// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { PMMMath } from "./PMMMath.sol";

/// @title PMMState
/// @notice The deterministic transition adapter over `PMMMath` (spec 5.1).
///
/// @dev `PMMMath` is a pure pricing function: give it a state, it gives back a number. It
///      never decides what the NEXT state is. This library does, and only that. It is
///      BASTION'S POLICY over DODO's pricing primitives, not a port of any DODO pool —
///      only `PMMPricing`/`DODOMath` are vendored, so no claim is made here about how
///      DODO's own pools sequence these steps.
///
///      Still a library: no storage, no opcodes, no anchors, no budgets. Where the state
///      lives is milestone 3 (ladder decision D2).
///
///      THE FILL SEQUENCE, and why it is in this order (spec 5.1):
///        1. Price on the NET curve input. The provider fee is not part of the trade the
///           curve sees.
///        2. Move the ledger: credit the GROSS input, debit the output. "Provider fees
///           increase the maker's actual input balance" — so the fee lands in inventory.
///        3. RE-CLASSIFY R from the resulting balances. The R that the curve returned was
///           computed on net input and is not assumed valid once gross is credited; a fill
///           the curve calls exactly back-to-`ONE` is not at target any more once the fee
///           is added. `test_GrossCredit_ReclassifiesR` pins that case.
///        4. Apply the reference's own `adjustedTarget` rule. This is the fee reinvestment
///           step: the extra inventory becomes a larger target rather than surplus sitting
///           outside the curve, and it leaves a state that is a FIXED POINT of
///           `adjustedTarget` — re-running it changes nothing, which is the machine-checkable
///           form of "leaves a valid next state".
///
///      Recentring is separate and explicit. Only `init` and `recentre` may move targets
///      for a reason other than a fill, and `recentre` to an unchanged anchor does nothing,
///      so repeated quotes at one anchor cannot walk the curve.
library PMMState {
    uint256 internal constant ONE = 1e18;

    /// @notice `i` of zero divides by zero inside `reciprocalFloor`.
    error InvalidAnchor();
    /// @notice `k` outside [0, 1e18], or inside the rejected band just below 1e18.
    error InvalidCurvature(uint256 k);
    /// @notice A leg opened at zero; the solver divides by both balances.
    error EmptyLedger();
    /// @notice The declared fee is larger than the input it is taken from.
    error FeeExceedsInput(uint256 grossInput, uint256 feeInput);
    /// @notice The fill would hand out the maker's entire output leg.
    /// @dev A leg at zero cannot be priced or recentred afterwards: `getMidPrice` and
    ///      `_GeneralIntegrate` both divide by the balances, so the book would be dead
    ///      rather than empty. The curve permits it — output is capped at the target, and
    ///      at R = ONE the target IS the balance — so refusing is Bastion's policy. It is
    ///      applied in `quoteExactIn` as well, so a quote is never shown for a fill that
    ///      would be refused.
    error LegExhausted(uint256 output, uint256 outputLeg);

    /// @dev Largest `k` accepted BELOW 1e18. `k == 1e18` exactly is accepted and is fine:
    ///      it is a separate closed form in the reference with no quadratic and no
    ///      1/(1-k) term. The band (0.999e18, 1e18) is REJECTED because of a measured
    ///      defect in the curve, recorded as FINDING 1 of milestone 2 increment 2:
    ///      `_SolveQuadraticFunctionForTrade` computes V2 = numerator * 1e18 / (2*(1e18-k)),
    ///      so every wei of the numerator's (unavoidable, floored) error is amplified by
    ///      1/(1-k). At 1-k = 1 the output deviates from the exact answer by 2.3e17 wei on
    ///      a 10e18 book; at 1-k = 3 on a 1e12-wei book the curve returns 4.1x the correct
    ///      output. The port reproduces the reference exactly there — the defect is in the
    ///      curve, not the port — so the only defence available at this layer is to refuse
    ///      the band. 0.999e18 is the widest bound this repository has fuzz-verified.
    ///      This is a Bastion restriction, NOT a DODO one, and it is the owner's to lift.
    uint256 internal constant MAX_CURVATURE_BELOW_ONE = 0.999e18;

    // ============ initialisation ============

    /// @notice Open a risk group at the target in both legs.
    /// @dev Spec 5.1: "Initialization and recentring must satisfy the canonical solver's
    ///      state relationships." At R = ONE that relationship is simply B0 = B, Q0 = Q,
    ///      so this is the one state that needs no solving — and the only one a maker may
    ///      name directly. A maker cannot hand in an arbitrary (B0, Q0, R).
    function init(uint256 i, uint256 k, uint256 b, uint256 q) internal pure returns (PMMMath.PMMState memory s) {
        if (i == 0) revert InvalidAnchor();
        if (k > ONE || (k > MAX_CURVATURE_BELOW_ONE && k != ONE)) revert InvalidCurvature(k);
        if (b == 0 || q == 0) revert EmptyLedger();
        s = PMMMath.PMMState({ i: i, K: k, B: b, Q: q, B0: b, Q0: q, R: PMMMath.RState.ONE });
    }

    // ============ quoting ============

    /// @notice Price a fill without touching the state.
    /// @dev Takes gross and fee rather than the net amount so that a caller cannot quote
    ///      one number and settle another. `state` is `memory`; this function assigns to
    ///      nothing in it, which `testFuzz_Quote_DoesNotMutateState` checks by hashing the
    ///      struct either side of the call. The no-write guarantee that gate Q1 needs is a
    ///      storage-level property and belongs to milestone 3; this is its precondition.
    function quoteExactIn(
        PMMMath.PMMState memory state,
        bool baseIn,
        uint256 grossInput,
        uint256 feeInput
    ) internal pure returns (uint256 output) {
        if (feeInput > grossInput) revert FeeExceedsInput(grossInput, feeInput);
        uint256 curveInput = grossInput - feeInput;
        (output, ) = baseIn
            ? PMMMath.sellBaseToken(state, curveInput)
            : PMMMath.sellQuoteToken(state, curveInput);
        uint256 outputLeg = baseIn ? state.Q : state.B;
        if (output >= outputLeg) revert LegExhausted(output, outputLeg);
    }

    // ============ transitions ============

    /// @notice Execute a fill: price on net, credit gross, debit output, leave a valid state.
    /// @param baseIn true when the taker pays base and receives quote
    /// @param grossInput everything the taker pays, fee included
    /// @param feeInput the provider fee inside `grossInput`, which the maker keeps
    /// @return output what the taker receives; never more than the maker's output leg
    function applyExactIn(
        PMMMath.PMMState memory state,
        bool baseIn,
        uint256 grossInput,
        uint256 feeInput
    ) internal pure returns (uint256 output) {
        if (feeInput > grossInput) revert FeeExceedsInput(grossInput, feeInput);

        // 1. price on the NET input
        uint256 curveInput = grossInput - feeInput;
        (output, ) = baseIn
            ? PMMMath.sellBaseToken(state, curveInput)
            : PMMMath.sellQuoteToken(state, curveInput);

        commitExactIn(state, baseIn, grossInput, output);
    }

    /// @notice Steps 2-4 of the fill sequence, given an output the curve has already priced.
    /// @dev Split out because the VM path cannot re-price at commit time. Upstream's
    ///      `FeeFlatIn` deducts the fee BEFORE the inner loop and restores it after, so the
    ///      instruction that prices sees only the NET input while the instruction that
    ///      commits sees the GROSS. Those are two different points in a program, so the
    ///      transition has to be callable without the pricing step. `applyExactIn` above is
    ///      the same sequence for callers that hold both numbers at once, and both share
    ///      this body — there is one implementation of the transition, not two.
    /// @param output what the curve returned for the NET input
    function commitExactIn(
        PMMMath.PMMState memory state,
        bool baseIn,
        uint256 grossInput,
        uint256 output
    ) internal pure {
        uint256 outputLeg = baseIn ? state.Q : state.B;
        if (output >= outputLeg) revert LegExhausted(output, outputLeg);

        // 2. move the ledger by the GROSS input
        if (baseIn) {
            state.B += grossInput;
            state.Q -= output;
        } else {
            state.Q += grossInput;
            state.B -= output;
        }

        // 3. the curve's R was computed on net input; re-derive it from the balances
        state.R = _classify(state, baseIn);

        // 4. fee reinvestment: restore canonicality with the reference's own rule
        (state.B0, state.Q0) = PMMMath.adjustedTarget(state);
    }

    /// @notice Move the anchor, once, and re-solve the target around it.
    /// @dev Spec 5.1: "a new anchor or approved target change applies once to the current
    ///      shared state. Repeated quotes at an unchanged anchor cannot reset the curve."
    ///      An unchanged anchor is a no-op here, so calling this on every quote would still
    ///      not walk the curve. At R = ONE there is no target to re-solve and only `i` moves.
    /// @return moved false when `newI` was already the anchor and nothing changed
    function recentre(PMMMath.PMMState memory state, uint256 newI) internal pure returns (bool moved) {
        if (newI == 0) revert InvalidAnchor();
        if (newI == state.i) return false;
        state.i = newI;
        (state.B0, state.Q0) = PMMMath.adjustedTarget(state);
        return true;
    }

    // ============ classification ============

    /// @dev R must agree with the balances, because the reference's own back-to-one
    ///      arithmetic subtracts on that assumption: ABOVE_ONE does `B0 - B` and `Q - Q0`,
    ///      BELOW_ONE the mirror. A state whose R disagrees underflows inside the reference.
    ///
    ///      The last branch is the one the fee creates. A fee big enough to outweigh a dust
    ///      output can leave BOTH legs above their targets, which no ordering rule covers.
    ///      The input leg is the one that grew, so the maker is long the input token and
    ///      the trade's own direction settles it; step 4 then raises the opposite target
    ///      above the balance, restoring the invariant.
    function _classify(PMMMath.PMMState memory state, bool baseIn) private pure returns (PMMMath.RState) {
        if (state.B == state.B0 && state.Q == state.Q0) return PMMMath.RState.ONE;
        if (state.B <= state.B0 && state.Q >= state.Q0) return PMMMath.RState.ABOVE_ONE;
        if (state.B >= state.B0 && state.Q <= state.Q0) return PMMMath.RState.BELOW_ONE;
        // Both legs above target: only a fee-heavy fill reaches here. The input leg is the
        // one that grew, so the trade's own direction settles it; step 4 then raises the
        // opposite target above the balance, restoring the invariant.
        return baseIn ? PMMMath.RState.BELOW_ONE : PMMMath.RState.ABOVE_ONE;
    }
}

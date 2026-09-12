// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

/// @title PMMMath
/// @notice Bastion's Solidity 0.8.30 port of DODO's finite-trade Proactive Market Maker.
///
/// @dev DERIVATIVE WORK. The arithmetic below is DODO ZOO's — Copyright 2020 DODO ZOO,
///      Apache-2.0 — from `DODOEX/contractV2` at pin `2f1bcdac` (UPSTREAM.md):
///      `contracts/lib/{PMMPricing,DODOMath,DecimalMath,SafeMath}.sol`.
///
///      The unmodified originals live in `reference/dodo/lib/`, compiled in their own
///      project at their own solc 0.6.9, and are the INDEPENDENT ORACLE for gate P1.
///      Nothing in this file may ever be used to produce an expected value for that
///      comparison (spec 5.1): expected values come from the 0.6.9 build, never from
///      a second copy of the port.
///
///      Porting rules, applied line by line:
///        1. `SafeMath.{add,sub,mul,div}` -> plain 0.8 checked arithmetic. It reverts on
///           exactly the same inputs; only the revert DATA differs (a string at 0.6.9,
///           `Panic(0x11)`/`Panic(0x12)` here). Return values are unaffected.
///        2. Where the reference deliberately uses a RAW `*` as an OVERFLOW PROBE
///           (`(a * b) / a == b`), this port keeps that multiply inside `unchecked` so it
///           still wraps. Making it checked would revert where the reference quietly
///           takes its fallback branch — a real behavioural divergence, not a style
///           preference. Every site is marked PORTING RULE 2 below. Small raw scalar
///           multiplies the reference leaves unchecked (`4 * k`, `k * 2`) are kept
///           unchecked for the same reason, even though `k <= 1e18` makes them safe.
///        3. `sqrt` is DODO's Babylonian loop, verbatim. MEASURED, not assumed: that loop
///           equals exact floor-sqrt on every input in 0..2,999,999 and on 40,000 random
///           values in 1e35..1e77, EXCEPT `x = 2`, where it returns 2 rather than 1. So a
///           substituted correct floor-sqrt would diverge only at that one argument, which
///           these paths never produce. The loop is kept for fidelity, not because the
///           differential test can currently tell the two apart.
///        4. The reference's explicit `require`/`revert` strings are preserved, so the
///           differential test can compare revert data on those paths too.
///
///      UNITS. `i` is quote raw units per base raw unit, scaled by 1e18 — the `priceWad`
///      of spec 5.2, i.e. AFTER decimal normalisation. `B`, `Q`, `B0`, `Q0` and every
///      amount are raw token units. `K` is 1e18-scaled, `0 <= K <= 1e18`. See Scale.sol
///      for turning a human price into `i`; PMMMath itself never sees a token decimal.
///
///      SCOPE — milestone 2 increment 2. Ported: both directions, all three entry states
///      including equilibrium crossings, `adjustedTarget` and `getMidPrice`. NOT ported,
///      and deliberately absent rather than stubbed: any exact-out inverse — the
///      reference has none, so the port gets no function for it. State transition,
///      initialisation and fee reinvestment are increment 3 and live outside this library.
library PMMMath {
    /// @dev Layout and ordering match `PMMPricing.RState` so the harness `uint8` maps 1:1.
    enum RState {
        ONE,
        ABOVE_ONE,
        BELOW_ONE
    }

    /// @dev Mirrors `PMMPricing.PMMState`.
    struct PMMState {
        uint256 i; // anchor price, quote raw per base raw, 1e18 fixed point
        uint256 K; // curve flatness, 1e18 fixed point, 0 <= K <= 1e18
        uint256 B; // base balance in the shared pricing ledger, raw units
        uint256 Q; // quote balance in the shared pricing ledger, raw units
        uint256 B0; // base target, raw units
        uint256 Q0; // quote target, raw units
        RState R; // which side of the target the maker is on
    }

    uint256 internal constant ONE = 10 ** 18;
    uint256 internal constant ONE2 = 10 ** 36;

    // ============ buy & sell ============

    /// @notice Bob pays base, Alice pays quote. Exact-in only.
    /// @dev `PMMPricing.sellBaseToken`.
    function sellBaseToken(
        PMMState memory state,
        uint256 payBaseAmount
    ) public pure returns (uint256 receiveQuoteAmount, RState newR) {
        if (state.R == RState.ONE) {
            // case 1: R = 1, R falls below one
            receiveQuoteAmount = _rOneSellBaseToken(state, payBaseAmount);
            newR = RState.BELOW_ONE;
        } else if (state.R == RState.ABOVE_ONE) {
            uint256 backToOnePayBase = state.B0 - state.B;
            uint256 backToOneReceiveQuote = state.Q - state.Q0;
            // case 2: R > 1, the resulting state depends on the trade size
            if (payBaseAmount < backToOnePayBase) {
                // case 2.1: R does not change
                receiveQuoteAmount = _rAboveSellBaseToken(state, payBaseAmount);
                newR = RState.ABOVE_ONE;
                if (receiveQuoteAmount > backToOneReceiveQuote) {
                    // [Important corner case!] reachable through precision loss, and it
                    // would otherwise leave spare quote negative. Clamp, as the reference does.
                    receiveQuoteAmount = backToOneReceiveQuote;
                }
            } else if (payBaseAmount == backToOnePayBase) {
                // case 2.2: R returns exactly to ONE
                receiveQuoteAmount = backToOneReceiveQuote;
                newR = RState.ONE;
            } else {
                // case 2.3: the fill crosses equilibrium and ends BELOW_ONE
                receiveQuoteAmount =
                    backToOneReceiveQuote +
                    _rOneSellBaseToken(state, payBaseAmount - backToOnePayBase);
                newR = RState.BELOW_ONE;
            }
        } else {
            // case 3: R < 1
            receiveQuoteAmount = _rBelowSellBaseToken(state, payBaseAmount);
            newR = RState.BELOW_ONE;
        }
    }

    /// @notice Bob pays quote, Alice pays base. Exact-in only.
    /// @dev `PMMPricing.sellQuoteToken`. Mirror image of `sellBaseToken`.
    function sellQuoteToken(
        PMMState memory state,
        uint256 payQuoteAmount
    ) public pure returns (uint256 receiveBaseAmount, RState newR) {
        if (state.R == RState.ONE) {
            receiveBaseAmount = _rOneSellQuoteToken(state, payQuoteAmount);
            newR = RState.ABOVE_ONE;
        } else if (state.R == RState.ABOVE_ONE) {
            receiveBaseAmount = _rAboveSellQuoteToken(state, payQuoteAmount);
            newR = RState.ABOVE_ONE;
        } else {
            uint256 backToOnePayQuote = state.Q0 - state.Q;
            uint256 backToOneReceiveBase = state.B - state.B0;
            if (payQuoteAmount < backToOnePayQuote) {
                receiveBaseAmount = _rBelowSellQuoteToken(state, payQuoteAmount);
                newR = RState.BELOW_ONE;
                if (receiveBaseAmount > backToOneReceiveBase) {
                    // [Important corner case!] see sellBaseToken.
                    receiveBaseAmount = backToOneReceiveBase;
                }
            } else if (payQuoteAmount == backToOnePayQuote) {
                receiveBaseAmount = backToOneReceiveBase;
                newR = RState.ONE;
            } else {
                receiveBaseAmount =
                    backToOneReceiveBase +
                    _rOneSellQuoteToken(state, payQuoteAmount - backToOnePayQuote);
                newR = RState.ABOVE_ONE;
            }
        }
    }

    // ============ R = 1 cases ============

    /// @dev `PMMPricing._ROneSellBaseToken`.
    function _rOneSellBaseToken(PMMState memory state, uint256 payBaseAmount) internal pure returns (uint256) {
        // in theory Q2 <= Q0; when the amount is near zero precision may say otherwise
        return _solveQuadraticFunctionForTrade(state.Q0, state.Q0, payBaseAmount, state.i, state.K);
    }

    /// @dev `PMMPricing._ROneSellQuoteToken`. Note it reads only `B0`, `i` and `K`.
    function _rOneSellQuoteToken(PMMState memory state, uint256 payQuoteAmount) internal pure returns (uint256) {
        return _solveQuadraticFunctionForTrade(state.B0, state.B0, payQuoteAmount, reciprocalFloor(state.i), state.K);
    }

    // ============ R < 1 cases ============

    /// @dev `PMMPricing._RBelowSellQuoteToken`.
    function _rBelowSellQuoteToken(PMMState memory state, uint256 payQuoteAmount) internal pure returns (uint256) {
        return _generalIntegrate(state.Q0, state.Q + payQuoteAmount, state.Q, reciprocalFloor(state.i), state.K);
    }

    /// @dev `PMMPricing._RBelowSellBaseToken`.
    function _rBelowSellBaseToken(PMMState memory state, uint256 payBaseAmount) internal pure returns (uint256) {
        return _solveQuadraticFunctionForTrade(state.Q0, state.Q, payBaseAmount, state.i, state.K);
    }

    // ============ R > 1 cases ============

    /// @dev `PMMPricing._RAboveSellBaseToken`.
    function _rAboveSellBaseToken(PMMState memory state, uint256 payBaseAmount) internal pure returns (uint256) {
        return _generalIntegrate(state.B0, state.B + payBaseAmount, state.B, state.i, state.K);
    }

    /// @dev `PMMPricing._RAboveSellQuoteToken`.
    function _rAboveSellQuoteToken(PMMState memory state, uint256 payQuoteAmount) internal pure returns (uint256) {
        return _solveQuadraticFunctionForTrade(state.B0, state.B, payQuoteAmount, reciprocalFloor(state.i), state.K);
    }

    // ============ helpers ============

    /// @dev `PMMPricing.adjustedTarget`. Mutates `state` in place, as the reference does:
    ///      it rewrites ONE of `Q0`/`B0` and leaves everything else alone. This is the
    ///      recentring arithmetic only — WHEN it may be applied is a policy question
    ///      (spec 5.1: recentring is an explicit transition, repeated quotes at an
    ///      unchanged anchor must not reset the curve) and lives in increment 3.
    /// @dev RETURNS the adjusted targets rather than mutating `state` in place, unlike the
    ///      reference, which is `internal` and can. This library is DEPLOYED and reached by
    ///      delegatecall (see BastionAquaSwapVMRouter and gate D1), and a callee's changes to
    ///      a memory struct do not propagate back across that boundary. Returning is the only
    ///      shape that is correct both inlined and linked. The arithmetic is untouched.
    function adjustedTarget(PMMState memory state) public pure returns (uint256 newB0, uint256 newQ0) {
        newB0 = state.B0;
        newQ0 = state.Q0;
        if (state.R == RState.BELOW_ONE) {
            newQ0 = _solveQuadraticFunctionForTarget(state.Q, state.B - state.B0, state.i, state.K);
        } else if (state.R == RState.ABOVE_ONE) {
            newB0 = _solveQuadraticFunctionForTarget(state.B, state.Q - state.Q0, reciprocalFloor(state.i), state.K);
        }
    }

    /// @dev `PMMPricing.getMidPrice`. Quote raw per base raw, 1e18 scaled.
    function getMidPrice(PMMState memory state) public pure returns (uint256) {
        if (state.R == RState.BELOW_ONE) {
            uint256 r = divFloor((state.Q0 * state.Q0) / state.Q, state.Q);
            r = ONE - state.K + mulFloor(state.K, r);
            return divFloor(state.i, r);
        } else {
            uint256 r = divFloor((state.B0 * state.B0) / state.B, state.B);
            r = ONE - state.K + mulFloor(state.K, r);
            return mulFloor(state.i, r);
        }
    }

    // ============ DODOMath ============

    /// @dev `DODOMath._GeneralIntegrate`. Integrates the curve from V1 to V2, requires
    ///      V0 >= V1 >= V2 > 0. Rounds down.
    ///      res = i*delta*(1-k+k(V0^2/V1/V2)), delta = V1-V2
    function _generalIntegrate(
        uint256 V0,
        uint256 V1,
        uint256 V2,
        uint256 i,
        uint256 k
    ) internal pure returns (uint256) {
        require(V0 > 0, "TARGET_IS_ZERO");
        uint256 fairAmount = i * (V1 - V2); // i*delta
        if (k == 0) {
            return fairAmount / ONE;
        }
        uint256 V0V0V1V2 = divFloor((V0 * V0) / V1, V2);
        uint256 penalty = mulFloor(k, V0V0V1V2); // k(V0^2/V1/V2)
        return ((ONE - k + penalty) * fairAmount) / ONE2;
    }

    /// @dev `DODOMath._SolveQuadraticFunctionForTarget`. Given V1 and delta, solve V0.
    ///      Rounds down.
    function _solveQuadraticFunctionForTarget(
        uint256 V1,
        uint256 delta,
        uint256 i,
        uint256 k
    ) internal pure returns (uint256) {
        if (k == 0) {
            return V1 + mulFloor(i, delta);
        }
        // V0 = V1*(1+(sqrt-1)/2k), sqrt = sqrt(1+4kidelta/V1)
        if (V1 == 0) {
            return 0;
        }
        uint256 root;
        uint256 ki;
        unchecked {
            // PORTING RULE 2: the reference leaves `4 * k` raw. k <= 1e18 makes it safe,
            // but faithfulness is the point, not the bound.
            ki = 4 * k;
        }
        ki = ki * i; // checked: the reference uses SafeMath.mul here
        if (ki == 0) {
            root = ONE;
        } else {
            uint256 product;
            bool invertible;
            unchecked {
                // PORTING RULE 2: overflow probe, must be allowed to wrap.
                product = ki * delta;
                invertible = product / ki == delta;
            }
            root = invertible ? sqrt(product / V1 + ONE2) : sqrt((ki / V1) * delta + ONE2);
        }
        uint256 twoK;
        unchecked {
            // PORTING RULE 2: the reference leaves `k * 2` raw.
            twoK = k * 2;
        }
        uint256 premium = divFloor(root - ONE, twoK) + ONE;
        // V0 >= V1 by construction of the solution
        return mulFloor(V1, premium);
    }

    /// @dev `DODOMath._SolveQuadraticFunctionForTrade`. Given V1 and delta, solve V2 and
    ///      return |V1 - V2|. `i` is the price of the delta-V pair. Rounds down.
    ///      Supports k = 0 and k = 1 as special branches, exactly as the reference does.
    function _solveQuadraticFunctionForTrade(
        uint256 V0,
        uint256 V1,
        uint256 delta,
        uint256 i,
        uint256 k
    ) internal pure returns (uint256) {
        require(V0 > 0, "TARGET_IS_ZERO");
        if (delta == 0) return 0;

        if (k == 0) {
            uint256 flat = mulFloor(i, delta);
            return flat > V1 ? V1 : flat;
        }

        if (k == ONE) {
            // Q2 = Q1/(1+temp), temp = i*delta*Q1/Q0/Q0, so Q1-Q2 = Q1*temp/(1+temp)
            uint256 temp;
            uint256 idelta = i * delta;
            if (idelta == 0) {
                temp = 0;
            } else {
                uint256 product;
                bool invertible;
                unchecked {
                    // PORTING RULE 2: overflow probe, must be allowed to wrap.
                    product = idelta * V1;
                    invertible = product / idelta == V1;
                }
                // `V0 * V0` stays checked: the reference uses SafeMath.mul here.
                temp = invertible ? product / (V0 * V0) : (((delta * V1) / V0) * i) / V0;
            }
            return (V1 * temp) / (temp + ONE);
        }

        // b = kQ0^2/Q1 - i*deltaB - (1-k)Q1, carried as |b| plus a sign flag
        uint256 part2 = (((k * V0) / V1) * V0) + (i * delta); // kQ0^2/Q1-i*deltaB
        uint256 bAbs = (ONE - k) * V1; // (1-k)Q1

        bool bSig;
        if (bAbs >= part2) {
            bAbs = bAbs - part2;
            bSig = false;
        } else {
            bAbs = part2 - bAbs;
            bSig = true;
        }
        bAbs = bAbs / ONE;

        uint256 squareRoot = mulFloor((ONE - k) * 4, mulFloor(k, V0) * V0); // 4(1-k)kQ0^2
        squareRoot = sqrt((bAbs * bAbs) + squareRoot); // sqrt(b*b+4(1-k)kQ0*Q0)

        uint256 denominator = (ONE - k) * 2; // 2(1-k)
        uint256 numerator;
        if (bSig) {
            numerator = squareRoot - bAbs;
            if (numerator == 0) {
                revert("DODOMath: should not be zero");
            }
        } else {
            numerator = bAbs + squareRoot;
        }

        // V2 rounds UP, so the returned output V1 - V2 rounds DOWN, toward the maker.
        uint256 V2 = divCeil(numerator, denominator);
        if (V2 > V1) {
            return 0;
        } else {
            return V1 - V2;
        }
    }

    // ============ DecimalMath ============

    /// @dev `DecimalMath.mulFloor`.
    function mulFloor(uint256 target, uint256 d) internal pure returns (uint256) {
        return (target * d) / ONE;
    }

    /// @dev `DecimalMath.divFloor`.
    function divFloor(uint256 target, uint256 d) internal pure returns (uint256) {
        return (target * ONE) / d;
    }

    /// @dev `DecimalMath.divCeil`.
    function divCeil(uint256 target, uint256 d) internal pure returns (uint256) {
        return _divCeil(target * ONE, d);
    }

    /// @dev `DecimalMath.reciprocalFloor`. Reverts on `target == 0`, as the reference does.
    function reciprocalFloor(uint256 target) internal pure returns (uint256) {
        return ONE2 / target;
    }

    // ============ SafeMath ============

    /// @dev `SafeMath.divCeil`, kept in the reference's remainder form rather than the
    ///      `(a + b - 1) / b` idiom: that idiom overflows on inputs this one handles.
    function _divCeil(uint256 a, uint256 b) internal pure returns (uint256) {
        uint256 quotient = a / b;
        uint256 remainder = a - quotient * b;
        if (remainder > 0) {
            return quotient + 1;
        } else {
            return quotient;
        }
    }

    /// @dev `SafeMath.sqrt`, DODO's Babylonian loop. See porting rule 3 in the header.
    function sqrt(uint256 x) internal pure returns (uint256 y) {
        uint256 z = x / 2 + 1;
        y = x;
        while (z < y) {
            y = z;
            z = (x / z + z) / 2;
        }
    }
}

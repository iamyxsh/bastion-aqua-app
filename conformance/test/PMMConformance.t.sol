// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// BASTION — gate P1 and the exact-in half of gate P2. Milestone 2, increments 1 and 2.
///
/// One question: does our 0.8.30 port return EXACTLY what DODO's own code returns?
///
///   port      contracts/src/bastion/pmm/PMMMath.sol      compiled here, solc 0.8.30
///   reference reference/dodo/lib/PMMPricing.sol et al.   compiled by its OWN project at
///             solc 0.6.9 and loaded here as bytecode through vm.getCode
///
/// Expected values are never computed in this file. Every one of them is whatever the
/// 0.6.9 bytecode returns (spec 5.1: "Expected values never come from another copy of
/// the port"). Both sides are called through identical ABIs and compared on RAW
/// RETURNDATA, so a difference in the output amount, in the next R state, in a
/// recomputed target, or in whether the call reverted all fail the same assertion.
///
/// SCOPE after increment 2: both directions, all three entry states, equilibrium
/// crossings inside one fill, adjustedTarget, getMidPrice, 6/18-decimal normalisation of
/// the anchor, and maker-favouring exact-in rounding. Exact-out does not exist: the
/// reference has no inverse, so the port has no function to test. State transition
/// policy — initialisation, fee reinvestment, when recentring may be applied — is
/// increment 3 and is NOT tested here; where these tests advance a ledger they do that
/// arithmetic locally, in the test, and say so.
///
/// DECLARED DOMAIN (every bound is asserted by `bound`, not hoped for):
///   i        [1e15, 1e24]   anchor wad, quote RAW per base RAW ($0.001 .. $1,000,000 at 18/18)
///   K        [0, 1e18]      inclusive; k = 0 and k = 1e18 are also pinned as fixed cases
///   B0       [1e12, min(1e27, 1e46/i)]  base target, capped so BOTH legs stay <= 1e28
///   Q0       B0 * i / 1e18  the consistent R = ONE initialisation
/// The cap on B0 is load-bearing, not cosmetic. `_SolveQuadraticFunctionForTrade`
/// evaluates 4*(1-k)*k*V0^2, and V0 is the QUOTE target when selling base. At 4e18 * V0^2
/// the multiply overflows uint256 once V0 passes ~1.7e29, so an uncapped quote leg makes
/// both sides revert — with different revert data, which reads as a false divergence.
///   pay      [0, 4 * Q0] selling quote, [0, 4 * B0] selling base
///   states   ONE, plus ABOVE_ONE/BELOW_ONE reached by a real reference trade, plus
///            synthetic off-target states that satisfy only the R ordering invariant
/// Outside these bounds both sides still refuse, but with different revert DATA — see
/// test_OutsideDomain_BothRevert_ButRevertDataDiffers.

import { Test } from "forge-std/Test.sol";
import { console2 } from "forge-std/console2.sol";

import { PMMMath } from "bastion/pmm/PMMMath.sol";
import { Scale } from "bastion/pmm/Scale.sol";

/// @dev DODO's 0.6.9 harness (reference/dodo/src/PMMHarness.sol), reached by bytecode.
interface IPMMHarness {
    function sellBase(uint256 i, uint256 K, uint256 B, uint256 Q, uint256 B0, uint256 Q0, uint8 R, uint256 pay)
        external pure returns (uint256 receiveQuote, uint8 newR);
    function sellQuote(uint256 i, uint256 K, uint256 B, uint256 Q, uint256 B0, uint256 Q0, uint8 R, uint256 pay)
        external pure returns (uint256 receiveBase, uint8 newR);
    function adjustTarget(uint256 i, uint256 K, uint256 B, uint256 Q, uint256 B0, uint256 Q0, uint8 R)
        external pure returns (uint256 newB0, uint256 newQ0);
    function midPrice(uint256 i, uint256 K, uint256 B, uint256 Q, uint256 B0, uint256 Q0, uint8 R)
        external pure returns (uint256);
}

/// @dev The port behind the SAME external ABI as the harness, so both sides can be driven
///      by one staticcall and compared on raw returndata.
contract PMMPort {
    function _s(uint256 i, uint256 K, uint256 B, uint256 Q, uint256 B0, uint256 Q0, uint8 R)
        private pure returns (PMMMath.PMMState memory)
    {
        return PMMMath.PMMState({ i: i, K: K, B: B, Q: Q, B0: B0, Q0: Q0, R: PMMMath.RState(R) });
    }

    function sellBase(uint256 i, uint256 K, uint256 B, uint256 Q, uint256 B0, uint256 Q0, uint8 R, uint256 pay)
        external pure returns (uint256 receiveQuote, uint8 newR)
    {
        (uint256 out, PMMMath.RState r) = PMMMath.sellBaseToken(_s(i, K, B, Q, B0, Q0, R), pay);
        return (out, uint8(r));
    }

    function sellQuote(uint256 i, uint256 K, uint256 B, uint256 Q, uint256 B0, uint256 Q0, uint8 R, uint256 pay)
        external pure returns (uint256 receiveBase, uint8 newR)
    {
        (uint256 out, PMMMath.RState r) = PMMMath.sellQuoteToken(_s(i, K, B, Q, B0, Q0, R), pay);
        return (out, uint8(r));
    }

    function adjustTarget(uint256 i, uint256 K, uint256 B, uint256 Q, uint256 B0, uint256 Q0, uint8 R)
        external pure returns (uint256 newB0, uint256 newQ0)
    {
        return PMMMath.adjustedTarget(_s(i, K, B, Q, B0, Q0, R));
    }

    function midPrice(uint256 i, uint256 K, uint256 B, uint256 Q, uint256 B0, uint256 Q0, uint8 R)
        external pure returns (uint256)
    {
        return PMMMath.getMidPrice(_s(i, K, B, Q, B0, Q0, R));
    }

    // Scale is a Bastion library with no DODO counterpart; it is unit-tested, not diffed.
    function toAnchorWad(uint256 humanPriceWad, uint8 baseDec, uint8 quoteDec) external pure returns (uint256) {
        return Scale.toAnchorWad(humanPriceWad, baseDec, quoteDec);
    }

    function toHumanPriceWad(uint256 i, uint8 baseDec, uint8 quoteDec) external pure returns (uint256) {
        return Scale.toHumanPriceWad(i, baseDec, quoteDec);
    }
}

// solhint-disable no-console
contract PMMConformanceTest is Test {
    uint256 internal constant ONE = 1e18;
    uint256 internal constant ONE2 = 1e36;

    uint8 internal constant R_ONE = 0;
    uint8 internal constant R_ABOVE_ONE = 1;
    uint8 internal constant R_BELOW_ONE = 2;

    uint256 internal constant I_MIN = 1e15;
    uint256 internal constant I_MAX = 1e24;
    uint256 internal constant B0_MIN = 1e12;
    uint256 internal constant B0_MAX = 1e27;
    /// @dev Largest either leg may reach: 4e18 * LEG_MAX^2 must stay below 2^256.
    uint256 internal constant LEG_MAX = 1e28;

    IPMMHarness internal ref;
    PMMPort internal port;

    /// @dev A full PMM state. `R` is a uint8 to match both ABIs.
    struct St {
        uint256 i;
        uint256 k;
        uint256 B;
        uint256 Q;
        uint256 B0;
        uint256 Q0;
        uint8 R;
    }

    function setUp() public {
        bytes memory code = vm.getCode("../reference/dodo/out/PMMHarness.sol/PMMHarness.json");
        address a;
        assembly {
            a := create(0, add(code, 0x20), mload(code))
        }
        require(a != address(0), "PMMHarness deploy failed - run: forge build --root reference/dodo");
        ref = IPMMHarness(a);
        port = new PMMPort();
    }

    // ------------------------------------------------------------ the comparison

    /// @dev One call each, identical calldata, compared on raw returndata.
    function _assertSameCall(bytes memory cd, string memory what) internal view {
        (bool refOk, bytes memory refData) = address(ref).staticcall(cd);
        (bool portOk, bytes memory portData) = address(port).staticcall(cd);
        assertEq(portOk, refOk, string.concat(what, ": one side reverted and the other did not"));
        assertEq(portData, refData, string.concat(what, ": port and reference disagree"));
    }

    function _sameSellBase(St memory s, uint256 pay) internal view {
        _assertSameCall(abi.encodeCall(IPMMHarness.sellBase, (s.i, s.k, s.B, s.Q, s.B0, s.Q0, s.R, pay)), "sellBase");
    }

    function _sameSellQuote(St memory s, uint256 pay) internal view {
        _assertSameCall(abi.encodeCall(IPMMHarness.sellQuote, (s.i, s.k, s.B, s.Q, s.B0, s.Q0, s.R, pay)), "sellQuote");
    }

    function _sameAdjustTarget(St memory s) internal view {
        _assertSameCall(abi.encodeCall(IPMMHarness.adjustTarget, (s.i, s.k, s.B, s.Q, s.B0, s.Q0, s.R)), "adjustTarget");
    }

    function _sameMidPrice(St memory s) internal view {
        _assertSameCall(abi.encodeCall(IPMMHarness.midPrice, (s.i, s.k, s.B, s.Q, s.B0, s.Q0, s.R)), "midPrice");
    }

    /// @dev Compare every function this state can answer, in one call.
    function _sameEverything(St memory s, uint256 payBase, uint256 payQuote) internal view {
        _sameSellBase(s, payBase);
        _sameSellQuote(s, payQuote);
        _sameAdjustTarget(s);
        _sameMidPrice(s);
    }

    // ------------------------------------------------------------ state construction

    /// Bound raw fuzz words into the declared domain, capping B0 so that the QUOTE leg
    /// (B0 * i / 1e18) also stays within LEG_MAX. See the header note on why.
    function _boundState(uint256 iRaw, uint256 k, uint256 b0Raw) internal pure returns (St memory) {
        uint256 i = bound(iRaw, I_MIN, I_MAX);
        uint256 cap = (LEG_MAX * ONE) / i;
        if (cap > B0_MAX) cap = B0_MAX;
        return _one(i, k, bound(b0Raw, B0_MIN, cap));
    }

    /// A consistent R = ONE state: at target in both legs, Q0 valued at the anchor.
    function _one(uint256 i, uint256 k, uint256 b0) internal pure returns (St memory) {
        uint256 q0 = (b0 * i) / ONE;
        return St({ i: i, k: k, B: b0, Q: q0, B0: b0, Q0: q0, R: R_ONE });
    }

    /// Reject a fuzz input that the REFERENCE itself refuses. DODO reverts
    /// "DODOMath: should not be zero" whenever the quadratic's numerator lands exactly on
    /// zero, which happens once `mulFloor(k, V0)` floors away — a small target with a
    /// near-zero k — and the trade is large enough to flip the sign of b. Those inputs are
    /// not swept under the rug: test_ReferenceRefusal_BothRevertIdentically pins one, and
    /// the raw-returndata comparison covers the rest. They are excluded only from the
    /// tests that need a NUMBER back.
    function _assumePriceable(bytes memory cd) internal view {
        (bool ok,) = address(ref).staticcall(cd);
        vm.assume(ok);
    }

    function _tryPortSellQuote(St memory s, uint256 pay) internal view returns (bool ok, uint256 out) {
        bytes memory cd = abi.encodeCall(IPMMHarness.sellQuote, (s.i, s.k, s.B, s.Q, s.B0, s.Q0, s.R, pay));
        (bool o, bytes memory d) = address(port).staticcall(cd);
        if (!o) return (false, 0);
        (out, ) = abi.decode(d, (uint256, uint8));
        ok = true;
    }

    function _tryPortSellBase(St memory s, uint256 pay) internal view returns (bool ok, uint256 out) {
        bytes memory cd = abi.encodeCall(IPMMHarness.sellBase, (s.i, s.k, s.B, s.Q, s.B0, s.Q0, s.R, pay));
        (bool o, bytes memory d) = address(port).staticcall(cd);
        if (!o) return (false, 0);
        (out, ) = abi.decode(d, (uint256, uint8));
        ok = true;
    }

    /// Same state with every amount multiplied by `m` — the homogeneity oracle's input.
    function _scaled(St memory s, uint256 m) internal pure returns (St memory) {
        return St({ i: s.i, k: s.k, B: s.B * m, Q: s.Q * m, B0: s.B0 * m, Q0: s.Q0 * m, R: s.R });
    }

    /// Advance a state by a real fill priced by the REFERENCE. The ledger arithmetic here
    /// (input credited, output debited) is the TEST's, not the library's: PMMMath is pure
    /// and the transition adapter is increment 3. Targets are deliberately left alone,
    /// which is what a real pool does between anchor changes.
    function _afterSellQuote(St memory s, uint256 pay) internal view returns (St memory out) {
        _assumePriceable(abi.encodeCall(IPMMHarness.sellQuote, (s.i, s.k, s.B, s.Q, s.B0, s.Q0, s.R, pay)));
        (uint256 recvBase, uint8 newR) = ref.sellQuote(s.i, s.k, s.B, s.Q, s.B0, s.Q0, s.R, pay);
        out = s;
        out.Q = s.Q + pay;
        out.B = s.B - recvBase;
        out.R = newR;
    }

    function _afterSellBase(St memory s, uint256 pay) internal view returns (St memory out) {
        _assumePriceable(abi.encodeCall(IPMMHarness.sellBase, (s.i, s.k, s.B, s.Q, s.B0, s.Q0, s.R, pay)));
        (uint256 recvQuote, uint8 newR) = ref.sellBase(s.i, s.k, s.B, s.Q, s.B0, s.Q0, s.R, pay);
        out = s;
        out.B = s.B + pay;
        out.Q = s.Q - recvQuote;
        out.R = newR;
    }

    /// A canonical ABOVE_ONE state: one real quote-in fill away from equilibrium.
    function _canonicalAbove(St memory s, uint256 payRaw) internal view returns (St memory) {
        return _afterSellQuote(s, bound(payRaw, 1, s.Q0 / 2 + 1));
    }

    /// A canonical BELOW_ONE state: one real base-in fill away from equilibrium.
    function _canonicalBelow(St memory s, uint256 payRaw) internal view returns (St memory) {
        return _afterSellBase(s, bound(payRaw, 1, s.B0 / 2 + 1));
    }

    // ============================================================================
    // P1 — R = ONE, both directions
    // ============================================================================

    function testFuzz_SellQuote_ROne(uint256 iRaw, uint256 kRaw, uint256 b0Raw, uint256 payRaw) public view {
        St memory s = _boundState(iRaw, bound(kRaw, 0, ONE), b0Raw);
        _sameSellQuote(s, bound(payRaw, 0, 4 * s.Q0));
    }

    function testFuzz_SellBase_ROne(uint256 iRaw, uint256 kRaw, uint256 b0Raw, uint256 payRaw) public view {
        St memory s = _boundState(iRaw, bound(kRaw, 0, ONE), b0Raw);
        _sameSellBase(s, bound(payRaw, 0, 4 * s.B0));
    }

    /// k = 0 and k = 1e18 are separate branches in the reference and `bound` almost never
    /// lands on an endpoint, so pin both, in both directions.
    function testFuzz_SellQuote_ROne_KZero(uint256 iRaw, uint256 b0Raw, uint256 payRaw) public view {
        St memory s = _boundState(iRaw, 0, b0Raw);
        _sameSellQuote(s, bound(payRaw, 0, 4 * s.Q0));
    }

    function testFuzz_SellQuote_ROne_KOne(uint256 iRaw, uint256 b0Raw, uint256 payRaw) public view {
        St memory s = _boundState(iRaw, ONE, b0Raw);
        _sameSellQuote(s, bound(payRaw, 0, 4 * s.Q0));
    }

    function testFuzz_SellBase_ROne_KZero(uint256 iRaw, uint256 b0Raw, uint256 payRaw) public view {
        St memory s = _boundState(iRaw, 0, b0Raw);
        _sameSellBase(s, bound(payRaw, 0, 4 * s.B0));
    }

    function testFuzz_SellBase_ROne_KOne(uint256 iRaw, uint256 b0Raw, uint256 payRaw) public view {
        St memory s = _boundState(iRaw, ONE, b0Raw);
        _sameSellBase(s, bound(payRaw, 0, 4 * s.B0));
    }

    // ============================================================================
    // P1 — canonical off-target states, both directions, every function
    // ============================================================================

    function testFuzz_CanonicalAbove(uint256 iRaw, uint256 kRaw, uint256 b0Raw, uint256 seedRaw, uint256 payRaw)
        public
        view
    {
        St memory s = _canonicalAbove(_boundState(iRaw, bound(kRaw, 0, ONE), b0Raw), seedRaw);
        assertEq(s.R, R_ABOVE_ONE, "constructed state is not ABOVE_ONE");
        _sameEverything(s, bound(payRaw, 0, 4 * s.B0), bound(payRaw, 0, 4 * s.Q0));
    }

    function testFuzz_CanonicalBelow(uint256 iRaw, uint256 kRaw, uint256 b0Raw, uint256 seedRaw, uint256 payRaw)
        public
        view
    {
        St memory s = _canonicalBelow(_boundState(iRaw, bound(kRaw, 0, ONE), b0Raw), seedRaw);
        assertEq(s.R, R_BELOW_ONE, "constructed state is not BELOW_ONE");
        _sameEverything(s, bound(payRaw, 0, 4 * s.B0), bound(payRaw, 0, 4 * s.Q0));
    }

    /// Synthetic off-target states. They satisfy only the R ordering invariant that the
    /// reference's own back-to-one arithmetic assumes (ABOVE_ONE: B < B0 and Q > Q0), not
    /// the curve invariant. That is deliberate: it reaches branches a canonical state
    /// rarely does, including the reference's "[Important corner case!]" clamps.
    function testFuzz_SyntheticAbove(
        uint256 iRaw, uint256 kRaw, uint256 b0Raw, uint256 bGapRaw, uint256 qGapRaw, uint256 payRaw
    ) public view {
        St memory base = _boundState(iRaw, bound(kRaw, 0, ONE), b0Raw);
        uint256 b0 = base.B0;
        uint256 q0 = base.Q0;
        St memory s = St({
            i: base.i,
            k: base.k,
            // stay off the degenerate end: a reserve of a few wei makes B0^2/B overflow
            // on both sides, which reads as a divergence but is only a broken input
            B: b0 - bound(bGapRaw, 1, b0 / 2),
            Q: q0 + bound(qGapRaw, 1, q0),
            B0: b0,
            Q0: q0,
            R: R_ABOVE_ONE
        });
        _sameEverything(s, bound(payRaw, 0, 4 * s.B0), bound(payRaw, 0, 4 * s.Q0));
    }

    function testFuzz_SyntheticBelow(
        uint256 iRaw, uint256 kRaw, uint256 b0Raw, uint256 bGapRaw, uint256 qGapRaw, uint256 payRaw
    ) public view {
        St memory base = _boundState(iRaw, bound(kRaw, 0, ONE), b0Raw);
        uint256 b0 = base.B0;
        uint256 q0 = base.Q0;
        St memory s = St({
            i: base.i,
            k: base.k,
            B: b0 + bound(bGapRaw, 1, b0),
            Q: q0 - bound(qGapRaw, 1, q0 / 2),
            B0: b0,
            Q0: q0,
            R: R_BELOW_ONE
        });
        _sameEverything(s, bound(payRaw, 0, 4 * s.B0), bound(payRaw, 0, 4 * s.Q0));
    }

    /// Three fills in sequence, alternating direction, comparing both implementations at
    /// every step and after each recentring. This is where a state-dependent divergence
    /// would compound rather than cancel.
    function testFuzz_TradeSequence(uint256 iRaw, uint256 kRaw, uint256 b0Raw, uint256 p1, uint256 p2, uint256 p3)
        public
        view
    {
        St memory s = _boundState(iRaw, bound(kRaw, 0, ONE), b0Raw);

        uint256 payQ = bound(p1, 1, s.Q0 / 4 + 1);
        _sameSellQuote(s, payQ);
        s = _afterSellQuote(s, payQ);
        _sameAdjustTarget(s);
        _sameMidPrice(s);

        uint256 payB = bound(p2, 1, s.B / 4 + 1);
        _sameSellBase(s, payB);
        s = _afterSellBase(s, payB);
        _sameAdjustTarget(s);
        _sameMidPrice(s);

        uint256 payQ2 = bound(p3, 1, s.Q / 4 + 1);
        _sameSellQuote(s, payQ2);
        s = _afterSellQuote(s, payQ2);
        _sameAdjustTarget(s);
        _sameMidPrice(s);
    }

    // ============================================================================
    // P1 — equilibrium crossings inside one fill
    // ============================================================================

    /// Selling base into an ABOVE_ONE maker walks the state back toward the target. The
    /// reference splits that into three cases at `backToOnePayBase = B0 - B`, and the
    /// boundary is exact, not approximate — so test one wei either side of it and on it.
    function test_Crossing_SellBase_FromAbove() public view {
        St memory s = _canonicalAbove(_one(3_000e18, 0.1e18, 10e18), 1_000e18);
        uint256 backToOne = s.B0 - s.B;
        assertGt(backToOne, 2, "need room to step either side of the boundary");

        // case 2.1 — one wei short: stays ABOVE_ONE
        (uint256 outShort, uint8 rShort) = port.sellBase(s.i, s.k, s.B, s.Q, s.B0, s.Q0, s.R, backToOne - 1);
        assertEq(rShort, R_ABOVE_ONE, "one wei short of the boundary must stay ABOVE_ONE");
        _sameSellBase(s, backToOne - 1);

        // case 2.2 — exactly on it: R becomes ONE and the output is exactly the spare quote
        (uint256 outExact, uint8 rExact) = port.sellBase(s.i, s.k, s.B, s.Q, s.B0, s.Q0, s.R, backToOne);
        assertEq(rExact, R_ONE, "exactly back to target must report ONE");
        assertEq(outExact, s.Q - s.Q0, "back-to-one output must be exactly the spare quote");
        _sameSellBase(s, backToOne);

        // case 2.3 — one wei over: crosses into BELOW_ONE inside a single fill
        (uint256 outOver, uint8 rOver) = port.sellBase(s.i, s.k, s.B, s.Q, s.B0, s.Q0, s.R, backToOne + 1);
        assertEq(rOver, R_BELOW_ONE, "crossing the target must land BELOW_ONE");
        _sameSellBase(s, backToOne + 1);

        assertLe(outShort, outExact, "output must not decrease approaching the boundary");
        assertLe(outExact, outOver, "output must not decrease crossing the boundary");
        console2.log("sellBase from ABOVE_ONE, backToOnePayBase =", backToOne);
        console2.log("  one wei short -> out", outShort, "R", rShort);
        console2.log("  exactly       -> out", outExact, "R", rExact);
        console2.log("  one wei over  -> out", outOver, "R", rOver);
    }

    /// The mirror image: selling quote into a BELOW_ONE maker.
    function test_Crossing_SellQuote_FromBelow() public view {
        St memory s = _canonicalBelow(_one(3_000e18, 0.1e18, 10e18), 3e18);
        uint256 backToOne = s.Q0 - s.Q;
        assertGt(backToOne, 2, "need room to step either side of the boundary");

        (, uint8 rShort) = port.sellQuote(s.i, s.k, s.B, s.Q, s.B0, s.Q0, s.R, backToOne - 1);
        assertEq(rShort, R_BELOW_ONE, "one wei short of the boundary must stay BELOW_ONE");
        _sameSellQuote(s, backToOne - 1);

        (uint256 outExact, uint8 rExact) = port.sellQuote(s.i, s.k, s.B, s.Q, s.B0, s.Q0, s.R, backToOne);
        assertEq(rExact, R_ONE, "exactly back to target must report ONE");
        assertEq(outExact, s.B - s.B0, "back-to-one output must be exactly the spare base");
        _sameSellQuote(s, backToOne);

        (, uint8 rOver) = port.sellQuote(s.i, s.k, s.B, s.Q, s.B0, s.Q0, s.R, backToOne + 1);
        assertEq(rOver, R_ABOVE_ONE, "crossing the target must land ABOVE_ONE");
        _sameSellQuote(s, backToOne + 1);
    }

    /// Fuzz the boundary itself rather than one hand-picked state.
    function testFuzz_CrossingBoundary(uint256 iRaw, uint256 kRaw, uint256 b0Raw, uint256 seedRaw) public view {
        St memory s = _canonicalAbove(_boundState(iRaw, bound(kRaw, 0, ONE), b0Raw), seedRaw);
        uint256 backToOne = s.B0 - s.B;
        vm.assume(backToOne > 1);
        _sameSellBase(s, backToOne - 1);
        _sameSellBase(s, backToOne);
        _sameSellBase(s, backToOne + 1);
    }

    /// The reference's "[Important corner case!]" clamp: when precision would otherwise
    /// hand out more than the spare inventory, it caps the output at back-to-one. A
    /// synthetic state with a target barely off the balance reaches it.
    function test_CornerCaseClamp() public view {
        uint256 i = 3_000e18;
        uint256 b0 = 10e18;
        uint256 q0 = 30_000e18;
        // Q is one wei above Q0, so spare quote is 1 wei while the integral wants more.
        St memory s = St({ i: i, k: 0.5e18, B: b0 - 1e17, Q: q0 + 1, B0: b0, Q0: q0, R: R_ABOVE_ONE });
        uint256 backToOnePayBase = s.B0 - s.B;
        (uint256 out, uint8 newR) = port.sellBase(s.i, s.k, s.B, s.Q, s.B0, s.Q0, s.R, backToOnePayBase - 1);
        assertLe(out, s.Q - s.Q0, "clamp must not hand out more than the spare quote");
        assertEq(newR, R_ABOVE_ONE);
        _sameSellBase(s, backToOnePayBase - 1);
        console2.log("clamped output (spare quote was 1 wei):", out);
    }

    // ============================================================================
    // P1 — adjustedTarget and getMidPrice
    // ============================================================================

    function testFuzz_AdjustTarget_AllStates(uint256 iRaw, uint256 kRaw, uint256 b0Raw, uint256 seedRaw) public view {
        St memory s = _boundState(iRaw, bound(kRaw, 0, ONE), b0Raw);
        _sameAdjustTarget(s);
        _sameAdjustTarget(_canonicalAbove(s, seedRaw));
        _sameAdjustTarget(_canonicalBelow(s, seedRaw));
    }

    function testFuzz_MidPrice_AllStates(uint256 iRaw, uint256 kRaw, uint256 b0Raw, uint256 seedRaw) public view {
        St memory s = _boundState(iRaw, bound(kRaw, 0, ONE), b0Raw);
        _sameMidPrice(s);
        _sameMidPrice(_canonicalAbove(s, seedRaw));
        _sameMidPrice(_canonicalBelow(s, seedRaw));
    }

    /// At exact equilibrium the mid price is the anchor itself. Pinned because it is the
    /// one value a human can check by eye in a console.
    function test_MidPrice_AtTargetEqualsAnchor() public view {
        St memory s = _one(3_000e18, 0.1e18, 10e18);
        assertEq(port.midPrice(s.i, s.k, s.B, s.Q, s.B0, s.Q0, s.R), s.i, "mid at target must equal the anchor");
        _sameMidPrice(s);
    }

    /// adjustedTarget touches ONE leg and leaves the other alone; at R = ONE it does nothing.
    function test_AdjustTarget_NoOpAtOne() public view {
        St memory s = _one(3_000e18, 0.1e18, 10e18);
        (uint256 nb0, uint256 nq0) = port.adjustTarget(s.i, s.k, s.B, s.Q, s.B0, s.Q0, s.R);
        assertEq(nb0, s.B0);
        assertEq(nq0, s.Q0);
        _sameAdjustTarget(s);
    }

    // ============================================================================
    // P2 exact-in — maker-favouring rounding, both orientations
    // ============================================================================

    /// The oracle here is neither implementation. The PMM curve is HOMOGENEOUS OF DEGREE
    /// ONE in (B, Q, B0, Q0, delta) at fixed (i, k): scaling every amount by S scales the
    /// output by exactly S in real arithmetic. Evaluating the same trade at 1e6x scale and
    /// dividing back therefore yields ~6 more correct digits, independently of how either
    /// implementation rounds.
    ///
    /// FINDING — gate P2's exact-in "maker-favouring rounding bound" DOES NOT HOLD for
    /// this curve, and the milestone card's "output rounds down" assumption is wrong.
    /// `_SolveQuadraticFunctionForTrade` floors `bAbs`, floors `(k*V0)/V1` before
    /// multiplying it back up by V0, and floors the square root. All three understate the
    /// numerator, which understates V2, which OVERSTATES the output handed to the taker.
    /// The closing `divCeil` on V2 claws back less than one wei of that.
    ///
    /// The size of the overshoot is governed by 1/(1-k), because V2 = numerator/(2(1-k)):
    ///
    ///     1-k (wei)   worst relative overshoot   (anchor 3000e18, B0 10e18, 1e18 base in)
    ///     1           8.3e-05
    ///     100         8.3e-07
    ///     1e5         1.0e-09
    ///     1e9         1.4e-13
    ///     >= 1e12     0        (exact)
    ///
    /// and it compounds with a small book: at 1-k = 3 with B0 = 1e12 wei the port and the
    /// reference agree with each other exactly, and both return 4.1x the correct output.
    /// That case is pinned below in test_P2_NotMakerFavouring_TheViolation.
    ///
    /// CONSEQUENCE FOR BASTION, to carry into milestone 3: `k` must be constrained away
    /// from 1e18 (k = 1e18 exactly is fine — it is a separate closed form with no
    /// quadratic), and rounding is not a solvency control. The maker-wide output caps of
    /// B1/B2 are what bound giveaway, not the curve's arithmetic.
    ///
    /// DECLARED ENVELOPE. Two error sources drive the deviation, and the envelope below
    /// carries one term for each:
    ///   * `mulFloor(k, V0) * V0` inside the 4(1-k)kV0^2 term floors BEFORE multiplying
    ///     back up by V0, so its absolute error scales with the leg's target V0.
    ///   * V2 = numerator * 1e18 / (2*(1e18-k)), so every wei of numerator error is
    ///     amplified by 1/(1-k).
    ///
    ///     |output - exact|  <=  8  +  V0/1e12  +  2e18/(1e18 - k)      [k <= 0.999e18]
    ///
    /// where V0 is the target of the leg being solved (B0 selling quote, Q0 selling base).
    /// The SHAPE is derived; the two coefficients are EMPIRICAL, chosen so that repeated
    /// fuzzing cannot break them. This is a structural guard, not a tight estimate — gate
    /// P1's exact equality against the reference is the tight test. Outside the band the
    /// envelope does not hold at all, which is the finding, pinned below.
    uint256 internal constant P2_SCALE = 1e6;
    /// @dev k = 1e18 is a separate exact closed form; this band is the quadratic branch.
    uint256 internal constant P2_K_MAX = 0.999e18;
    uint256 internal constant P2_LEG_MIN = 1e15;
    uint256 internal constant P2_ABS_FLOOR = 8;
    /// @dev The oracle floors once more when dividing back, so allow one wei under.
    uint256 internal constant P2_UNDERSHOOT = 2;

    function _p2Allowance(uint256 v0, uint256 k) internal pure returns (uint256) {
        return P2_ABS_FLOOR + v0 / 1e12 + (2 * ONE) / (ONE - k);
    }

    function _p2Check(uint256 small, uint256 precise, uint256 v0, uint256 k) internal pure {
        if (small > precise) {
            assertLe(small - precise, _p2Allowance(v0, k), "overshoot exceeded the declared envelope");
        } else {
            assertLe(precise - small, P2_UNDERSHOOT, "output fell further below the exact answer than declared");
        }
    }

    /// Construct a state inside the band, rather than rejecting into it with vm.assume:
    /// both legs at least P2_LEG_MIN, and both small enough that the 1e6x scaled copy
    /// still fits under LEG_MAX.
    function _p2State(uint256 iRaw, uint256 kRaw, uint256 b0Raw) internal pure returns (St memory) {
        uint256 i = bound(iRaw, I_MIN, I_MAX);
        uint256 lo = (P2_LEG_MIN * ONE) / i; // so Q0 = B0 * i / 1e18 >= P2_LEG_MIN
        if (lo < P2_LEG_MIN) lo = P2_LEG_MIN;
        uint256 hi = LEG_MAX / P2_SCALE; // so B0 * P2_SCALE stays under LEG_MAX
        uint256 capQ = ((LEG_MAX / P2_SCALE) * ONE) / i; // so Q0 * P2_SCALE does too
        if (capQ < hi) hi = capQ;
        if (hi < lo) hi = lo;
        return _one(i, bound(kRaw, 0, P2_K_MAX), bound(b0Raw, lo, hi));
    }

    function testFuzz_P2_SellQuote_DeviationInSafeBand(uint256 iRaw, uint256 kRaw, uint256 b0Raw, uint256 payRaw)
        public
        view
    {
        St memory s = _p2State(iRaw, kRaw, b0Raw);
        uint256 pay = bound(payRaw, 1, 4 * s.Q0);

        (bool okS, uint256 small) = _tryPortSellQuote(s, pay);
        (bool okB, uint256 big) = _tryPortSellQuote(_scaled(s, P2_SCALE), pay * P2_SCALE);
        vm.assume(okS && okB);
        _p2Check(small, big / P2_SCALE, s.B0, s.k);
    }

    function testFuzz_P2_SellBase_DeviationInSafeBand(uint256 iRaw, uint256 kRaw, uint256 b0Raw, uint256 payRaw)
        public
        view
    {
        St memory s = _p2State(iRaw, kRaw, b0Raw);
        uint256 pay = bound(payRaw, 1, 4 * s.B0);

        (bool okS, uint256 small) = _tryPortSellBase(s, pay);
        (bool okB, uint256 big) = _tryPortSellBase(_scaled(s, P2_SCALE), pay * P2_SCALE);
        vm.assume(okS && okB);
        _p2Check(small, big / P2_SCALE, s.Q0, s.k);
    }

    /// THE VIOLATION, pinned with concrete numbers so that it cannot quietly disappear and
    /// so that any future "fix" to the port fails loudly here. Port and reference agree
    /// exactly (P1 holds); both are far from the exact real answer (P2 exact-in does not).
    function test_P2_NotMakerFavouring_TheViolation() public view {
        uint256 anchor = 530_286_172_950_154_960_612_151; // ~530,286 quote per base
        uint256 k = ONE - 3; // three wei short of 1: the worst regime
        uint256 b0 = 1_000_000_000_001; // a dust book, 1e-6 base at 18 dp
        uint256 q0 = (b0 * anchor) / ONE;
        uint256 pay = 98_556_284_614; // base in
        St memory s = St({ i: anchor, k: k, B: b0, Q: q0, B0: b0, Q0: q0, R: R_ONE });

        // P1 still holds here: the port is not the thing that is wrong.
        _sameSellBase(s, pay);

        (, uint256 got) = _tryPortSellBase(s, pay);
        (, uint256 scaled) = _tryPortSellBase(_scaled(s, P2_SCALE), pay * P2_SCALE);
        uint256 precise = scaled / P2_SCALE;

        assertGt(got, precise, "expected the documented overshoot");
        assertGt(got, precise * 4, "the documented case overshoots by more than 4x");
        console2.log("P2 violation, 1-k = 3 wei on a 1e12-wei book:");
        console2.log("  output returned by BOTH implementations:", got);
        console2.log("  high-precision (1e6x) answer:           ", precise);
        console2.log("  overshoot, x1000 relative:              ", ((got - precise) * 1000) / precise);
    }

    /// The same curve away from the bad regime behaves. Sweeping 1-k on one fixed, normal
    /// book shows the deviation shrinking with 1/(1-k) — evidence that the amplification,
    /// not the port, is the cause. Every step is also checked against the reference.
    function test_P2_DeviationShrinksAwayFromKOne() public view {
        uint256[5] memory gaps = [uint256(1), 1e2, 1e5, 1e9, 1e12];
        uint256 previous = type(uint256).max;
        for (uint256 n = 0; n < gaps.length; ++n) {
            St memory s = _one(3_000e18, ONE - gaps[n], 10e18);
            _sameSellBase(s, 1e18);
            (, uint256 got) = _tryPortSellBase(s, 1e18);
            (, uint256 scaled) = _tryPortSellBase(_scaled(s, P2_SCALE), 1e18 * P2_SCALE);
            uint256 precise = scaled / P2_SCALE;
            uint256 dev = got > precise ? got - precise : precise - got;
            console2.log("  1-k =", gaps[n], "deviation (wei) =", dev);
            assertLe(dev, previous, "deviation grew as k moved away from 1");
            assertLe(dev, _p2Allowance(s.Q0, s.k), "deviation exceeded the declared envelope");
            previous = dev;
        }
    }

    /// k = 0 is the one branch that IS exactly maker-favouring: a flat multiply floored
    /// once, capped at the reserve. Both orientations.
    function testFuzz_P2_KZero_IsExactlyFloored(uint256 iRaw, uint256 b0Raw, uint256 payRaw) public view {
        St memory s = _boundState(iRaw, 0, b0Raw);

        uint256 payQ = bound(payRaw, 1, 2 * s.Q0);
        (bool okQ, uint256 outB) = _tryPortSellQuote(s, payQ);
        vm.assume(okQ);
        uint256 flatB = ((ONE2 / s.i) * payQ) / ONE;
        assertEq(outB, flatB > s.B0 ? s.B0 : flatB, "k=0 quote-in is not the floored flat price");

        uint256 payB = bound(payRaw, 1, 2 * s.B0);
        (bool okB2, uint256 outQ) = _tryPortSellBase(s, payB);
        vm.assume(okB2);
        uint256 flatQ = (s.i * payB) / ONE;
        assertEq(outQ, flatQ > s.Q0 ? s.Q0 : flatQ, "k=0 base-in is not the floored flat price");
    }

    /// Report the worst deviation actually seen over a deterministic in-band sample, so
    /// the safe-band claim above is a measurement in this repository, not a quoted number.
    function test_P2_MeasuredDeviationInSafeBand() public view {
        uint256 worstOver;
        uint256 worstRel;
        uint256 worstUnder;
        uint256 seed = 0x9e3779b97f4a7c15;
        for (uint256 n = 0; n < 256; ++n) {
            seed = uint256(keccak256(abi.encode(seed, n)));
            uint256 k = seed % P2_K_MAX;
            uint256 i = I_MIN + (uint256(keccak256(abi.encode(seed, "i"))) % (1e22 - I_MIN));
            uint256 b0 = P2_LEG_MIN + (uint256(keccak256(abi.encode(seed, "b"))) % 1e21);
            uint256 q0 = (b0 * i) / ONE;
            if (q0 < P2_LEG_MIN || q0 > LEG_MAX / P2_SCALE || b0 > LEG_MAX / P2_SCALE) continue;
            uint256 pay = 1 + (uint256(keccak256(abi.encode(seed, "p"))) % (4 * q0));

            St memory st = St({ i: i, k: k, B: b0, Q: q0, B0: b0, Q0: q0, R: R_ONE });
            (bool okS, uint256 small) = _tryPortSellQuote(st, pay);
            (bool okB, uint256 big) = _tryPortSellQuote(_scaled(st, P2_SCALE), pay * P2_SCALE);
            if (!okS || !okB) continue;
            uint256 precise = big / P2_SCALE;
            if (small > precise) {
                uint256 d = small - precise;
                if (d > worstOver) worstOver = d;
                uint256 rel = precise == 0 ? 0 : (d * 1e18) / precise;
                if (rel > worstRel) worstRel = rel;
            } else if (precise - small > worstUnder) {
                worstUnder = precise - small;
            }
            _p2Check(small, precise, b0, k);
        }
        console2.log("P2 in-band, 256 deterministic samples, sellQuote:");
        console2.log("  worst overshoot (wei)            ", worstOver);
        console2.log("  worst overshoot, relative x 1e18 ", worstRel);
        console2.log("  worst undershoot (wei)           ", worstUnder);
    }

    /// Paying more must never return less. A taker who cannot rely on this can be made
    /// worse off by rounding alone.
    function testFuzz_P2_Monotonic(uint256 iRaw, uint256 kRaw, uint256 b0Raw, uint256 payRaw, uint256 bumpRaw)
        public
        view
    {
        St memory s = _boundState(iRaw, bound(kRaw, 0, ONE), b0Raw);
        uint256 pay = bound(payRaw, 0, 2 * s.Q0);
        uint256 bump = bound(bumpRaw, 1, s.Q0 + 1);

        (bool o1, uint256 less) = _tryPortSellQuote(s, pay);
        (bool o2, uint256 more) = _tryPortSellQuote(s, pay + bump);
        if (o1 && o2) assertGe(more, less, "paying more returned less base");

        uint256 payB = bound(payRaw, 0, 2 * s.B0);
        uint256 bumpB = bound(bumpRaw, 1, s.B0 + 1);
        (bool o3, uint256 lessB) = _tryPortSellBase(s, payB);
        (bool o4, uint256 moreB) = _tryPortSellBase(s, payB + bumpB);
        if (o3 && o4) assertGe(moreB, lessB, "paying more returned less quote");
        vm.assume((o1 && o2) || (o3 && o4));
    }

    /// Output can never exceed what the maker holds against it, in either direction. This
    /// is the property the overshoot above could threaten, so it is asserted separately.
    function testFuzz_P2_OutputBoundedByReserve(uint256 iRaw, uint256 kRaw, uint256 b0Raw, uint256 payRaw)
        public
        view
    {
        St memory s = _boundState(iRaw, bound(kRaw, 0, ONE), b0Raw);

        (bool okQ, uint256 outBase) = _tryPortSellQuote(s, bound(payRaw, 0, 10 * s.Q0));
        if (okQ) assertLe(outBase, s.B0, "handed out more base than the target");

        (bool okB, uint256 outQuote) = _tryPortSellBase(s, bound(payRaw, 0, 10 * s.B0));
        if (okB) assertLe(outQuote, s.Q0, "handed out more quote than the target");
        vm.assume(okQ || okB);
    }

    /// At equilibrium the PMM must never beat the anchor for the taker, in either
    /// direction. (This holds AT the target; away from it a rebalancing trade can and
    /// should price better than the anchor, so the assertion is scoped to R = ONE.)
    function test_P2_NeverBetterThanAnchorAtTarget() public view {
        uint256 i = 3_000e18;
        uint256 b0 = 10e18;
        uint256 q0 = 30_000e18;

        uint256 payQ = 3_000e18;
        (uint256 outBase,) = port.sellQuote(i, 0.1e18, b0, q0, b0, q0, R_ONE, payQ);
        assertLt(outBase, (payQ * ONE) / i, "quote-in beat the anchor at target");

        uint256 payB = 1e18;
        (uint256 outQuote,) = port.sellBase(i, 0.1e18, b0, q0, b0, q0, R_ONE, payB);
        assertLt(outQuote, (payB * i) / ONE, "base-in beat the anchor at target");
    }

    function test_P2_ZeroInZeroOut() public view {
        St memory s = _one(3_000e18, 0.1e18, 10e18);
        (uint256 a,) = port.sellQuote(s.i, s.k, s.B, s.Q, s.B0, s.Q0, s.R, 0);
        (uint256 b,) = port.sellBase(s.i, s.k, s.B, s.Q, s.B0, s.Q0, s.R, 0);
        assertEq(a, 0);
        assertEq(b, 0);
        _sameSellQuote(s, 0);
        _sameSellBase(s, 0);
    }

    // ============================================================================
    // boundaries
    // ============================================================================

    /// One wei in. Rounding down means the taker may receive nothing; whatever the
    /// reference does, the port must do the same.
    function test_DustPay() public view {
        St memory s = _one(3_000e18, 0.1e18, 10e18);
        _sameSellQuote(s, 1);
        _sameSellBase(s, 1);
    }

    /// A fill far larger than the book, in both directions.
    function test_PayFarAboveTarget() public view {
        St memory s = _one(3_000e18, 0.1e18, 10e18);
        _sameSellQuote(s, 1_000_000e18);
        _sameSellBase(s, 1_000e18);
    }

    function test_KZeroAndKOne_Fixed() public view {
        _sameSellQuote(_one(3_000e18, 0, 10e18), 1_500e18);
        _sameSellQuote(_one(3_000e18, ONE, 10e18), 1_500e18);
        _sameSellBase(_one(3_000e18, 0, 10e18), 0.5e18);
        _sameSellBase(_one(3_000e18, ONE, 10e18), 0.5e18);
    }

    /// The reference refuses some perfectly ordinary-looking trades. When `k * V0 / 1e18`
    /// floors to zero — a small target with a near-zero curvature — the 4(1-k)kV0^2 term
    /// vanishes, sqrt(bAbs^2) returns bAbs exactly, and the numerator is zero, so DODO
    /// reverts "DODOMath: should not be zero". The port must refuse the same way: same
    /// string, not a panic and not a number. Numbers below are the reproduced case.
    ///
    /// This matters past milestone 2: the router at M3 will meet this revert on a live
    /// quote path and must surface it, not treat it as a zero quote.
    function test_ReferenceRefusal_BothRevertIdentically() public view {
        uint256 anchor = 3_000e18;
        uint256 k = 1; // one wei of curvature
        uint256 b0 = 1e12; // 0.000001 base at 18 dp
        uint256 q0 = (b0 * anchor) / ONE; // 3e15
        St memory s = St({ i: anchor, k: k, B: b0, Q: q0, B0: b0, Q0: q0, R: R_ONE });

        bytes memory cd = abi.encodeCall(IPMMHarness.sellQuote, (s.i, s.k, s.B, s.Q, s.B0, s.Q0, s.R, 4 * q0));
        (bool refOk, bytes memory refData) = address(ref).staticcall(cd);
        (bool portOk, bytes memory portData) = address(port).staticcall(cd);

        assertFalse(refOk, "the reference is expected to refuse this trade");
        assertFalse(portOk, "the port must refuse it too");
        assertEq(portData, refData, "refusal must be byte-identical, not a panic");
        assertEq(
            refData,
            abi.encodeWithSignature("Error(string)", "DODOMath: should not be zero"),
            "unexpected refusal reason"
        );
    }

    /// Outside the declared domain both sides refuse, but the revert DATA differs:
    /// SafeMath's "MUL_ERROR" string at 0.6.9 versus 0.8's Panic(0x11). Porting rule 1.
    function test_OutsideDomain_BothRevert_ButRevertDataDiffers() public view {
        bytes memory cd = abi.encodeCall(IPMMHarness.sellQuote, (1, 0.5e18, 1e18, 1e18, 1e18, 1e18, R_ONE, 1e60));
        (bool refOk, bytes memory refData) = address(ref).staticcall(cd);
        (bool portOk, bytes memory portData) = address(port).staticcall(cd);
        assertFalse(refOk, "reference should overflow here");
        assertFalse(portOk, "port should overflow here");
        assertTrue(keccak256(refData) != keccak256(portData), "revert data unexpectedly identical");
        console2.log("reference revert data:");
        console2.logBytes(refData);
        console2.log("port revert data (Panic 0x11):");
        console2.logBytes(portData);
    }

    // ============================================================================
    // Scale — 6/18 decimal normalisation of the anchor (spec 5.2 priceWad)
    // ============================================================================

    /// The fixture pair from the milestone 1 smoke test: fWETH at 18 dp, fUSDC at 6 dp.
    /// A maker who signs the human price without normalising is off by 1e12.
    function test_Scale_WethUsdc() public view {
        uint256 human = 3_000e18; // 3,000 USDC per WETH
        uint256 i = port.toAnchorWad(human, 18, 6);
        assertEq(i, 3_000e6, "3,000 USDC/WETH must normalise to 3e9");

        // and it prices in raw units: at k = 0 the flat branch returns exactly i*delta/1e18
        uint256 b0 = 10e18; // 10 fWETH
        uint256 q0 = (b0 * i) / ONE; // 30,000e6 fUSDC
        assertEq(q0, 30_000e6, "the quote leg must be 30,000.000000 USDC");

        (uint256 outQuote,) = port.sellBase(i, 0, b0, q0, b0, q0, R_ONE, 1e18); // sell 1 fWETH
        assertEq(outQuote, 3_000e6, "1 WETH at k=0 must return exactly 3,000 USDC");
        _sameSellBase(St({ i: i, k: 0, B: b0, Q: q0, B0: b0, Q0: q0, R: R_ONE }), 1e18);

        // the same state on the real curve still agrees with the reference
        _sameEverything(St({ i: i, k: 0.1e18, B: b0, Q: q0, B0: b0, Q0: q0, R: R_ONE }), 1e18, 3_000e6);
        console2.log("fWETH/fUSDC anchor i =", i, "for human price", human);
    }

    /// Same decimals is the identity; a bigger quote leg multiplies.
    function test_Scale_OtherPairs() public view {
        assertEq(port.toAnchorWad(3_000e18, 18, 18), 3_000e18, "18/18 must be the identity");
        assertEq(port.toAnchorWad(1e18, 8, 18), 1e28, "8 dp base against 18 dp quote scales up by 1e10");
        assertEq(port.toHumanPriceWad(3_000e6, 18, 6), 3_000e18, "display must invert the 6 dp case");
    }

    /// The round trip is lossy exactly where the header says it is, never rounds up, and
    /// refuses rather than silently returning a zero anchor when the loss is total.
    function testFuzz_Scale_RoundTripNeverRoundsUp(uint256 humanRaw, uint8 baseRaw, uint8 quoteRaw) public {
        uint8 baseDec = uint8(bound(baseRaw, 0, 36));
        uint8 quoteDec = uint8(bound(quoteRaw, 0, 36));
        uint256 human = bound(humanRaw, 1e18, 1e30);

        if (baseDec > quoteDec && human < 10 ** uint256(baseDec - quoteDec)) {
            // normalisation would floor the anchor to zero; the curve would then divide
            // by it, so Scale must refuse here rather than hand back 0.
            vm.expectRevert(Scale.PriceUnderflow.selector);
            port.toAnchorWad(human, baseDec, quoteDec);
            return;
        }

        uint256 i = port.toAnchorWad(human, baseDec, quoteDec);
        assertGt(i, 0, "a surviving anchor must be non-zero");
        uint256 back = port.toHumanPriceWad(i, baseDec, quoteDec);
        assertLe(back, human, "round trip rounded UP");
        if (quoteDec >= baseDec) assertEq(back, human, "the multiplying direction is lossless");
    }

    function test_Scale_Reverts() public {
        vm.expectRevert(abi.encodeWithSelector(Scale.DecimalsOutOfRange.selector, uint8(37)));
        port.toAnchorWad(3_000e18, 37, 6);

        // a price so small that 18->0 decimal loss floors it to zero
        vm.expectRevert(Scale.PriceUnderflow.selector);
        port.toAnchorWad(1e17, 18, 0);
    }

    // ============================================================================
    // gas
    // ============================================================================

    /// Per-call gas for the port, measured at a representative off-target state. These are
    /// EXTERNAL calls into a wrapper, so they include ~2,100 of call overhead and ABI
    /// coding; the library itself is `internal` and will be inlined by its caller. Recorded
    /// as a baseline for gate D1, not as a budget.
    function test_GasPerCall() public view {
        St memory s = _canonicalAbove(_one(3_000e18, 0.1e18, 10e18), 1_000e18);
        uint256 g;

        g = gasleft();
        port.sellQuote(s.i, s.k, s.B, s.Q, s.B0, s.Q0, s.R, 1_000e18);
        console2.log("gas sellQuote   (ABOVE_ONE, k=0.1):", g - gasleft());

        g = gasleft();
        port.sellBase(s.i, s.k, s.B, s.Q, s.B0, s.Q0, s.R, 1e18);
        console2.log("gas sellBase    (ABOVE_ONE, k=0.1):", g - gasleft());

        g = gasleft();
        port.adjustTarget(s.i, s.k, s.B, s.Q, s.B0, s.Q0, s.R);
        console2.log("gas adjustTarget(ABOVE_ONE, k=0.1):", g - gasleft());

        g = gasleft();
        port.midPrice(s.i, s.k, s.B, s.Q, s.B0, s.Q0, s.R);
        console2.log("gas midPrice    (ABOVE_ONE, k=0.1):", g - gasleft());

        St memory one = _one(3_000e18, 0.1e18, 10e18);
        g = gasleft();
        port.sellQuote(one.i, one.k, one.B, one.Q, one.B0, one.Q0, one.R, 1_000e18);
        console2.log("gas sellQuote   (ONE, k=0.1):      ", g - gasleft());
    }

    // ============================================================================
    // the worked example carried forward from increment 1
    // ============================================================================

    /// The 30 bps split is arithmetic done HERE, in the test, purely to show the units a
    /// fill decomposes into. PMMMath charges no fee and knows nothing about one: fees are
    /// FeeFlatIn at milestone 3, and fee reinvestment into the ledger is increment 3.
    function test_WorkedExample_ROneSellQuote() public view {
        uint256 i = 3_000e18;
        uint256 k = 0.1e18;
        uint256 b0 = 10e18;
        uint256 q0 = 30_000e18;

        uint256 grossIn = 3_000e18;
        uint256 feeIn = (grossIn * 30) / 10_000;
        uint256 curveIn = grossIn - feeIn;

        (uint256 refOut, uint8 refR) = ref.sellQuote(i, k, b0, q0, b0, q0, R_ONE, curveIn);
        (uint256 portOut, uint8 portR) = port.sellQuote(i, k, b0, q0, b0, q0, R_ONE, curveIn);

        console2.log("i   (quote per base, wad) ", i);
        console2.log("k   (flatness, wad)       ", k);
        console2.log("B0 = B (base)             ", b0);
        console2.log("Q0 = Q (quote)            ", q0);
        console2.log("gross in  (quote)         ", grossIn);
        console2.log("fee 30bps (quote)         ", feeIn);
        console2.log("curve in  (quote)         ", curveIn);
        console2.log("reference out (base)      ", refOut);
        console2.log("port      out (base)      ", portOut);
        console2.log("reference next R          ", refR);
        console2.log("port      next R          ", portR);
        console2.log("effective price, quote per base (wad)", (curveIn * ONE) / portOut);

        assertEq(portOut, refOut, "output differs from the reference");
        assertEq(portR, refR, "next R differs from the reference");
        assertEq(portR, R_ABOVE_ONE, "selling quote from ONE must leave the maker ABOVE_ONE");
        assertGt(portOut, 0, "a 3,000 quote fill must return base");
    }
}

// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// BASTION — milestone 3 increment 2. THE PRODUCT CLAIM, and the first time tokens move.
///
/// One question: does a real, Aqua-settled fill on book A change what book B quotes, through
/// contract state rather than through anything a UI coordinates?
///
/// The distinguishing detail is in test_FillOnAMovesQuoteOnB: after the fill, B's own Aqua
/// virtual balances are UNCHANGED — nothing was shipped, docked or re-priced on B, and no
/// transaction touched it — yet B's quote moves, by exactly the amount the milestone 2
/// library predicts from the new shared state. That is the difference between shared pricing
/// state and two independent books that happen to look alike.
///
/// Everything here is in-process against the same unmodified Aqua the upstream suite uses.
/// The anvil run with real transaction hashes is scripts/anvil-bastion.sh.
///
/// NOT covered: budgets binding, mandates, the maker lock, settlement-trait validation,
/// access control. None of them exist yet.

import { BastionTestBase } from "./BastionTestBase.sol";
import { ISwapVM } from "../../src/interfaces/ISwapVM.sol";
import { PMMMath } from "../../src/bastion/pmm/PMMMath.sol";
import { PMMState } from "../../src/bastion/pmm/PMMState.sol";

contract BastionSharedStateTest is BastionTestBase {
    ISwapVM.Order internal bookA;
    ISwapVM.Order internal bookB;
    bytes32 internal hashA;
    bytes32 internal hashB;

    /// Bob sells 3,000 quote into book A.
    uint256 internal constant FILL = 3_000e18;
    /// The amount book B is quoted at, before and after, so the two are comparable.
    uint256 internal constant PROBE = 1_000e18;

    function setUp() public override {
        super.setUp();
        _openGroup();
        bookA = createStrategy(_bastionProgram(1));
        bookB = createStrategy(_bastionProgram(2));
        hashA = _ship(bookA);
        hashB = _ship(bookB);
        _admit(hashA);
        _admit(hashB);
        _post(ANCHOR, 1, uint64(block.timestamp + 1 hours));
    }

    function _state() internal view returns (PMMMath.PMMState memory s) {
        (uint256 i, uint256 k, uint256 b, uint256 q, uint256 b0, uint256 q0, uint8 r) =
            desk.riskGroupState(maker, GROUP_ID);
        s = PMMMath.PMMState({ i: i, K: k, B: b, Q: q, B0: b0, Q0: q0, R: PMMMath.RState(r) });
    }

    function _quoteB(uint256 amount) internal view returns (uint256 out) {
        (, out,) = desk.asView().quote(bookB, amount, _traits(false));
    }

    // ============ gate P5 ============

    /// A fill on A changes B's next quote, with no transaction on B and no change to B's own
    /// Aqua balances. Under one unchanged anchor.
    function test_FillOnAMovesQuoteOnB() public {
        uint256 quoteBefore = _quoteB(PROBE);
        (uint256 aquaB_A_before, uint256 aquaB_B_before) = getAquaBalances(hashB);
        PMMMath.PMMState memory stateBefore = _state();

        // Bob really fills A: tokens move through unmodified Aqua settlement.
        vm.prank(address(this));
        (uint256 amountIn, uint256 amountOut) = taker.swap(bookA, FILL, _swapTraits(false));
        assertEq(amountIn, FILL, "exact-in must take exactly what was asked");
        assertGt(amountOut, 0, "the fill returned nothing");

        uint256 quoteAfter = _quoteB(PROBE);
        (uint256 aquaB_A_after, uint256 aquaB_B_after) = getAquaBalances(hashB);
        PMMMath.PMMState memory stateAfter = _state();

        // 1. the shared state moved
        assertTrue(
            keccak256(abi.encode(stateBefore)) != keccak256(abi.encode(stateAfter)),
            "the fill did not move the shared state"
        );

        // 2. B's quote moved with it, and moved the right way: Bob bought base from the
        //    desk, so base is now scarcer and a quote-in fill buys less of it.
        assertTrue(quoteAfter != quoteBefore, "B's quote did not change after a fill on A");
        assertLt(quoteAfter, quoteBefore, "buying base should make base dearer on the sibling book");

        // 3. and it moved by exactly what the milestone 2 library predicts from the new state
        assertEq(
            quoteAfter,
            PMMState.quoteExactIn(stateAfter, false, _net(PROBE), 0),
            "B's new quote is not what the shared state implies"
        );

        // 4. THE POINT: nothing happened to B itself. No transaction, no shipping, no
        //    re-pricing, and its Aqua virtual balances are byte-identical.
        assertEq(aquaB_A_after, aquaB_A_before, "book B's Aqua base balance changed");
        assertEq(aquaB_B_after, aquaB_B_before, "book B's Aqua quote balance changed");

        emit log_named_uint("B quote before fill on A (base out for 1,000 quote in)", quoteBefore);
        emit log_named_uint("B quote after  fill on A", quoteAfter);
        emit log_named_uint("B quote delta", quoteBefore - quoteAfter);
    }

    /// @dev 30 bps the way FeeFlatIn applies it (ceilDiv at D = 1e7).
    function _net(uint256 gross) internal pure returns (uint256) {
        uint256 fee = (gross * FEE_30BPS + 1e7 - 1) / 1e7;
        return gross - fee;
    }

    // ============ gate S1: reconciliation ============

    /// Every number a fill produces has to agree with every other: what Bob paid, what Aqua
    /// credited, what the shared ledger absorbed, and what actually landed in the wallets.
    function test_SettlementReconciles() public {
        (uint256 aquaBaseBefore, uint256 aquaQuoteBefore) = getAquaBalances(hashA);
        PMMMath.PMMState memory before = _state();

        uint256 takerQuoteBefore = tokenB.balanceOf(address(taker));
        uint256 takerBaseBefore = tokenA.balanceOf(address(taker));
        uint256 makerQuoteBefore = tokenB.balanceOf(maker);
        uint256 makerBaseBefore = tokenA.balanceOf(maker);

        (uint256 amountIn, uint256 amountOut) = taker.swap(bookA, FILL, _swapTraits(false));

        (uint256 aquaBaseAfter, uint256 aquaQuoteAfter) = getAquaBalances(hashA);
        PMMMath.PMMState memory afterState = _state();

        // taker paid gross quote and received base
        assertEq(takerQuoteBefore - tokenB.balanceOf(address(taker)), amountIn, "taker did not pay amountIn");
        assertEq(tokenA.balanceOf(address(taker)) - takerBaseBefore, amountOut, "taker did not receive amountOut");

        // maker received gross quote and paid base — real ERC20 movement, not bookkeeping
        assertEq(tokenB.balanceOf(maker) - makerQuoteBefore, amountIn, "maker did not receive the input");
        assertEq(makerBaseBefore - tokenA.balanceOf(maker), amountOut, "maker did not pay the output");

        // Aqua's virtual balances for THIS book moved by the same amounts
        assertEq(aquaQuoteAfter - aquaQuoteBefore, amountIn, "Aqua credit != taker gross input");
        assertEq(aquaBaseBefore - aquaBaseAfter, amountOut, "Aqua debit != output");

        // and the shared pricing ledger absorbed the GROSS input, fee included
        assertEq(afterState.Q - before.Q, amountIn, "ledger input delta != taker gross input");
        assertEq(before.B - afterState.B, amountOut, "ledger output delta != output");

        emit log_named_uint("gross quote in  (= Aqua credit = ledger delta)", amountIn);
        emit log_named_uint("base out        (= Aqua debit  = recipient receipt)", amountOut);
    }

    // ============ gate Q1, the other half ============

    /// The quote a taker is shown is what execution delivers from the same state.
    function test_QuoteEqualsExecution() public {
        (, uint256 quoted,) = desk.asView().quote(bookA, FILL, _traits(false));
        (, uint256 executed) = taker.swap(bookA, FILL, _swapTraits(false));
        assertEq(executed, quoted, "execution did not deliver the quote");
    }

    /// Quoting never moves the curve, no matter how many times, and a quote taken after a
    /// sibling fill reads the NEW state (spec 5.1).
    function test_QuotesAreFreeAndReadTheNewState() public {
        bytes32 before = keccak256(abi.encode(_state()));
        for (uint256 n = 0; n < 5; ++n) {
            _quoteB(PROBE);
            desk.asView().quote(bookA, FILL, _traits(false));
        }
        assertEq(keccak256(abi.encode(_state())), before, "quoting moved the shared state");

        taker.swap(bookA, FILL, _swapTraits(false));
        assertEq(
            _quoteB(PROBE),
            PMMState.quoteExactIn(_state(), false, _net(PROBE), 0),
            "a quote after a sibling fill did not read the new state"
        );
    }

    // ============ gate P4, integrated and preliminary ============

    /// One fill of X on a single book against two fills of X/2 split across the two SIBLING
    /// books. PRELIMINARY: two books, one state, no routing, no access differences.
    ///
    /// This is the integrated form of milestone 2's finding — splitting does not pay the
    /// taker more — and it is the property that matters here, because sibling books are
    /// exactly what a taker could try to split across.
    function test_P4_SplittingAcrossSiblingBooksDoesNotPayMore() public {
        uint256 snapshot = vm.snapshotState();

        (, uint256 single) = taker.swap(bookA, FILL, _swapTraits(false));

        vm.revertToState(snapshot);

        (, uint256 firstHalf) = taker.swap(bookA, FILL / 2, _swapTraits(false));
        (, uint256 secondHalf) = taker.swap(bookB, FILL / 2, _swapTraits(false));
        uint256 split = firstHalf + secondHalf;

        assertLe(split, single, "splitting across sibling books paid the taker MORE");
        emit log_named_uint("single fill on A            (base out)", single);
        emit log_named_uint("split across A and B        (base out)", split);
        emit log_named_uint("shortfall from splitting    (base wei)", single - split);
    }

    /// The mirror direction settles too: Bob sells base and receives quote.
    function test_BaseInDirectionSettles() public {
        uint256 makerBaseBefore = tokenA.balanceOf(maker);
        (uint256 amountIn, uint256 amountOut) = taker.swap(bookA, 1e18, _swapTraits(true));
        assertEq(amountIn, 1e18);
        assertGt(amountOut, 0, "selling base returned no quote");
        assertEq(tokenA.balanceOf(maker) - makerBaseBefore, amountIn, "maker did not receive the base");

        PMMMath.PMMState memory s = _state();
        assertEq(s.B, LEDGER_BASE + amountIn, "ledger did not absorb the gross base input");
    }
}

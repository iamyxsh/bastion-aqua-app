// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// BASTION — milestone 3 increment 1: the Bastion router quotes the ported PMM from shared
/// state, through a real SwapVM program.
///
/// This is WIRING evidence, not pricing evidence. That the numbers are DODO's is gate P1 and
/// was settled in milestone 2 against the independently compiled 0.6.9 reference; nothing
/// here re-establishes it. What is new is that a program running inside the VM reaches the
/// same library, over state that persists per risk group.
///
/// NOT covered, because none of it exists yet: Aqua settlement (increment 2), the maker
/// lock, settlement-trait validation (increment 3), output budgets (increment 4), mandates
/// and access control (milestone 4).

import { BastionTestBase } from "./BastionTestBase.sol";
import { ISwapVM } from "../../src/interfaces/ISwapVM.sol";
import { Opcode } from "../../src/libs/OpcodeList.sol";
import { Salt } from "../../src/instructions/Controls.sol";
import { XYCSwap } from "../../src/instructions/XYCSwap.sol";

import { PMMMath } from "../../src/bastion/pmm/PMMMath.sol";
import { PMMState } from "../../src/bastion/pmm/PMMState.sol";
import { PortfolioLedger } from "../../src/bastion/instructions/PortfolioLedger.sol";
import { PortfolioSwap } from "../../src/bastion/instructions/PortfolioSwap.sol";
import { MakerPriceAnchor } from "../../src/bastion/instructions/MakerPriceAnchor.sol";

contract BastionPortfolioSwapTest is BastionTestBase {
    /// @dev 30 bps at upstream's D = 1e7, applied the way FeeFlatIn applies it (ceilDiv).
    function _net(uint256 gross) internal pure returns (uint256) {
        uint256 fee = (gross * FEE_30BPS + 1e7 - 1) / 1e7;
        return gross - fee;
    }

    function _state() internal view returns (PMMMath.PMMState memory s) {
        (uint256 i, uint256 k, uint256 b, uint256 q, uint256 b0, uint256 q0, uint8 r) =
            desk.riskGroupState(maker, GROUP_ID);
        s = PMMMath.PMMState({ i: i, K: k, B: b, Q: q, B0: b0, Q0: q0, R: PMMMath.RState(r) });
    }

    // ============ the wiring claim ============

    /// The router's quote equals the library's answer on the same stored state, in both
    /// directions. If these disagree, the VM path is reaching different state or a different
    /// curve than the one milestone 2 verified.
    function test_RouterQuoteEqualsTheLibrary() public {
        (ISwapVM.Order memory order,) = _liveBook(1);

        // quote in, base out
        uint256 grossQuoteIn = 3_000e18;
        (, uint256 amountOut,) = desk.asView().quote(order, grossQuoteIn, _traits(false));
        uint256 expected = PMMState.quoteExactIn(_state(), false, _net(grossQuoteIn), 0);
        assertEq(amountOut, expected, "quote-in: router and library disagree");
        assertGt(amountOut, 0, "a 3,000 quote fill must return base");

        // base in, quote out
        uint256 grossBaseIn = 1e18;
        (, uint256 amountOut2,) = desk.asView().quote(order, grossBaseIn, _traits(true));
        uint256 expected2 = PMMState.quoteExactIn(_state(), true, _net(grossBaseIn), 0);
        assertEq(amountOut2, expected2, "base-in: router and library disagree");
        assertGt(amountOut2, 0, "a 1 base fill must return quote");
    }

    /// Part of gate Q1: a static quote makes no writes. Proven by a real STATICCALL through
    /// `asView()`, not by trusting the `!isStaticContext` guard — a write would revert.
    function test_StaticQuoteWritesNothing() public {
        (ISwapVM.Order memory order,) = _liveBook(1);
        bytes32 before = keccak256(abi.encode(_state()));

        for (uint256 n = 0; n < 3; ++n) {
            desk.asView().quote(order, 3_000e18, _traits(false));
        }

        assertEq(keccak256(abi.encode(_state())), before, "a quote moved the shared state");
    }

    /// Two equivalent books over ONE risk group read the SAME state. This is the shape of
    /// the shared-state claim; the claim itself needs a real fill, which is increment 2.
    function test_SiblingBooksQuoteFromOneState() public {
        _openGroup();
        ISwapVM.Order memory bookA = createStrategy(_bastionProgram(1));
        ISwapVM.Order memory bookB = createStrategy(_bastionProgram(2));
        bytes32 hashA = _ship(bookA);
        bytes32 hashB = _ship(bookB);
        assertTrue(hashA != hashB, "different salts must give different books");

        _admit(hashA);
        _admit(hashB);
        _post(ANCHOR, 1, uint64(block.timestamp + 1 hours));

        assertEq(desk.bookGroup(hashA), desk.bookGroup(hashB), "books are not on one risk group");

        (, uint256 outA,) = desk.asView().quote(bookA, 3_000e18, _traits(false));
        (, uint256 outB,) = desk.asView().quote(bookB, 3_000e18, _traits(false));
        assertEq(outA, outB, "equivalent sibling books quoted differently from one state");
    }

    // ============ refusals ============

    /// A program that was never admitted cannot quote, even though its bytecode is valid and
    /// its opcodes exist. Admission — not the program text — is what makes a book Bastion's.
    function test_UnadmittedBookReverts() public {
        _openGroup();
        _post(ANCHOR, 1, uint64(block.timestamp + 1 hours));
        ISwapVM.Order memory order = createStrategy(_bastionProgram(7));
        bytes32 orderHash = _ship(order);
        ISwapVM v = desk.asView();
        bytes memory t = _traits(false);

        vm.expectRevert(abi.encodeWithSelector(PortfolioLedger.BookNotAdmitted.selector, orderHash));
        v.quote(order, 3_000e18, t);
    }

    /// Copying an admitted program and re-salting it produces a DIFFERENT order hash, which
    /// was never admitted. A copied Bastion book cannot quote. (Milestone 4 increment 3
    /// tests the rest of gate M2; this is the part that already holds.)
    function test_ResaltedCopyIsNotAdmitted() public {
        (ISwapVM.Order memory admitted,) = _liveBook(1);
        desk.asView().quote(admitted, 3_000e18, _traits(false)); // works

        ISwapVM.Order memory copy = createStrategy(_bastionProgram(999));
        bytes32 copyHash = _ship(copy);
        ISwapVM v = desk.asView();
        bytes memory t = _traits(false);
        vm.expectRevert(abi.encodeWithSelector(PortfolioLedger.BookNotAdmitted.selector, copyHash));
        v.quote(copy, 3_000e18, t);
    }

    /// Exact-out is refused in the VM, not hidden in a frontend. The DODO reference has no
    /// inverse, so the port has no function for it (spec 5.1, 17).
    function test_ExactOutReverts() public {
        (ISwapVM.Order memory order,) = _liveBook(1);
        ISwapVM v = desk.asView();
        bytes memory t = _exactOutTraits(false);
        vm.expectRevert(PortfolioSwap.ExactOutNotSupported.selector);
        v.quote(order, 1e18, t);
    }

    /// No anchor has been accepted yet: the desk cannot quote. Spec 5.3.
    function test_MissingAnchorReverts() public {
        _openGroup();
        ISwapVM.Order memory order = createStrategy(_bastionProgram(1));
        bytes32 orderHash = _ship(order);
        _admit(orderHash);
        ISwapVM v = desk.asView();
        bytes memory t = _traits(false);

        vm.expectRevert(abi.encodeWithSelector(MakerPriceAnchor.AnchorMissing.selector, orderHash));
        v.quote(order, 3_000e18, t);
    }

    /// The accepted anchor expired: quotes pause until a fresh one is published. There is no
    /// bypass, and time moving forward is enough to stop the desk.
    function test_StaleAnchorReverts() public {
        (ISwapVM.Order memory order,) = _liveBook(1);
        uint64 expiry = uint64(block.timestamp + 1 hours);
        uint64 afterExpiry = expiry + 1;

        vm.warp(afterExpiry);
        ISwapVM v = desk.asView();
        bytes memory t = _traits(false);
        vm.expectRevert(abi.encodeWithSelector(MakerPriceAnchor.AnchorStale.selector, expiry, afterExpiry));
        v.quote(order, 3_000e18, t);

        // A fresh update restores eligibility (explicit pause is milestone 5). The new expiry
        // is derived from `afterExpiry` rather than re-reading block.timestamp: under the
        // optimizer, repeated TIMESTAMP reads in one function are common-subexpression
        // eliminated, so a read after vm.warp still yields the pre-warp value.
        _post(ANCHOR, 2, afterExpiry + 1 hours);
        (, uint256 amountOut,) = desk.asView().quote(order, 3_000e18, _traits(false));
        assertGt(amountOut, 0, "a fresh anchor should restore quoting");
    }

    /// A book whose pair is not the risk group's pair is refused rather than mispriced.
    function test_WrongPairReverts() public {
        _openGroup();
        // admit a book that trades the same tokens the fixture built, but register the group
        // against a third token so the pair no longer matches.
        vm.prank(address(0xBEEF));
        desk.initRiskGroup(
            bytes32(uint256(2)), address(tokenB), address(0xCAFE), K, anchorSigner, ANCHOR, 1e18, 1e18
        );

        ISwapVM.Order memory order = createStrategy(_bastionProgram(3));
        bytes32 orderHash = _ship(order);
        vm.prank(address(0xBEEF));
        desk.admitBook(bytes32(uint256(2)), orderHash);

        ISwapVM v = desk.asView();
        bytes memory t = _traits(false);
        vm.expectRevert(
            abi.encodeWithSelector(
                PortfolioLedger.TokenNotInRiskGroup.selector, address(tokenB), address(tokenA)
            )
        );
        v.quote(order, 3_000e18, t);
    }

    // ============ the fork surface stays bounded ============

    /// Upstream programs still run on the Bastion router, unchanged. Bastion's opcodes are
    /// tried first and everything else falls through to `super._runOpcode`.
    function test_UpstreamProgramsStillRun() public {
        ISwapVM.Order memory order = createStrategy(bytes.concat(XYCSwap.build(), Salt.build(uint64(42))));
        _ship(order);
        // no admission, no anchor, no risk group: it is not a Bastion book at all, and it
        // still prices on the upstream constant-product curve.
        (, uint256 amountOut,) = desk.asView().quote(order, 1e18, _traits(true));
        assertGt(amountOut, 0, "an upstream XYC book stopped working on the Bastion router");
    }

    /// The opcode slots this milestone claimed, pinned. Upstream's own OpcodeEnumCheck still
    /// passes unchanged; this covers the five previously free slots we named.
    function test_BastionOpcodeSlots() public pure {
        assertEq(uint8(Opcode.MakerPriceAnchor), 0x33);
        assertEq(uint8(Opcode.MakerBudget), 0x34);
        assertEq(uint8(Opcode.BookMandate), 0x35);
        assertEq(uint8(Opcode.PortfolioSwap), 0x52);
        assertEq(uint8(Opcode.PortfolioLedger), 0x92);
        // and the neighbours upstream already owned are untouched
        assertEq(uint8(Opcode.JumpIfTokenOut), 0x32);
        assertEq(uint8(Opcode.LimitSwap), 0x53);
        assertEq(uint8(Opcode.DynamicBalances), 0x91);
    }
}

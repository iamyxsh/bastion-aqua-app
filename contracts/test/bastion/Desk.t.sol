// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// BASTION — milestone 3 increment 1: the maker's administrative surface.
///
/// What this file covers: risk-group initialisation, book admission, and the signed-anchor
/// lifecycle that a live quote depends on. What it does NOT cover, because none of it exists
/// yet: output budgets, mandates, the maker lock, settlement-trait validation, anchor
/// deviation and confidence limits, signer rotation, explicit pause, and scheduled
/// revision or revocation.

import { Test } from "forge-std/Test.sol";

import { BastionTestBase } from "./BastionTestBase.sol";
import { DeskAdmin } from "../../src/bastion/desk/DeskAdmin.sol";
import { PMMState } from "../../src/bastion/pmm/PMMState.sol";
import { PMMMath } from "../../src/bastion/pmm/PMMMath.sol";

contract BastionDeskTest is BastionTestBase {
    // ============ initialisation ============

    function test_InitRiskGroup_OpensAtTarget() public {
        _openGroup();
        (uint256 i, uint256 k, uint256 b, uint256 q, uint256 b0, uint256 q0, uint8 r) =
            desk.riskGroupState(maker, GROUP_ID);

        assertEq(i, ANCHOR, "anchor");
        assertEq(k, K, "curvature");
        assertEq(b, LEDGER_BASE, "base ledger");
        assertEq(q, LEDGER_QUOTE, "quote ledger");
        assertEq(b0, LEDGER_BASE, "a fresh group opens at its base target");
        assertEq(q0, LEDGER_QUOTE, "a fresh group opens at its quote target");
        assertEq(r, 0, "a fresh group is at R = ONE");

        (address groupMaker, address base, address quote, address signer, uint32 policy,,,) =
            desk.riskGroupTerms(maker, GROUP_ID);
        assertEq(groupMaker, maker);
        assertEq(base, address(tokenA));
        assertEq(quote, address(tokenB));
        assertEq(signer, anchorSigner);
        assertEq(policy, 1);
    }

    function test_InitRiskGroup_Rejects() public {
        vm.startPrank(maker);

        vm.expectRevert(abi.encodeWithSelector(DeskAdmin.InvalidPair.selector, address(tokenA), address(tokenA)));
        desk.initRiskGroup(GROUP_ID, address(tokenA), address(tokenA), K, anchorSigner, ANCHOR, 1e18, 1e18);

        vm.expectRevert(DeskAdmin.InvalidAnchorSigner.selector);
        desk.initRiskGroup(GROUP_ID, address(tokenA), address(tokenB), K, address(0), ANCHOR, 1e18, 1e18);

        // the curvature band rejected by milestone 2 increment 2's FINDING 1
        vm.expectRevert(abi.encodeWithSelector(PMMState.InvalidCurvature.selector, uint256(1e18 - 3)));
        desk.initRiskGroup(GROUP_ID, address(tokenA), address(tokenB), 1e18 - 3, anchorSigner, ANCHOR, 1e18, 1e18);

        vm.expectRevert(PMMState.EmptyLedger.selector);
        desk.initRiskGroup(GROUP_ID, address(tokenA), address(tokenB), K, anchorSigner, ANCHOR, 0, 1e18);

        vm.stopPrank();
    }

    function test_InitRiskGroup_CannotBeReopened() public {
        _openGroup();
        bytes32 groupKey = desk.riskGroupKey(maker, GROUP_ID);
        vm.prank(maker);
        vm.expectRevert(abi.encodeWithSelector(DeskAdmin.RiskGroupExists.selector, groupKey));
        desk.initRiskGroup(GROUP_ID, address(tokenA), address(tokenB), K, anchorSigner, ANCHOR, 1e18, 1e18);
    }

    /// A group id is scoped to its maker, so two makers may use the same local id without
    /// colliding — and neither can touch the other's state.
    function test_RiskGroupsAreScopedToTheirMaker() public {
        _openGroup();
        address other = vm.addr(0xB0B);
        vm.prank(other);
        desk.initRiskGroup(GROUP_ID, address(tokenA), address(tokenB), K, anchorSigner, 1e18, 5e18, 5e18);

        (,,, uint256 q,,,) = desk.riskGroupState(maker, GROUP_ID);
        (,,, uint256 qOther,,,) = desk.riskGroupState(other, GROUP_ID);
        assertEq(q, LEDGER_QUOTE, "maker's group changed");
        assertEq(qOther, 5e18, "other maker's group is separate");
        assertTrue(desk.riskGroupKey(maker, GROUP_ID) != desk.riskGroupKey(other, GROUP_ID));
    }

    // ============ admission ============

    /// Authorisation here is structural, not a check: `groupKey` is derived from the
    /// caller, so a stranger calling admitBook addresses a group of THEIR own that was never
    /// opened, and is refused as unknown. They can never reach the maker's group at all.
    function test_AdmitBook_IsScopedToTheCaller() public {
        _openGroup();
        bytes32 orderHash = keccak256("book");
        bytes32 strangerKey = desk.riskGroupKey(address(taker), GROUP_ID);

        vm.prank(address(taker));
        vm.expectRevert(abi.encodeWithSelector(DeskAdmin.RiskGroupUnknown.selector, strangerKey));
        desk.admitBook(GROUP_ID, orderHash);

        _admit(orderHash);
        assertEq(desk.bookGroup(orderHash), desk.riskGroupKey(maker, GROUP_ID), "book not mapped to the group");
    }

    function test_AdmitBook_RejectsUnknownGroupAndDoubleAdmission() public {
        bytes32 orderHash = keccak256("book");
        bytes32 missing = desk.riskGroupKey(maker, bytes32(uint256(99)));

        vm.prank(maker);
        vm.expectRevert(abi.encodeWithSelector(DeskAdmin.RiskGroupUnknown.selector, missing));
        desk.admitBook(bytes32(uint256(99)), orderHash);

        _openGroup();
        _admit(orderHash);
        vm.prank(maker);
        vm.expectRevert(abi.encodeWithSelector(DeskAdmin.BookAlreadyAdmitted.selector, orderHash));
        desk.admitBook(GROUP_ID, orderHash);
    }

    function test_UnadmittedBookMapsToNothing() public view {
        assertEq(desk.bookGroup(keccak256("never admitted")), bytes32(0));
    }

    // ============ anchors ============

    function test_PostAnchor_IsPermissionlessButSignatureBound() public {
        _openGroup();
        DeskAdmin.Anchor memory a = _anchor(3_100e18, 1, uint64(block.timestamp + 1 hours));
        bytes memory sig = _sign(a, signerPk);

        // anyone may publish; the signature carries the authorisation (spec 5.2)
        vm.prank(address(taker));
        desk.postAnchor(a, sig);

        (,,,,, uint256 nonce, uint64 issuedAt, uint64 expiry) = desk.riskGroupTerms(maker, GROUP_ID);
        assertEq(nonce, 1);
        assertEq(issuedAt, uint64(block.timestamp));
        assertEq(expiry, uint64(block.timestamp + 1 hours));
    }

    function test_PostAnchor_RejectsWrongSigner() public {
        _openGroup();
        DeskAdmin.Anchor memory a = _anchor(3_100e18, 1, uint64(block.timestamp + 1 hours));
        // sign BEFORE arming the expectation: _sign calls the router for the digest, and
        // vm.expectRevert applies to the very next call.
        bytes memory wrong = _sign(a, 0xDEADBEEF);
        vm.expectRevert(abi.encodeWithSelector(DeskAdmin.AnchorBadSigner.selector, anchorSigner));
        desk.postAnchor(a, wrong);
    }

    function test_PostAnchor_RejectsReplayAndRegressingNonce() public {
        _openGroup();
        _post(3_100e18, 5, uint64(block.timestamp + 1 hours));

        DeskAdmin.Anchor memory replay = _anchor(3_100e18, 5, uint64(block.timestamp + 1 hours));
        bytes memory replaySig = _sign(replay, signerPk);
        vm.expectRevert(abi.encodeWithSelector(DeskAdmin.AnchorNonceNotMonotone.selector, uint256(5), uint256(5)));
        desk.postAnchor(replay, replaySig);

        DeskAdmin.Anchor memory older = _anchor(3_100e18, 4, uint64(block.timestamp + 1 hours));
        bytes memory olderSig = _sign(older, signerPk);
        vm.expectRevert(abi.encodeWithSelector(DeskAdmin.AnchorNonceNotMonotone.selector, uint256(4), uint256(5)));
        desk.postAnchor(older, olderSig);
    }

    function test_PostAnchor_RejectsFutureAndExpired() public {
        _openGroup();

        DeskAdmin.Anchor memory future = _anchor(3_100e18, 1, uint64(block.timestamp + 1 hours));
        future.issuedAt = uint64(block.timestamp + 60);
        bytes memory futureSig = _sign(future, signerPk);
        vm.expectRevert(
            abi.encodeWithSelector(DeskAdmin.AnchorIssuedInFuture.selector, future.issuedAt, block.timestamp)
        );
        desk.postAnchor(future, futureSig);

        DeskAdmin.Anchor memory expired = _anchor(3_100e18, 1, uint64(block.timestamp));
        bytes memory expiredSig = _sign(expired, signerPk);
        vm.expectRevert(
            abi.encodeWithSelector(DeskAdmin.AnchorAlreadyExpired.selector, expired.expiry, block.timestamp)
        );
        desk.postAnchor(expired, expiredSig);
    }

    function test_PostAnchor_RejectsWrongPolicyVersion() public {
        _openGroup();
        DeskAdmin.Anchor memory a = _anchor(3_100e18, 1, uint64(block.timestamp + 1 hours));
        a.policyVersion = 2;
        bytes memory sig = _sign(a, signerPk);
        vm.expectRevert(abi.encodeWithSelector(DeskAdmin.AnchorWrongPolicyVersion.selector, uint32(2), uint32(1)));
        desk.postAnchor(a, sig);
    }

    /// An anchor signed for one router must not be replayable on another. The domain binds
    /// chainid and `address(this)`, so the digest differs even for identical fields.
    function test_AnchorDigestIsBoundToThisRouter() public {
        _openGroup();
        DeskAdmin.Anchor memory a = _anchor(3_100e18, 1, uint64(block.timestamp + 1 hours));
        bytes32 here = desk.hashAnchorView(a);

        BastionTestBaseOtherRouter other = new BastionTestBaseOtherRouter(address(aqua));
        assertTrue(here != other.digest(a), "the same anchor hashed identically on two routers");
    }

    /// Accepting an anchor IS the explicit recentring transition of spec 5.1, and it applies
    /// once. Posting the same price again is a no-op on the curve.
    function test_PostAnchor_RecentresOnceAndLeavesACanonicalState() public {
        _openGroup();
        // move off target first, so there is a target to re-solve
        _post(ANCHOR, 1, uint64(block.timestamp + 1 hours));

        (uint256 i0,,,, uint256 b0Before,,) = desk.riskGroupState(maker, GROUP_ID);
        assertEq(i0, ANCHOR, "posting the same price should not move the anchor value");

        _post(3_300e18, 2, uint64(block.timestamp + 1 hours));
        (uint256 i1, uint256 k1, uint256 b1, uint256 q1, uint256 b01, uint256 q01, uint8 r1) =
            desk.riskGroupState(maker, GROUP_ID);
        assertEq(i1, 3_300e18, "the new anchor was not applied");
        assertEq(b1, LEDGER_BASE, "recentring must not move inventory");
        assertEq(q1, LEDGER_QUOTE, "recentring must not move inventory");
        // at R = ONE there is no target to re-solve, so the targets are unchanged
        assertEq(b01, b0Before, "targets moved at R = ONE");
        assertEq(r1, 0);

        // and the resulting state is a fixed point of the reference's own target rule
        PMMMath.PMMState memory s =
            PMMMath.PMMState({ i: i1, K: k1, B: b1, Q: q1, B0: b01, Q0: q01, R: PMMMath.RState(r1) });
        (uint256 rb0, uint256 rq0) = PMMMath.adjustedTarget(s);
        assertEq(rb0, b01, "B0 is not canonical after recentring");
        assertEq(rq0, q01, "Q0 is not canonical after recentring");
    }
}

/// @dev A second router, only to prove anchor digests are router-bound.
contract BastionTestBaseOtherRouter {
    address private immutable _router;

    constructor(address aqua) {
        _router = address(new BastionRouterShim(aqua));
    }

    function digest(DeskAdmin.Anchor calldata a) external view returns (bytes32) {
        return BastionRouterShim(payable(_router)).hashAnchorView(a);
    }
}

import { BastionAquaSwapVMRouter } from "../../src/bastion/routers/BastionAquaSwapVMRouter.sol";

contract BastionRouterShim is BastionAquaSwapVMRouter {
    constructor(address aqua) BastionAquaSwapVMRouter(aqua, address(0), msg.sender, "Bastion", "1") { }
}

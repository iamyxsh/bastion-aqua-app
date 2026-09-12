// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { DeskStorage } from "./DeskStorage.sol";
import { DeskAdmin } from "./DeskAdmin.sol";

/// @title BastionDesk
/// @notice The maker's administrative entrypoints on the router.
/// @dev Thin on purpose. Every body lives in the deployed `DeskAdmin` library and is reached
///      by delegatecall, so the code sits outside the router's 24,576-byte budget while the
///      storage stays in the router (ladder decision D2 and its size fallback; the
///      measurement is in DeskAdmin's header). `msg.sender` is forwarded explicitly because
///      a library call does not change it but a reader should not have to know that.
abstract contract BastionDesk {
    /// @notice Open a risk group. One group's PMM state is shared by every sibling book.
    function initRiskGroup(
        bytes32 riskGroupId,
        address baseToken,
        address quoteToken,
        uint256 k,
        address anchorSigner,
        uint256 initialPriceWad,
        uint256 baseLedger,
        uint256 quoteLedger
    ) external returns (bytes32) {
        return DeskAdmin.initRiskGroup(
            msg.sender, riskGroupId, baseToken, quoteToken, k, anchorSigner, initialPriceWad, baseLedger, quoteLedger
        );
    }

    /// @notice Admit one book, by its SwapVM order hash, onto a risk group.
    function admitBook(bytes32 riskGroupId, bytes32 orderHash) external {
        DeskAdmin.admitBook(msg.sender, riskGroupId, orderHash);
    }

    /// @notice Publish a signed price update. Permissionless by design (spec 5.2).
    function postAnchor(DeskAdmin.Anchor calldata a, bytes calldata signature) external {
        DeskAdmin.postAnchor(a, signature, msg.sender);
    }

    // ============ views ============

    /// @notice The EIP-712 digest a keeper must sign for this router.
    /// @dev Must be read from the ROUTER, not from the library: the domain binds
    ///      `address(this)`, and under delegatecall that is this router. Calling the
    ///      library directly would produce a digest for the library's own address.
    function hashAnchorView(DeskAdmin.Anchor calldata a) external view returns (bytes32) {
        return DeskAdmin.hashAnchor(a);
    }

    function riskGroupKey(address maker, bytes32 riskGroupId) external pure returns (bytes32) {
        return DeskStorage.key(maker, riskGroupId);
    }

    /// @notice The risk group a book is admitted to, or zero if it is not admitted.
    function bookGroup(bytes32 orderHash) external view returns (bytes32) {
        return DeskStorage.layout().bookOf[orderHash];
    }

    /// @notice The shared PMM state and terms of one risk group.
    function riskGroupState(address maker, bytes32 riskGroupId)
        external
        view
        returns (uint256 i, uint256 k, uint256 b, uint256 q, uint256 b0, uint256 q0, uint8 r)
    {
        DeskStorage.RiskGroup storage g = DeskStorage.layout().groups[DeskStorage.key(maker, riskGroupId)];
        return (g.i, g.K, g.B, g.Q, g.B0, g.Q0, g.R);
    }

    /// @notice Registered terms and anchor health of one risk group.
    function riskGroupTerms(address maker, bytes32 riskGroupId)
        external
        view
        returns (
            address groupMaker,
            address baseToken,
            address quoteToken,
            address anchorSigner,
            uint32 policyVersion,
            uint256 anchorNonce,
            uint64 anchorIssuedAt,
            uint64 anchorExpiry
        )
    {
        DeskStorage.RiskGroup storage g = DeskStorage.layout().groups[DeskStorage.key(maker, riskGroupId)];
        return (
            g.maker, g.baseToken, g.quoteToken, g.anchorSigner,
            g.policyVersion, g.anchorNonce, g.anchorIssuedAt, g.anchorExpiry
        );
    }
}

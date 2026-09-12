// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { PMMMath } from "../pmm/PMMMath.sol";

/// @title DeskStorage
/// @notice The one place Bastion's shared maker state lives (ladder decision D2).
///
/// @dev WHY A NAMESPACED SLOT, and not ordinary contract storage. Instructions are
///      `internal` libraries that execute inside the router's own context, exactly like
///      upstream's `DynamicBalances` (src/instructions/Balances.sol). They therefore reach
///      state through a fixed ERC-7201 slot rather than through a contract reference: a
///      separate registry would need an external call from inside the VM loop.
///
///      THE POINT OF THE WHOLE DESIGN is the second mapping. Books are keyed by their own
///      `orderHash`, but they map onto ONE `RiskGroup`. Two admitted books over the same
///      group read and write the same `i, K, B, Q, B0, Q0, R`, so a fill through one book
///      moves the price the other one quotes — through contract state, not through anything
///      a UI coordinates. Aqua's per-book virtual balances stay independent of this and are
///      untouched here.
library DeskStorage {
    /// @dev keccak256(abi.encode(uint256(keccak256("bastion.storage.Desk")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 internal constant SLOT = 0xa0079670cb25a9edae57946c51610206acde03c039f2693b3dcf17b0ea697b00;

    /// @param maker the only address that may administer this group
    /// @param baseToken / quoteToken the pair; direction is derived from these, never guessed
    /// @param anchorSigner the scoped key allowed to sign price anchors, and nothing else
    /// @param policyVersion bumped by the maker; an anchor signed for another version is rejected
    /// @param i,K,B,Q,B0,Q0,R the canonical PMM state of spec 5.1, shared by every sibling book
    /// @param anchorNonce monotone; an older update can never be selected once a newer one lands
    /// @param anchorIssuedAt signed issue time — freshness derives from this, never from publication
    /// @param anchorExpiry after this the desk is stale and quotes must stop
    /// @param anchorConfidenceBps carried and stored but NOT enforced until milestone 5
    struct RiskGroup {
        address maker;
        address baseToken;
        address quoteToken;
        address anchorSigner;
        uint32 policyVersion;
        uint256 i;
        uint256 K;
        uint256 B;
        uint256 Q;
        uint256 B0;
        uint256 Q0;
        uint8 R;
        uint256 anchorNonce;
        uint64 anchorIssuedAt;
        uint64 anchorExpiry;
        uint64 anchorConfidenceBps;
    }

    struct Layout {
        mapping(bytes32 groupKey => RiskGroup) groups;
        mapping(bytes32 orderHash => bytes32 groupKey) bookOf;
    }

    function layout() internal pure returns (Layout storage $) {
        bytes32 slot = SLOT;
        assembly ("memory-safe") {
            $.slot := slot
        }
    }

    /// @dev A group id is scoped to its maker, so two makers may use the same local id.
    function key(address maker, bytes32 riskGroupId) internal pure returns (bytes32) {
        return keccak256(abi.encode(maker, riskGroupId));
    }

    // ---- moving the PMM state between storage and the solver -------------------

    function loadPmm(RiskGroup storage g) internal view returns (PMMMath.PMMState memory) {
        return PMMMath.PMMState({
            i: g.i,
            K: g.K,
            B: g.B,
            Q: g.Q,
            B0: g.B0,
            Q0: g.Q0,
            R: PMMMath.RState(g.R)
        });
    }

    function storePmm(RiskGroup storage g, PMMMath.PMMState memory s) internal {
        g.i = s.i;
        g.B = s.B;
        g.Q = s.Q;
        g.B0 = s.B0;
        g.Q0 = s.Q0;
        g.R = uint8(s.R);
        // K is deliberately not written back: curvature is a registered term, not trade state.
    }
}

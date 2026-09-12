// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Context } from "../../libs/VM.sol";
import { Opcode } from "../../libs/OpcodeList.sol";
import { MemoryPtr, MemoryPtrLib } from "../../libs/MemoryPtr.sol";
import { InstructionBuilder } from "../../libs/InstructionBuilder.sol";

import { DeskStorage } from "../desk/DeskStorage.sol";
import { PortfolioLedger } from "./PortfolioLedger.sol";

/// @notice MakerPriceAnchor opcode: refuses to trade without a live signed anchor.
/// @dev Encoding: []
///
/// @dev A leaf, and a gate rather than a source of price. The anchor itself is published by
///      a separate permissionless `postAnchor` transaction carrying the maker's signature
///      (spec 5.2, ladder decision D4); this instruction only asserts that what was
///      published is still live at fill time.
///
/// @dev SCOPE at milestone 3 increment 1: presence and expiry. Maximum age at fill, maximum
///      deviation from the previously accepted anchor, maximum signed confidence, signer
///      rotation and explicit pause are milestone 5 and are NOT enforced here. The
///      confidence bound is already carried and stored by `postAnchor` so signatures do not
///      have to change shape later.
library MakerPriceAnchor {
    using MemoryPtrLib for MemoryPtr;
    using InstructionBuilder for MemoryPtr;

    /// @dev No anchor has ever been accepted for this risk group.
    error AnchorMissing(bytes32 orderHash);
    /// @dev The accepted anchor's signed expiry has passed. Spec 5.3: quotes and fills pause.
    error AnchorStale(uint256 expiry, uint256 nowTs);

    Opcode constant opcode = Opcode.MakerPriceAnchor;

    function sizeOf() internal pure returns (uint256) {
        return InstructionBuilder.sizeOf();
    }

    function build() internal pure returns (bytes memory) {
        return build(MemoryPtrLib.alloc(sizeOf())).resolve();
    }

    function build(MemoryPtr ptrStart) internal pure returns (MemoryPtr ptr) {
        ptr = ptrStart.pushHeader(opcode);
        ptrStart.patchLength(ptr);
    }

    function exec(Context memory ctx, bytes calldata) internal view {
        (DeskStorage.RiskGroup storage g, ) = PortfolioLedger.resolve(ctx);
        require(g.anchorExpiry != 0, AnchorMissing(ctx.query.orderHash));
        require(block.timestamp <= g.anchorExpiry, AnchorStale(g.anchorExpiry, block.timestamp));
    }
}

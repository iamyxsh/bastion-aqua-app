// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Context } from "../../libs/VM.sol";
import { Opcode, OpcodeOps } from "../../libs/OpcodeList.sol";
import { AquaOpcodes } from "../../opcodes/AquaOpcodes.sol";

import { MakerPriceAnchor } from "../instructions/MakerPriceAnchor.sol";
import { PortfolioLedger } from "../instructions/PortfolioLedger.sol";
import { PortfolioSwap } from "../instructions/PortfolioSwap.sol";

/// @title BastionOpcodes
/// @notice Bastion's instruction set: the upstream Aqua set plus three new opcodes.
/// @dev `AquaOpcodes._runOpcode` is `internal virtual`
///      (src/opcodes/AquaOpcodes.sol:27), so extending the instruction set needs NO edit to
///      it. Bastion's opcodes are tried first and everything else falls through to `super`,
///      which keeps upstream dispatch byte-identical for every upstream program.
contract BastionOpcodes is AquaOpcodes {
    using OpcodeOps for Opcode;

    function _runOpcode(Context memory ctx, uint256 opcode, bytes calldata args) internal virtual override {
             if (opcode == PortfolioSwap.opcode.asU8()) PortfolioSwap.exec(ctx, args);
        else if (opcode == PortfolioLedger.opcode.asU8()) PortfolioLedger.exec(ctx, args);
        else if (opcode == MakerPriceAnchor.opcode.asU8()) MakerPriceAnchor.exec(ctx, args);
        else super._runOpcode(ctx, opcode, args);
    }
}

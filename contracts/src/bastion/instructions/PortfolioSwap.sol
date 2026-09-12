// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Context } from "../../libs/VM.sol";
import { Opcode } from "../../libs/OpcodeList.sol";
import { MemoryPtr, MemoryPtrLib } from "../../libs/MemoryPtr.sol";
import { InstructionBuilder } from "../../libs/InstructionBuilder.sol";

import { PMMMath } from "../pmm/PMMMath.sol";
import { PMMState } from "../pmm/PMMState.sol";
import { DeskStorage } from "../desk/DeskStorage.sol";
import { PortfolioLedger } from "./PortfolioLedger.sol";

/// @notice PortfolioSwap opcode: prices one exact-in fill off the SHARED PMM state.
/// @dev Encoding: []
///
/// @dev A leaf. It reads the risk group's state and sets `ctx.swap.amountOut`; it writes
///      nothing. The state transition belongs to the enclosing `PortfolioLedger`, which is
///      the only instruction positioned to see the gross input.
///
/// @dev It prices from the shared PMM ledger, NOT from `ctx.swap.balanceIn/balanceOut`.
///      Those are Aqua's per-book virtual balances, which stay independent (spec 8) and
///      still bound settlement. Advertised virtual amounts, shared pricing inventory and
///      live backing are three different things and this instruction only touches the second.
library PortfolioSwap {
    using MemoryPtrLib for MemoryPtr;
    using InstructionBuilder for MemoryPtr;

    /// @dev Exact-out is not supported and is refused here, not hidden in a frontend.
    ///      The DODO reference provides exact-in pricing only; deriving an inverse is a
    ///      separate gate (spec 5.1, 17).
    error ExactOutNotSupported();

    Opcode constant opcode = Opcode.PortfolioSwap;

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
        require(ctx.query.isExactIn, ExactOutNotSupported());

        (DeskStorage.RiskGroup storage g, bool baseIn) = PortfolioLedger.resolve(ctx);

        PMMMath.PMMState memory s = DeskStorage.loadPmm(g);
        // `ctx.swap.amountIn` is already NET of the enclosing FeeFlatIn, so the fee argument
        // here is zero: the fee has been taken, and it is credited by PortfolioLedger.
        ctx.swap.amountOut = PMMState.quoteExactIn(s, baseIn, ctx.swap.amountIn, 0);
    }
}

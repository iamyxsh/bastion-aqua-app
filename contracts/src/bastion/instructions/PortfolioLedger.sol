// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Context, ContextLib } from "../../libs/VM.sol";
import { Opcode } from "../../libs/OpcodeList.sol";
import { MemoryPtr, MemoryPtrLib } from "../../libs/MemoryPtr.sol";
import { InstructionBuilder } from "../../libs/InstructionBuilder.sol";

import { PMMMath } from "../pmm/PMMMath.sol";
import { PMMState } from "../pmm/PMMState.sol";
import { DeskStorage } from "../desk/DeskStorage.sol";

/// @notice PortfolioLedger opcode: admits the book, then commits the shared PMM state.
/// @dev Encoding: []
///
/// @dev A WRAPPER, and it has to be. Upstream `FeeFlatIn` subtracts the fee from
///      `ctx.swap.amountIn` BEFORE its inner loop and adds it back after
///      (src/instructions/FeeFlat.sol), so whatever prices inside it sees the NET input,
///      while spec 5.1 requires the ledger to be credited the GROSS. Those are two
///      different points in one program, which is why upstream nests the same way:
///      `DynamicBalances{FeeFlatIn{XYCSwap}}`. Bastion mirrors it exactly:
///
///          [ MakerPriceAnchor ; PortfolioLedger ; FeeFlatIn ; PortfolioSwap ; Salt ]
///            \_ anchor valid?   \_ admit + commit  \_ fee     \_ price on net
///
///      Nesting is implicit in program order: a wrapper's `ctx.runLoop()` executes the
///      remainder of the program and returns with the registers it produced.
///
/// @dev Admission is checked HERE, before `runLoop`, so a program whose `orderHash` was
///      never admitted reverts before any pricing happens.
///
/// @dev Writes are guarded by `!ctx.vm.isStaticContext`, the upstream pattern at
///      Balances.sol:121. A quote therefore leaves storage byte-identical.
library PortfolioLedger {
    using MemoryPtrLib for MemoryPtr;
    using InstructionBuilder for MemoryPtr;
    using ContextLib for Context;

    /// @dev This program's orderHash is not an admitted book on any risk group.
    error BookNotAdmitted(bytes32 orderHash);
    /// @dev The book's tokens are not the risk group's pair.
    error TokenNotInRiskGroup(address tokenIn, address tokenOut);

    Opcode constant opcode = Opcode.PortfolioLedger;

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

    /// @dev Resolve the risk group a book belongs to, reverting if it was never admitted.
    ///      Shared with PortfolioSwap so both agree on the group and the direction.
    function resolve(Context memory ctx)
        internal
        view
        returns (DeskStorage.RiskGroup storage g, bool baseIn)
    {
        DeskStorage.Layout storage $ = DeskStorage.layout();
        bytes32 groupKey = $.bookOf[ctx.query.orderHash];
        require(groupKey != bytes32(0), BookNotAdmitted(ctx.query.orderHash));
        g = $.groups[groupKey];

        if (ctx.query.tokenIn == g.baseToken && ctx.query.tokenOut == g.quoteToken) {
            baseIn = true;
        } else if (ctx.query.tokenIn == g.quoteToken && ctx.query.tokenOut == g.baseToken) {
            baseIn = false;
        } else {
            revert TokenNotInRiskGroup(ctx.query.tokenIn, ctx.query.tokenOut);
        }
    }

    function exec(Context memory ctx, bytes calldata) internal {
        (DeskStorage.RiskGroup storage g, bool baseIn) = resolve(ctx);

        (uint256 amountIn, uint256 amountOut) = ctx.runLoop();

        if (!ctx.vm.isStaticContext) {
            // `amountIn` is GROSS here: FeeFlatIn restored the fee on the way out, so the
            // fee lands in the maker's inventory and is reinvested by the transition.
            PMMMath.PMMState memory s = DeskStorage.loadPmm(g);
            PMMState.commitExactIn(s, baseIn, amountIn, amountOut);
            DeskStorage.storePmm(g, s);
        }
    }
}

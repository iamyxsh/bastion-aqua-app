// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Simulator } from "@1inch/solidity-utils/contracts/mixins/Simulator.sol";

import { Context } from "../../libs/VM.sol";
import { SwapVM } from "../../SwapVM.sol";

import { BastionOpcodes } from "../opcodes/BastionOpcodes.sol";
import { BastionDesk } from "../desk/BastionDesk.sol";

/// @title BastionAquaSwapVMRouter
/// @notice The only router Bastion books ship to.
/// @dev Aqua keys balances by (maker, app, orderHash, token), where the app is the router.
///      A book shipped to the upstream `AquaSwapVMRouter` is therefore a different position
///      entirely and cannot reach this desk's state.
///
/// @dev Upstream `SwapVM.sol`, `AquaOpcodes.sol` and `AquaSwapVMRouter.sol` are all
///      UNMODIFIED. The only upstream file this milestone touches is `libs/OpcodeList.sol`,
///      to give names to five previously free enum slots.
///
/// @dev NOT PRESENT YET, and load-bearing for anyone reading this as finished: there is no
///      maker execution lock, no settlement-trait validation and no output budget. Those
///      need preflight and post-settlement hooks inside `SwapVM.quote`/`swap`, which are
///      not virtual (milestone 3 increment 3, ladder decision D3b).
contract BastionAquaSwapVMRouter is Simulator, SwapVM, BastionOpcodes, BastionDesk {
    constructor(
        address aqua,
        address weth,
        address owner,
        string memory name,
        string memory version
    ) SwapVM(aqua, weth, owner, name, version) { }

    /// @dev Dispatches an opcode to its handler for VM execution.
    function _dispatch(Context memory ctx, uint256 opcode, bytes calldata args) internal override {
        _runOpcode(ctx, opcode, args);
    }
}

// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// BASTION — milestone 1, increment 3.
///
/// Smoke test on a LOCAL ANVIL chain proving that tokens really move through
/// unmodified Aqua settlement driven by unmodified SwapVM. No Bastion instruction is
/// involved: the program is upstream `XYCSwap` + `Salt`. This proves the plumbing,
/// not our pricing.
///
/// Everything here is a LOCAL FIXTURE. `fWETH` and `fUSDC` are mintable mocks, not
/// real WETH or USDC. The keys come from anvil's published test mnemonic — public by
/// design, worthless off a local chain, and never to be reused anywhere else.
///
/// Contracts are deployed by `scripts/anvil-smoke.sh` with `forge create`, not here:
/// `forge script` 1.0.0-stable aborts while decoding `AquaSwapVMRouter`'s constructor
/// arguments. This script therefore performs calls only and reads the addresses from
/// the environment.
///
/// Run:  make smoke

import { Script } from "forge-std/Script.sol";
import { console2 } from "forge-std/console2.sol";

import { Aqua } from "@1inch/aqua/src/Aqua.sol";

import { ISwapVM } from "../../src/interfaces/ISwapVM.sol";
import { AquaSwapVMRouter } from "../../src/routers/AquaSwapVMRouter.sol";
import { MakerTraitsLib } from "../../src/libs/MakerTraits.sol";
import { TakerTraitsLib } from "../../src/libs/TakerTraits.sol";
import { XYCSwap } from "../../src/instructions/XYCSwap.sol";
import { Salt } from "../../src/instructions/Controls.sol";

import { TokenMockDecimals } from "../../test/mocks/TokenMockDecimals.sol";
import { MockTaker } from "../../test/mocks/MockTaker.sol";

// solhint-disable no-console
contract SmokeSwapLocal is Script {
    string internal constant ANVIL_MNEMONIC =
        "test test test test test test test test test test test junk";

    // Alice advertises 10 fWETH and 40,000 fUSDC. An Aqua balance is an allowance over
    // tokens that never leave her wallet, so she must actually hold them.
    uint256 internal constant MAKER_WETH = 10e18;
    uint256 internal constant MAKER_USDC = 40_000e6;

    // Bob sells 1,000 fUSDC, exact-in.
    uint256 internal constant TAKER_SELLS_USDC = 1_000e6;

    struct Env {
        Aqua aqua;
        AquaSwapVMRouter swapVM;
        TokenMockDecimals weth;
        TokenMockDecimals usdc;
        MockTaker takerApp;
        uint256 deployerPk;
        uint256 makerPk;
        uint256 takerPk;
        address deployer;
        address maker;
        address taker;
    }

    function run() external {
        Env memory e = _env();

        // ---- 1. fund the fixtures (deployer owns the mocks) --------------------
        vm.startBroadcast(e.deployerPk);
        e.weth.mint(e.maker, MAKER_WETH);
        e.usdc.mint(e.maker, MAKER_USDC);
        e.usdc.mint(address(e.takerApp), TAKER_SELLS_USDC);
        vm.stopBroadcast();

        // SwapVM orders require tokenA < tokenB by address.
        (address tokenA, address tokenB) = address(e.weth) < address(e.usdc)
            ? (address(e.weth), address(e.usdc))
            : (address(e.usdc), address(e.weth));
        bool usdcIsA = tokenA == address(e.usdc);

        // ---- 2. Alice ships one strategy --------------------------------------
        ISwapVM.Order memory order = _order(e.maker, tokenA, tokenB);
        bytes32 orderHash = e.swapVM.hash(order);

        address[] memory tokens = new address[](2);
        uint256[] memory amounts = new uint256[](2);
        tokens[0] = tokenA;
        tokens[1] = tokenB;
        amounts[0] = usdcIsA ? MAKER_USDC : MAKER_WETH;
        amounts[1] = usdcIsA ? MAKER_WETH : MAKER_USDC;

        vm.startBroadcast(e.makerPk);
        e.weth.approve(address(e.aqua), type(uint256).max);
        e.usdc.approve(address(e.aqua), type(uint256).max);
        bytes32 strategyHash = e.aqua.ship(address(e.swapVM), abi.encode(order), tokens, amounts);
        vm.stopBroadcast();

        require(strategyHash == orderHash, "strategyHash != swapVM.hash(order)");

        _report("BEFORE", e, orderHash);

        // ---- 3. Bob swaps ------------------------------------------------------
        // isAToB == true means tokenIn is tokenA. Bob's input is fUSDC.
        bytes memory takerTraits = TakerTraitsLib.build(TakerTraitsLib.Args({
            taker: address(e.takerApp),
            isExactIn: true,
            shouldUnwrapWeth: false,
            hasPreTransferInCallback: true,   // MockTaker pushes tokenIn into Aqua
            hasPreTransferOutCallback: false,
            isStrictThresholdAmount: false,
            isFirstTransferFromTaker: false,
            useTransferFromAndAquaPush: false,
            isAToB: usdcIsA,
            allowPartialFill: false,
            threshold: "",
            to: address(0),
            deadline: 0,
            preTransferInHookData: "",
            postTransferInHookData: "",
            preTransferOutHookData: "",
            postTransferOutHookData: "",
            preTransferInCallbackData: "",
            preTransferOutCallbackData: "",
            instructionsArgs: "",
            signature: ""
        }));

        vm.startBroadcast(e.takerPk);
        (uint256 amountIn, uint256 amountOut) =
            e.takerApp.swap(order, TAKER_SELLS_USDC, takerTraits);
        vm.stopBroadcast();

        console2.log("");
        console2.log("SWAP  amountIn  (fUSDC raw, 6dp) =", amountIn);
        console2.log("SWAP  amountOut (fWETH raw, 18dp) =", amountOut);

        _report("AFTER ", e, orderHash);

        console2.log("");
        console2.log("orderHash / strategyHash:");
        console2.logBytes32(orderHash);
    }

    function _env() internal view returns (Env memory e) {
        e.aqua = Aqua(vm.envAddress("AQUA"));
        e.swapVM = AquaSwapVMRouter(payable(vm.envAddress("SWAPVM")));
        e.weth = TokenMockDecimals(vm.envAddress("FWETH"));
        e.usdc = TokenMockDecimals(vm.envAddress("FUSDC"));
        e.takerApp = MockTaker(vm.envAddress("TAKER_APP"));

        e.deployerPk = vm.deriveKey(ANVIL_MNEMONIC, 0);
        e.makerPk = vm.deriveKey(ANVIL_MNEMONIC, 1);
        e.takerPk = vm.deriveKey(ANVIL_MNEMONIC, 2);
        e.deployer = vm.addr(e.deployerPk);
        e.maker = vm.addr(e.makerPk);
        e.taker = vm.addr(e.takerPk);
    }

    /// @dev Upstream program only: constant-product swap plus a salt for order identity.
    function _order(address maker, address tokenA, address tokenB)
        internal
        pure
        returns (ISwapVM.Order memory)
    {
        bytes memory program = bytes.concat(XYCSwap.build(), Salt.build(uint64(1)));

        return MakerTraitsLib.build(MakerTraitsLib.Args({
            maker: maker,
            receiver: address(0),
            tokenA: tokenA,
            tokenB: tokenB,
            shouldUnwrapWeth: false,
            useAquaInsteadOfSignature: true,
            allowZeroAmountIn: false,
            hasPreTransferInHook: false,
            hasPostTransferInHook: false,
            hasPreTransferOutHook: false,
            hasPostTransferOutHook: false,
            preTransferInTarget: address(0),
            preTransferInData: "",
            postTransferInTarget: address(0),
            postTransferInData: "",
            preTransferOutTarget: address(0),
            preTransferOutData: "",
            postTransferOutTarget: address(0),
            postTransferOutData: "",
            program: program
        }));
    }

    function _report(string memory label, Env memory e, bytes32 orderHash) internal view {
        (uint248 vWeth,) =
            e.aqua.rawBalances(e.maker, address(e.swapVM), orderHash, address(e.weth));
        (uint248 vUsdc,) =
            e.aqua.rawBalances(e.maker, address(e.swapVM), orderHash, address(e.usdc));
        console2.log("");
        console2.log(string.concat("== ", label, " =============================="));
        console2.log("  Alice wallet  fWETH =", e.weth.balanceOf(e.maker));
        console2.log("  Alice wallet  fUSDC =", e.usdc.balanceOf(e.maker));
        console2.log("  Bob   wallet  fWETH =", e.weth.balanceOf(address(e.takerApp)));
        console2.log("  Bob   wallet  fUSDC =", e.usdc.balanceOf(address(e.takerApp)));
        console2.log("  Aqua  virtual fWETH =", uint256(vWeth));
        console2.log("  Aqua  virtual fUSDC =", uint256(vUsdc));
    }
}

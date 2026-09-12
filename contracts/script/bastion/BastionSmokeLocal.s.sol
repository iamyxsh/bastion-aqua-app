// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// BASTION — milestone 3, increment 2. The product claim, on a LOCAL ANVIL chain.
///
/// One fill on book A, settled through unmodified Aqua, changes what book B quotes — with no
/// transaction on B and no change to B's own Aqua balances. Every number below comes from a
/// real transaction on chain 31337.
///
/// Everything here is a LOCAL FIXTURE. `fWETH` and `fUSDC` are mintable mocks, not real WETH
/// or USDC, and the keys are anvil's published test-mnemonic keys: public by design,
/// worthless off a local chain, never reused. Nothing here exists on any public network.
///
/// Contracts are deployed by `scripts/anvil-bastion.sh` with `forge create`, not here: forge
/// 1.0.0-stable aborts decoding this router family's constructor arguments and silently drops
/// the whole broadcast (UPSTREAM.md). This script performs CALLS ONLY.
///
/// Run:  make anvil   (one terminal)
///       make bastion (another)

import { Script } from "forge-std/Script.sol";
import { console2 } from "forge-std/console2.sol";

import { Aqua } from "@1inch/aqua/src/Aqua.sol";

import { ISwapVM } from "../../src/interfaces/ISwapVM.sol";
import { MakerTraitsLib } from "../../src/libs/MakerTraits.sol";
import { TakerTraitsLib } from "../../src/libs/TakerTraits.sol";
import { Salt } from "../../src/instructions/Controls.sol";
import { FeeFlatIn } from "../../src/instructions/FeeFlat.sol";

import { BastionAquaSwapVMRouter } from "../../src/bastion/routers/BastionAquaSwapVMRouter.sol";
import { DeskAdmin } from "../../src/bastion/desk/DeskAdmin.sol";
import { MakerPriceAnchor } from "../../src/bastion/instructions/MakerPriceAnchor.sol";
import { PortfolioLedger } from "../../src/bastion/instructions/PortfolioLedger.sol";
import { PortfolioSwap } from "../../src/bastion/instructions/PortfolioSwap.sol";
import { Scale } from "../../src/bastion/pmm/Scale.sol";

import { TokenMockDecimals } from "../../test/mocks/TokenMockDecimals.sol";
import { MockTaker } from "../../test/mocks/MockTaker.sol";

// solhint-disable no-console
contract BastionSmokeLocal is Script {
    string internal constant ANVIL_MNEMONIC = "test test test test test test test test test test test junk";

    bytes32 internal constant GROUP_ID = bytes32(uint256(1));
    uint24 internal constant FEE_30BPS = 30_000; // 30 bps at upstream's D = 1e7
    uint256 internal constant K = 0.1e18;

    // Alice's wallet and what she advertises to Aqua on EACH book.
    uint256 internal constant MAKER_WETH = 50e18;
    uint256 internal constant MAKER_USDC = 400_000e6;
    uint256 internal constant BOOK_WETH = 10e18;
    uint256 internal constant BOOK_USDC = 100_000e6;

    // The shared PMM ledger. Deliberately NOT the same numbers as the Aqua advertisement:
    // advertised virtual amounts, shared pricing inventory and live backing are three
    // different things (spec 8).
    uint256 internal constant LEDGER_WETH = 10e18;

    uint256 internal constant FILL = 3_000e6; // Bob sells 3,000 fUSDC into book A
    uint256 internal constant PROBE = 1_000e6; // book B is quoted at 1,000 fUSDC throughout

    struct Env {
        Aqua aqua;
        BastionAquaSwapVMRouter desk;
        TokenMockDecimals weth;
        TokenMockDecimals usdc;
        MockTaker takerApp;
        uint256 deployerPk;
        uint256 makerPk;
        uint256 takerPk;
        uint256 signerPk;
        address maker;
        address anchorSigner;
    }

    function run() external {
        Env memory e = _env();

        // fWETH is the base leg, fUSDC the quote leg. 3,000 USDC per WETH at 6/18 decimals
        // is 3_000e6 in the curve's units, NOT 3_000e18 — see Scale.sol.
        uint256 anchorWad = Scale.toAnchorWad(3_000e18, 18, 6);
        uint256 ledgerUsdc = (LEDGER_WETH * anchorWad) / 1e18;

        _fund(e);
        _openDesk(e, anchorWad, ledgerUsdc);

        (ISwapVM.Order memory bookA, bytes32 hashA) = _shipBook(e, 1);
        (ISwapVM.Order memory bookB, bytes32 hashB) = _shipBook(e, 2);
        _postAnchor(e, anchorWad);

        console2.log("");
        console2.log("anchor priceWad (quote raw per base raw, 1e18) =", anchorWad);
        console2.log("  human price 3,000 USDC per WETH at 6/18 decimals");
        console2.log("shared ledger: fWETH", LEDGER_WETH, " fUSDC", ledgerUsdc);

        // ---- the claim -----------------------------------------------------
        uint256 quoteBefore = _quote(e, bookB, PROBE);
        (uint248 bBaseBefore,) = e.aqua.rawBalances(e.maker, address(e.desk), hashB, address(e.weth));
        (uint248 bQuoteBefore,) = e.aqua.rawBalances(e.maker, address(e.desk), hashB, address(e.usdc));

        console2.log("");
        console2.log("== BEFORE ==========================================");
        console2.log("  book B quote: 1,000 fUSDC in ->", quoteBefore, "fWETH out");

        vm.startBroadcast(e.takerPk);
        (uint256 amountIn, uint256 amountOut) = e.takerApp.swap(bookA, FILL, _swapTraits(e, true));
        vm.stopBroadcast();

        uint256 quoteAfter = _quote(e, bookB, PROBE);
        (uint248 bBaseAfter,) = e.aqua.rawBalances(e.maker, address(e.desk), hashB, address(e.weth));
        (uint248 bQuoteAfter,) = e.aqua.rawBalances(e.maker, address(e.desk), hashB, address(e.usdc));

        console2.log("");
        console2.log("== FILL ON BOOK A (real Aqua settlement) ===========");
        console2.log("  Bob paid   fUSDC =", amountIn);
        console2.log("  Bob got    fWETH =", amountOut);

        console2.log("");
        console2.log("== AFTER ===========================================");
        console2.log("  book B quote: 1,000 fUSDC in ->", quoteAfter, "fWETH out");
        console2.log("  book B quote moved by         ", quoteBefore - quoteAfter, "fWETH");
        console2.log("  book B Aqua fWETH before/after", uint256(bBaseBefore), uint256(bBaseAfter));
        console2.log("  book B Aqua fUSDC before/after", uint256(bQuoteBefore), uint256(bQuoteAfter));
        require(bBaseBefore == bBaseAfter && bQuoteBefore == bQuoteAfter, "book B's own balances moved");
        require(quoteAfter != quoteBefore, "book B's quote did not move");

        console2.log("");
        console2.log("  No transaction touched book B. Its own Aqua balances are identical.");
        console2.log("  Its quote changed because both books read ONE shared PMM state.");

        _reportState(e);
        console2.log("");
        console2.log("book A orderHash:");
        console2.logBytes32(hashA);
        console2.log("book B orderHash:");
        console2.logBytes32(hashB);
    }

    // ---- setup ------------------------------------------------------------

    function _fund(Env memory e) internal {
        vm.startBroadcast(e.deployerPk);
        e.weth.mint(e.maker, MAKER_WETH);
        e.usdc.mint(e.maker, MAKER_USDC);
        e.usdc.mint(address(e.takerApp), FILL * 4);
        vm.stopBroadcast();
    }

    function _openDesk(Env memory e, uint256 anchorWad, uint256 ledgerUsdc) internal {
        vm.startBroadcast(e.makerPk);
        e.weth.approve(address(e.aqua), type(uint256).max);
        e.usdc.approve(address(e.aqua), type(uint256).max);
        e.desk.initRiskGroup(
            GROUP_ID, address(e.weth), address(e.usdc), K, e.anchorSigner, anchorWad, LEDGER_WETH, ledgerUsdc
        );
        vm.stopBroadcast();
    }

    function _shipBook(Env memory e, uint64 salt) internal returns (ISwapVM.Order memory order, bytes32 orderHash) {
        (address tokenA, address tokenB) = address(e.weth) < address(e.usdc)
            ? (address(e.weth), address(e.usdc))
            : (address(e.usdc), address(e.weth));
        bool wethIsA = tokenA == address(e.weth);

        order = MakerTraitsLib.build(MakerTraitsLib.Args({
            maker: e.maker,
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
            program: bytes.concat(
                MakerPriceAnchor.build(),
                PortfolioLedger.build(),
                FeeFlatIn.build(FEE_30BPS),
                PortfolioSwap.build(),
                Salt.build(salt)
            )
        }));
        orderHash = e.desk.hash(order);

        address[] memory tokens = new address[](2);
        uint256[] memory amounts = new uint256[](2);
        tokens[0] = tokenA;
        tokens[1] = tokenB;
        amounts[0] = wethIsA ? BOOK_WETH : BOOK_USDC;
        amounts[1] = wethIsA ? BOOK_USDC : BOOK_WETH;

        vm.startBroadcast(e.makerPk);
        bytes32 shipped = e.aqua.ship(address(e.desk), abi.encode(order), tokens, amounts);
        e.desk.admitBook(GROUP_ID, orderHash);
        vm.stopBroadcast();
        require(shipped == orderHash, "strategyHash != desk.hash(order)");
    }

    function _postAnchor(Env memory e, uint256 anchorWad) internal {
        DeskAdmin.Anchor memory a = DeskAdmin.Anchor({
            maker: e.maker,
            riskGroupId: GROUP_ID,
            policyVersion: 1,
            priceWad: anchorWad,
            issuedAt: uint64(block.timestamp),
            expiry: uint64(block.timestamp + 1 days),
            confidenceBps: 10,
            nonce: 1
        });
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(e.signerPk, e.desk.hashAnchorView(a));
        // permissionless: the deployer publishes a maker-scoped signature, not its own
        vm.startBroadcast(e.deployerPk);
        e.desk.postAnchor(a, abi.encodePacked(r, s, v));
        vm.stopBroadcast();
    }

    // ---- reads ------------------------------------------------------------

    function _quote(Env memory e, ISwapVM.Order memory order, uint256 amount) internal view returns (uint256 out) {
        (, out,) = e.desk.asView().quote(order, amount, _quoteTraits(e, true));
    }

    function _reportState(Env memory e) internal view {
        (uint256 i, uint256 k, uint256 b, uint256 q, uint256 b0, uint256 q0, uint8 r) =
            e.desk.riskGroupState(e.maker, GROUP_ID);
        console2.log("");
        console2.log("== SHARED PMM STATE (one per maker risk group) =====");
        console2.log("  i (anchor wad)", i);
        console2.log("  k            ", k);
        console2.log("  B  fWETH     ", b);
        console2.log("  Q  fUSDC     ", q);
        console2.log("  B0 fWETH     ", b0);
        console2.log("  Q0 fUSDC     ", q0);
        console2.log("  R            ", r);
    }

    // ---- traits -----------------------------------------------------------

    /// @param usdcIn true when the taker pays fUSDC. isAToB means tokenIn == tokenA.
    function _quoteTraits(Env memory e, bool usdcIn) internal view returns (bytes memory) {
        bool usdcIsA = address(e.usdc) < address(e.weth);
        return _traits(e, usdcIn == usdcIsA, false);
    }

    function _swapTraits(Env memory e, bool usdcIn) internal view returns (bytes memory) {
        bool usdcIsA = address(e.usdc) < address(e.weth);
        return _traits(e, usdcIn == usdcIsA, true);
    }

    function _traits(Env memory e, bool isAToB, bool withCallback) internal pure returns (bytes memory) {
        return TakerTraitsLib.build(TakerTraitsLib.Args({
            taker: address(e.takerApp),
            isExactIn: true,
            shouldUnwrapWeth: false,
            hasPreTransferInCallback: withCallback,
            hasPreTransferOutCallback: false,
            isStrictThresholdAmount: false,
            isFirstTransferFromTaker: false,
            useTransferFromAndAquaPush: false,
            isAToB: isAToB,
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
    }

    function _env() internal view returns (Env memory e) {
        e.aqua = Aqua(vm.envAddress("AQUA"));
        e.desk = BastionAquaSwapVMRouter(payable(vm.envAddress("DESK")));
        e.weth = TokenMockDecimals(vm.envAddress("FWETH"));
        e.usdc = TokenMockDecimals(vm.envAddress("FUSDC"));
        e.takerApp = MockTaker(vm.envAddress("TAKER_APP"));

        e.deployerPk = vm.deriveKey(ANVIL_MNEMONIC, 0);
        e.makerPk = vm.deriveKey(ANVIL_MNEMONIC, 1);
        e.takerPk = vm.deriveKey(ANVIL_MNEMONIC, 2);
        e.signerPk = vm.deriveKey(ANVIL_MNEMONIC, 3); // anchor-only key, scoped to signing
        e.maker = vm.addr(e.makerPk);
        e.anchorSigner = vm.addr(e.signerPk);
    }
}

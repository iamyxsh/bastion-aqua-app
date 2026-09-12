// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { TokenMock } from "@1inch/solidity-utils/contracts/mocks/TokenMock.sol";

import { AquaSwapVMTest } from "../base/AquaSwapVMTest.sol";
import { SwapVM } from "../../src/SwapVM.sol";
import { ISwapVM } from "../../src/interfaces/ISwapVM.sol";
import { TakerTraitsLib } from "../../src/libs/TakerTraits.sol";
import { Salt } from "../../src/instructions/Controls.sol";
import { FeeFlatIn } from "../../src/instructions/FeeFlat.sol";

import { BastionAquaSwapVMRouter } from "../../src/bastion/routers/BastionAquaSwapVMRouter.sol";
import { DeskAdmin } from "../../src/bastion/desk/DeskAdmin.sol";
import { MakerPriceAnchor } from "../../src/bastion/instructions/MakerPriceAnchor.sol";
import { PortfolioLedger } from "../../src/bastion/instructions/PortfolioLedger.sol";
import { PortfolioSwap } from "../../src/bastion/instructions/PortfolioSwap.sol";

/// BASTION — shared fixture for milestone 3 tests.
///
/// Reuses upstream's own Aqua test base and only swaps the router, so any behaviour these
/// tests observe is the Bastion router's, not a bespoke harness's.
abstract contract BastionTestBase is AquaSwapVMTest {
    bytes32 internal constant GROUP_ID = bytes32(uint256(1));

    /// 30 bps at upstream's D = 1e7 fee scale (src/instructions/FeeFlat.sol).
    uint24 internal constant FEE_30BPS = 30_000;

    uint256 internal constant K = 0.1e18;
    /// tokenA/tokenB are both 18 decimals in the upstream fixture, so no scaling is needed.
    uint256 internal constant ANCHOR = 3_000e18;
    uint256 internal constant LEDGER_BASE = 10e18;
    uint256 internal constant LEDGER_QUOTE = 30_000e18;

    uint256 internal signerPk = 0xA11CE51;
    address internal anchorSigner;

    BastionAquaSwapVMRouter internal desk;

    /// Advertised Aqua virtual balances. Deliberately NOT the same numbers as the PMM
    /// ledger: spec 8 keeps advertised virtual amounts, shared pricing inventory and live
    /// backing separate, and using one number for all three would hide that.
    uint256 internal constant AQUA_BASE = 50e18;
    uint256 internal constant AQUA_QUOTE = 200_000e18;

    function setUp() public virtual override {
        super.setUp();
        desk = BastionAquaSwapVMRouter(payable(address(swapVM)));
        anchorSigner = vm.addr(signerPk);

        // Alice must actually hold what she advertises: an Aqua balance is an allowance over
        // tokens that never leave her wallet.
        tokenA.mint(maker, AQUA_BASE);
        tokenB.mint(maker, AQUA_QUOTE);
        tokenA.mint(address(taker), 1_000e18);
        tokenB.mint(address(taker), 1_000_000e18);
    }

    /// Ship a book to Aqua so `quote` can read its virtual balances, and admit it here.
    function _ship(ISwapVM.Order memory order) internal returns (bytes32 orderHash) {
        orderHash = shipStrategy(swapVM, order, tokenA, tokenB, AQUA_BASE, AQUA_QUOTE);
    }

    function _deployRouter() internal virtual override returns (SwapVM) {
        return SwapVM(payable(address(new BastionAquaSwapVMRouter(address(aqua), address(0), address(this), "Bastion", "1"))));
    }

    /// The supported initial grammar. Nesting is implicit in program order:
    /// PortfolioLedger wraps FeeFlatIn, which wraps PortfolioSwap.
    function _bastionProgram(uint64 salt) internal pure returns (bytes memory) {
        return bytes.concat(
            MakerPriceAnchor.build(),
            PortfolioLedger.build(),
            FeeFlatIn.build(FEE_30BPS),
            PortfolioSwap.build(),
            Salt.build(salt)
        );
    }

    /// @dev base = tokenA, quote = tokenB, matching the group opened below.
    function _openGroup() internal {
        vm.prank(maker);
        desk.initRiskGroup(
            GROUP_ID, address(tokenA), address(tokenB), K, anchorSigner, ANCHOR, LEDGER_BASE, LEDGER_QUOTE
        );
    }

    function _admit(bytes32 orderHash) internal {
        vm.prank(maker);
        desk.admitBook(GROUP_ID, orderHash);
    }

    function _anchor(uint256 priceWad, uint256 nonce, uint64 expiry) internal view returns (DeskAdmin.Anchor memory) {
        return DeskAdmin.Anchor({
            maker: maker,
            riskGroupId: GROUP_ID,
            policyVersion: 1,
            priceWad: priceWad,
            issuedAt: uint64(block.timestamp),
            expiry: expiry,
            confidenceBps: 10,
            nonce: nonce
        });
    }

    function _sign(DeskAdmin.Anchor memory a, uint256 pk) internal view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, desk.hashAnchorView(a));
        return abi.encodePacked(r, s, v);
    }

    function _post(uint256 priceWad, uint256 nonce, uint64 expiry) internal {
        DeskAdmin.Anchor memory a = _anchor(priceWad, nonce, expiry);
        desk.postAnchor(a, _sign(a, signerPk));
    }

    /// A live desk: group open, book admitted, anchor posted.
    function _liveBook(uint64 salt) internal returns (ISwapVM.Order memory order, bytes32 orderHash) {
        _openGroup();
        order = createStrategy(_bastionProgram(salt));
        orderHash = _ship(order);
        _admit(orderHash);
        _post(ANCHOR, 1, uint64(block.timestamp + 1 hours));
    }

    /// Taker traits for a plain exact-in quote in one direction.
    /// @param aToB true means tokenIn == tokenA (base in)
    function _traits(bool aToB) internal view returns (bytes memory) {
        return TakerTraitsLib.build(TakerTraitsLib.Args({
            taker: address(taker),
            isExactIn: true,
            shouldUnwrapWeth: false,
            hasPreTransferInCallback: false,
            hasPreTransferOutCallback: false,
            isStrictThresholdAmount: false,
            isFirstTransferFromTaker: false,
            useTransferFromAndAquaPush: false,
            isAToB: aToB,
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

    /// Taker traits for a real settled fill. The callback is what makes MockTaker push the
    /// input into Aqua, which is how tokens actually move.
    function _swapTraits(bool aToB) internal view returns (bytes memory) {
        return TakerTraitsLib.build(TakerTraitsLib.Args({
            taker: address(taker),
            isExactIn: true,
            shouldUnwrapWeth: false,
            hasPreTransferInCallback: true,
            hasPreTransferOutCallback: false,
            isStrictThresholdAmount: false,
            isFirstTransferFromTaker: false,
            useTransferFromAndAquaPush: false,
            isAToB: aToB,
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

    function _exactOutTraits(bool aToB) internal view returns (bytes memory) {
        return TakerTraitsLib.build(TakerTraitsLib.Args({
            taker: address(taker),
            isExactIn: false,
            shouldUnwrapWeth: false,
            hasPreTransferInCallback: false,
            hasPreTransferOutCallback: false,
            isStrictThresholdAmount: false,
            isFirstTransferFromTaker: false,
            useTransferFromAndAquaPush: false,
            isAToB: aToB,
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
}

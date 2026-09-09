// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// BASTION — premise check, not a demo result.
///
/// Question: does DODO's PMM curve, with a maker who updates its index price daily,
/// actually beat plain constant product and a real concentrated-liquidity band over
/// real ETH price history?
///
/// All three curves are the real implementations:
///   XYK   upstream `XYCSwap.exec`            (unmodified SwapVM)
///   CLMM  upstream `XYCConcentrateSwap.exec` (unmodified SwapVM)
///   PMM   DODO's `PMMPricing`, compiled separately at solc 0.6.9 and reached through
///         reference/dodo/src/PMMHarness.sol via vm.getCode -- never re-implemented here
///
/// Prices are real ETH/USD daily closes from Binance; see PriceWindows.sol for
/// provenance. The CLMM band width is a real Gamma Strategies band.
///
/// What this is NOT: it does not settle through Aqua, it is not a Bastion contract,
/// and it charges no swap fees to anyone. See experiments/curves/README.md for limitations.

import { Test } from "forge-std/Test.sol";
import { console2 } from "forge-std/console2.sol";

import { Context } from "swap-vm/libs/VM.sol";
import { XYCSwap } from "swap-vm/instructions/XYCSwap.sol";
import { XYCConcentrateSwap } from "swap-vm/instructions/XYCConcentrate.sol";

import { PriceWindows } from "./PriceWindows.sol";

interface IPMMHarness {
    function sellBase(uint256 i, uint256 K, uint256 B, uint256 Q, uint256 B0, uint256 Q0, uint8 R, uint256 pay)
        external pure returns (uint256 receiveQuote, uint8 newR);
    function sellQuote(uint256 i, uint256 K, uint256 B, uint256 Q, uint256 B0, uint256 Q0, uint8 R, uint256 pay)
        external pure returns (uint256 receiveBase, uint8 newR);
    function adjustTarget(uint256 i, uint256 K, uint256 B, uint256 Q, uint256 B0, uint256 Q0, uint8 R)
        external pure returns (uint256 newB0, uint256 newQ0);
    function midPrice(uint256 i, uint256 K, uint256 B, uint256 Q, uint256 B0, uint256 Q0, uint8 R)
        external pure returns (uint256);
}

// solhint-disable no-console
contract CurveComparisonTest is Test {
    uint256 internal constant ONE = 1e18;

    // Both legs are 18 decimals on purpose. Decimal scaling is a separate concern with
    // its own tests; mixing it in here would confound the economics being measured.
    address internal constant ETH = address(0x1111111111111111111111111111111111111111);
    address internal constant USD = address(0x2222222222222222222222222222222222222222);

    /// Alice always starts with 10 ETH and its value in USD at the window's first close,
    /// so every curve begins balanced at the real starting price.
    uint256 internal constant START_ETH = 10e18;

    /// Gamma Strategies, vault 0xa9782a2c9c3fb83937f14cdfac9a6d23946c9255 on the Uniswap
    /// V3 USDC/WETH 0.05% pool 0x88e6a0c2ddd26feeb64f039a2c41296fcb3f5640.
    /// Base band ticks [197160, 198660] -> $2,359..$2,741, a geometric halfwidth of
    /// +/-7.8%. A second Gamma vault on the same pool used the identical 1500-tick width.
    /// Read from https://wire2.gamma.xyz/hypervisors/allData on 2026-09-06.
    uint256 internal constant BAND_HALFWIDTH_BPS = 780;

    uint256 internal constant ARB_ITERS = 64;

    IPMMHarness internal pmm;

    struct Pool { uint256 base; uint256 quote; }
    struct Flow { uint256 trades; uint256 volumeUsd; }
    Flow private fXyk; Flow private fClmm; Flow private fPmm;
    struct Pmm { uint256 i; uint256 K; uint256 B; uint256 Q; uint256 B0; uint256 Q0; uint8 R; }

    function setUp() public {
        // The 0.6.9 reference is compiled by its own project. Loading its artifact keeps
        // this test honest: nothing here is a second copy of DODO's math.
        bytes memory code = vm.getCode("../../reference/dodo/out/PMMHarness.sol/PMMHarness.json");
        address a;
        assembly { a := create(0, add(code, 0x20), mload(code)) }
        require(a != address(0), "PMMHarness deploy failed - run: forge build --root reference/dodo");
        pmm = IPMMHarness(a);
    }

    // ------------------------------------------------------------------ curves

    /// @dev Upstream constant product, called through its real `exec`.
    function _xykOut(uint256 balIn, uint256 balOut, uint256 amtIn) internal pure returns (uint256) {
        if (amtIn == 0 || balIn == 0 || balOut == 0) return 0;
        Context memory ctx;
        ctx.query.isExactIn = true;
        ctx.swap.balanceIn = balIn;
        ctx.swap.balanceOut = balOut;
        ctx.swap.amountIn = amtIn;
        XYCSwap.exec(ctx, msg.data[0:0]);
        return ctx.swap.amountOut > balOut ? balOut : ctx.swap.amountOut;
    }

    /// @dev Upstream concentrated liquidity, called through its real `exec`.
    ///      `args` is the instruction's own encoding: two uint256 sqrt prices.
    function _clmmFill(uint256 balIn, uint256 balOut, uint256 amtIn, bool ethIn, bytes calldata args)
        internal pure returns (uint256 spent, uint256 received)
    {
        // A one-sided concentrated position can receive its missing token.
        if (amtIn == 0 || balOut == 0) return (0, 0);
        Context memory ctx;
        ctx.query.isExactIn = true;
        ctx.query.tokenIn = ethIn ? ETH : USD;
        ctx.query.tokenOut = ethIn ? USD : ETH;
        ctx.swap.balanceIn = balIn;
        ctx.swap.balanceOut = balOut;
        ctx.swap.amountIn = amtIn;
        XYCConcentrateSwap.exec(ctx, args);
        return (ctx.swap.amountIn, ctx.swap.amountOut);
    }

    // ------------------------------------------------------- arbitrage per step

    /// @dev The arbitrageur trades the size that maximises his own profit against the
    ///      real external price. Ternary search, because profit is concave in size and
    ///      this needs no closed form -- so the same routine works for all three curves.
    // A profitable gross input cannot exceed the market value of all output reserves.
    // Callers use that bound, including when the input-token reserve is zero.
    function _bestSize(uint256 hi, function(uint256) internal view returns (int256) profit)
        private view returns (uint256 best)
    {
        uint256 lo = 0;
        for (uint256 n = 0; n < ARB_ITERS; n++) {
            uint256 m1 = lo + (hi - lo) / 3;
            uint256 m2 = hi - (hi - lo) / 3;
            if (profit(m1) < profit(m2)) lo = m1; else hi = m2;
        }
        best = (lo + hi) / 2;
        if (profit(best) <= 0) best = 0;
    }

    // XYK / CLMM share these scratch slots so the profit closures stay cheap.
    uint256 private _bIn; uint256 private _bOut; uint256 private _px; bool _ethIn;
    uint256 private _sqrtMin; uint256 private _sqrtMax; bool private _isClmm;

    function _profitEthOut(uint256 dyUsd) internal view returns (int256) {
        (uint256 spent, uint256 ethOut) = _isClmm
            ? this.clmmProxy(_bIn, _bOut, dyUsd, false, _sqrtMin, _sqrtMax)
            : (dyUsd, _xykOut(_bIn, _bOut, dyUsd));
        return int256(ethOut * _px / ONE) - int256(spent);
    }

    function _profitUsdOut(uint256 dxEth) internal view returns (int256) {
        (uint256 spent, uint256 usdOut) = _isClmm
            ? this.clmmProxy(_bIn, _bOut, dxEth, true, _sqrtMin, _sqrtMax)
            : (dxEth, _xykOut(_bIn, _bOut, dxEth));
        return int256(usdOut) - int256(spent * _px / ONE);
    }

    /// @dev External so that `args` is genuine calldata for the instruction's parser.
    function clmmProxy(uint256 balIn, uint256 balOut, uint256 amtIn, bool ethIn, uint256 sMin, uint256 sMax)
        external view returns (uint256, uint256)
    {
        return this.clmmInner(balIn, balOut, amtIn, ethIn, abi.encodePacked(sMin, sMax));
    }

    function clmmInner(uint256 balIn, uint256 balOut, uint256 amtIn, bool ethIn, bytes calldata args)
        external pure returns (uint256, uint256)
    {
        return _clmmFill(balIn, balOut, amtIn, ethIn, args);
    }

    function _stepPassive(Pool memory p, uint256 price, bool isClmm, uint256 sMin, uint256 sMax)
        internal
    {
        _isClmm = isClmm; _sqrtMin = sMin; _sqrtMax = sMax; _px = price;
        uint256 mid;
        if (isClmm) {
            // Real spot of the concentrated position: virtual reserves, not raw ones.
            (, uint256 sqrtSpot) = XYCConcentrateSwap.computeLiquidityAndPrice(p.base, p.quote, sMin, sMax);
            mid = sqrtSpot * sqrtSpot / ONE;
        } else {
            mid = p.quote * ONE / p.base;
        }
        if (mid < price) {
            _bIn = p.quote; _bOut = p.base;
            uint256 dy = _bestSize(p.base * price / ONE, _profitEthOut);
            if (dy == 0) return;
            (uint256 spent, uint256 ethOut) = isClmm
                ? this.clmmProxy(p.quote, p.base, dy, false, sMin, sMax)
                : (dy, _xykOut(p.quote, p.base, dy));
            dy = spent;
            if (ethOut == 0 || ethOut > p.base) return;
            p.quote += dy; p.base -= ethOut;
            if (isClmm) { fClmm.trades++; fClmm.volumeUsd += dy; }
            else        { fXyk.trades++;  fXyk.volumeUsd  += dy; }
        } else if (mid > price) {
            _bIn = p.base; _bOut = p.quote;
            uint256 dx = _bestSize(p.quote * ONE / price, _profitUsdOut);
            if (dx == 0) return;
            (uint256 spent, uint256 usdOut) = isClmm
                ? this.clmmProxy(p.base, p.quote, dx, true, sMin, sMax)
                : (dx, _xykOut(p.base, p.quote, dx));
            dx = spent;
            if (usdOut == 0 || usdOut > p.quote) return;
            p.base += dx; p.quote -= usdOut;
            if (isClmm) { fClmm.trades++; fClmm.volumeUsd += usdOut; }
            else        { fXyk.trades++;  fXyk.volumeUsd  += usdOut; }
        }
    }

    // ------------------------------------------------------------------- PMM

    Pmm private _s;

    function _profitPmmEthOut(uint256 dyUsd) internal view returns (int256) {
        (uint256 ethOut,) = pmm.sellQuote(_s.i, _s.K, _s.B, _s.Q, _s.B0, _s.Q0, _s.R, dyUsd);
        return int256(ethOut * _px / ONE) - int256(dyUsd);
    }

    function _profitPmmUsdOut(uint256 dxEth) internal view returns (int256) {
        (uint256 usdOut,) = pmm.sellBase(_s.i, _s.K, _s.B, _s.Q, _s.B0, _s.Q0, _s.R, dxEth);
        return int256(usdOut) - int256(dxEth * _px / ONE);
    }

    /// @param anchor  what Alice's keeper last observed (yesterday's close)
    /// @param price   where the market actually is now
    /// @dev The anchor is deliberately STALE. Setting it to `price` makes the pool mid
    ///      equal the market, so no arbitrage exists, PMM never trades and trivially
    ///      matches holding. That is an assumption doing all the work, not a result.
    function _stepPmm(Pmm memory s, uint256 anchor, uint256 price) internal {
        s.i = anchor;
        (s.B0, s.Q0) = pmm.adjustTarget(s.i, s.K, s.B, s.Q, s.B0, s.Q0, s.R);

        // 2. Arbitrage against the same external price.
        _s = s; _px = price;
        uint256 mid = pmm.midPrice(s.i, s.K, s.B, s.Q, s.B0, s.Q0, s.R);
        if (mid < price) {
            uint256 dy = _bestSize(s.B * price / ONE, _profitPmmEthOut);
            if (dy == 0) return;
            (uint256 ethOut, uint8 r) = pmm.sellQuote(s.i, s.K, s.B, s.Q, s.B0, s.Q0, s.R, dy);
            if (ethOut == 0 || ethOut > s.B) return;
            s.Q += dy; s.B -= ethOut; s.R = r;
            fPmm.trades++; fPmm.volumeUsd += dy;
        } else if (mid > price) {
            uint256 dx = _bestSize(s.Q * ONE / price, _profitPmmUsdOut);
            if (dx == 0) return;
            (uint256 usdOut, uint8 r) = pmm.sellBase(s.i, s.K, s.B, s.Q, s.B0, s.Q0, s.R, dx);
            if (usdOut == 0 || usdOut > s.Q) return;
            s.B += dx; s.Q -= usdOut; s.R = r;
            fPmm.trades++; fPmm.volumeUsd += usdOut;
        }
    }

    // --------------------------------------------------------------- the run

    function _sqrt1e18(uint256 priceWad) internal pure returns (uint256) {
        return sqrt(priceWad * ONE);
    }

    function sqrt(uint256 x) internal pure returns (uint256 y) {
        if (x == 0) return 0;
        y = x; uint256 z = (x + 1) / 2;
        while (z < y) { y = z; z = (x / z + z) / 2; }
    }

    /// @return valXyk valClmm valPmm valHold, all in USD wad at the final price
    function _run(uint256[] memory px, uint256 K)
        internal
        returns (uint256 valXyk, uint256 valClmm, uint256 valPmm, uint256 valHold)
    {
        fXyk = Flow(0, 0); fClmm = Flow(0, 0); fPmm = Flow(0, 0);
        uint256 p0 = px[0];
        uint256 startUsd = START_ETH * p0 / ONE;

        Pool memory a = Pool(START_ETH, startUsd);
        Pool memory b = Pool(START_ETH, startUsd);
        Pmm memory s = Pmm(p0, K, START_ETH, startUsd, START_ETH, startUsd, 0);

        // Band is centred on the window's starting price, the way a vault that had just
        // rebalanced would be. Halfwidth is Gamma's real 7.8%.
        uint256 lo = p0 * (10_000 - BAND_HALFWIDTH_BPS) / 10_000;
        uint256 hi = p0 * (10_000 + BAND_HALFWIDTH_BPS) / 10_000;
        uint256 sMin = _sqrt1e18(lo);
        uint256 sMax = _sqrt1e18(hi);

        for (uint256 d = 1; d < px.length; d++) {
            _stepPassive(a, px[d], false, 0, 0);
            _stepPassive(b, px[d], true, sMin, sMax);
            _stepPmm(s, px[d - 1], px[d]);   // keeper posts yesterday's close
        }

        uint256 pN = px[px.length - 1];
        valXyk  = a.base * pN / ONE + a.quote;
        valClmm = b.base * pN / ONE + b.quote;
        valPmm  = s.B * pN / ONE + s.Q;
        valHold = START_ETH * pN / ONE + startUsd;
    }

    function _pct(uint256 v, uint256 hold) internal pure returns (int256) {
        return (int256(v) - int256(hold)) * 10_000 / int256(hold);   // bps vs holding
    }

    function _report(string memory name, uint256[] memory px, uint256 K) internal {
        (uint256 x, uint256 c, uint256 m, uint256 h) = _run(px, K);
        console2.log("");
        console2.log(string.concat("--- ", name, "  K = ", vm.toString(K * 100 / ONE), "/100"));
        console2.log("  hold                 USD", h / ONE);
        console2.log("  XYK   constant prod  USD", x / ONE);
        console2.log("  CLMM  Gamma +/-7.8%  USD", c / ONE);
        console2.log("  PMM   daily anchor   USD", m / ONE);
        console2.log("  vs hold, bps:  XYK", _pct(x, h));
        console2.log("                 CLMM", _pct(c, h));
        console2.log("                 PMM ", _pct(m, h));
        console2.log("  arb trades:    XYK", fXyk.trades);
        console2.log("                 CLMM", fClmm.trades);
        console2.log("                 PMM ", fPmm.trades);
        console2.log("  arb volume USD XYK", fXyk.volumeUsd / ONE);
        console2.log("                 CLMM", fClmm.volumeUsd / ONE);
        console2.log("                 PMM ", fPmm.volumeUsd / ONE);
    }

    function test_CurveComparison() public {
        uint256 K = ONE / 10;   // placeholder single run; sweep lives in the K test
        _report("TREND UP    2025-06-23..08-22", PriceWindows.trendup(), K);
        _report("TREND DOWN  2025-01-15..03-16", PriceWindows.trenddown(), K);
        _report("CHOP        2025-03-24..05-23", PriceWindows.chop(), K);
        _report("QUIET       2025-11-23..01-22", PriceWindows.quiet(), K);
    }

    /// @notice Harness self-check, not a result.
    ///
    ///   At K = 1 and with the anchor FROZEN at the start price, DODO's curve is the
    ///   constant-product curve. So PMM must land on the XYK number. If it does not,
    ///   the harness, the state updates or the arbitrage loop is wrong and no number
    ///   from this file can be trusted.
    ///
    ///   The anchor must be frozen for this to hold. An earlier version of this check
    ///   let the anchor track the price, which made PMM never trade; it then "matched"
    ///   XYK only because the quiet window barely moves. That was a false pass.
    function test_SelfCheck_PmmAtK1_FrozenAnchor_IsConstantProduct() public {
        for (uint256 w = 0; w < 4; w++) {
        (uint256 x, uint256 m) = _runFrozenAnchor(_window(w), ONE);
        uint256 diff = x > m ? x - m : m - x;
        uint256 bps = diff * 10_000 / x;
        console2.log("self-check  XYK USD", x / ONE);
        console2.log("self-check  PMM USD", m / ONE);
        console2.log("self-check  diff bps", bps);
        assertApproxEqRel(m, x, 1e10, "K=1 frozen anchor: relative error exceeds 1e-8");
        }
    }

    /// @dev Same loop, but Alice never moves her anchor. Used only by the self-check.
    function _runFrozenAnchor(uint256[] memory px, uint256 K)
        internal
        returns (uint256 valXyk, uint256 valPmm)
    {
        fXyk = Flow(0, 0); fClmm = Flow(0, 0); fPmm = Flow(0, 0);
        uint256 p0 = px[0];
        uint256 startUsd = START_ETH * p0 / ONE;
        Pool memory a = Pool(START_ETH, startUsd);
        Pmm memory s = Pmm(p0, K, START_ETH, startUsd, START_ETH, startUsd, 0);
        for (uint256 d = 1; d < px.length; d++) {
            _stepPassive(a, px[d], false, 0, 0);
            _stepPmm(s, p0, px[d]);            // anchor frozen at p0
        }
        uint256 pN = px[px.length - 1];
        valXyk = a.base * pN / ONE + a.quote;
        valPmm = s.B * pN / ONE + s.Q;
    }

    /// @notice How PMM's result depends on K. No single K is defensible on its own, so
    ///         the answer is reported as a curve. Anchor is one day stale throughout.
    function test_KSweep() public {
        uint256[4] memory ks = [ONE / 100, ONE / 10, ONE / 2, ONE];
        string[4] memory names = ["TREND UP", "TREND DOWN", "CHOP", "QUIET"];
        for (uint256 w = 0; w < 4; w++) {
            uint256[] memory px = _window(w);
            console2.log("");
            console2.log(string.concat("--- K sweep, ", names[w], " (bps vs holding, 1-day stale anchor)"));
            (uint256 x, uint256 c,, uint256 h) = _run(px, ONE / 10);
            console2.log("   XYK ", _pct(x, h));
            console2.log("   CLMM", _pct(c, h));
            for (uint256 j = 0; j < ks.length; j++) {
                (,, uint256 m, uint256 hh) = _run(px, ks[j]);
                console2.log(string.concat("   PMM K=", vm.toString(ks[j] * 100 / ONE), "/100"), _pct(m, hh));
            }
        }
    }

    /// @notice How PMM's result depends on anchor FRESHNESS, which is the variable the
    ///         keeper actually controls. f = 0 means one full day stale; f = 100 means
    ///         the anchor is exactly the price arbitrageurs trade against, which is
    ///         unattainable and shown only as the ceiling.
    function test_FreshnessSweep() public {
        uint256[5] memory fs = [uint256(0), 50, 90, 99, 100];
        string[4] memory names = ["TREND UP", "TREND DOWN", "CHOP", "QUIET"];
        for (uint256 w = 0; w < 4; w++) {
            uint256[] memory px = _window(w);
            console2.log("");
            console2.log(string.concat("--- freshness sweep, ", names[w], " (bps vs holding, K=0.1)"));
            (uint256 x, uint256 c,, uint256 h) = _run(px, ONE / 10);
            console2.log("   XYK  (no oracle) ", _pct(x, h));
            console2.log("   CLMM (no oracle) ", _pct(c, h));
            for (uint256 j = 0; j < fs.length; j++) {
                (uint256 m, uint256 hh) = _runFreshness(px, ONE / 10, fs[j]);
                console2.log(string.concat("   PMM anchor ", vm.toString(fs[j]), "% fresh"), _pct(m, hh));
            }
        }
    }

    /// @dev anchor = yesterday + f% of today's move. f is the share of the move the
    ///      keeper managed to publish before arbitrageurs acted.
    function _runFreshness(uint256[] memory px, uint256 K, uint256 fPct)
        internal
        returns (uint256 valPmm, uint256 valHold)
    {
        fPmm = Flow(0, 0);
        uint256 p0 = px[0];
        uint256 startUsd = START_ETH * p0 / ONE;
        Pmm memory s = Pmm(p0, K, START_ETH, startUsd, START_ETH, startUsd, 0);
        for (uint256 d = 1; d < px.length; d++) {
            uint256 prev = px[d - 1];
            uint256 cur = px[d];
            uint256 anchor = cur > prev
                ? prev + (cur - prev) * fPct / 100
                : prev - (prev - cur) * fPct / 100;
            _stepPmm(s, anchor, cur);
        }
        uint256 pN = px[px.length - 1];
        valPmm = s.B * pN / ONE + s.Q;
        valHold = START_ETH * pN / ONE + startUsd;
    }


    function test_Clmm_OneSidedPositionCanTradeBackIntoRange() public {
        Pool memory pool = Pool(0, 60_000e18);
        uint256 sMin = _sqrt1e18(2500e18);
        uint256 sMax = _sqrt1e18(3000e18);
        _stepPassive(pool, 2800e18, true, sMin, sMax);
        assertGt(pool.base, 0, "reverse fill must restore the missing base reserve");
        assertLt(pool.quote, 60_000e18);
        (, uint256 spot) = XYCConcentrateSwap.computeLiquidityAndPrice(pool.base, pool.quote, sMin, sMax);
        assertApproxEqRel(spot * spot / ONE, 2800e18, 1e10);
    }

    function test_Clmm_PartialFillOnlyCreditsConsumedInput() public view {
        (uint256 spent, uint256 received) = this.clmmProxy(
            10e18, 30_000e18, 1000e18, true, _sqrt1e18(2800e18), _sqrt1e18(3200e18)
        );
        assertEq(received, 30_000e18);
        assertLt(spent, 1000e18, "must not credit the entire requested input");
        assertGt(spent, 0);
    }

    function _window(uint256 w) internal pure returns (uint256[] memory) {
        if (w == 0) return PriceWindows.trendup();
        if (w == 1) return PriceWindows.trenddown();
        if (w == 2) return PriceWindows.chop();
        return PriceWindows.quiet();
    }
}

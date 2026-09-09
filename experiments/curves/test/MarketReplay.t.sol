// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Context} from "swap-vm/libs/VM.sol";
import {XYCSwap} from "swap-vm/instructions/XYCSwap.sol";
import {XYCConcentrateSwap} from "swap-vm/instructions/XYCConcentrate.sol";
import {IPMMHarness} from "./CurveComparison.t.sol";

/// Counterfactual market replay, not an Aqua deployment or a Bastion PMM port.
/// The Python runner selects parameters using training days ONLY. This contract
/// handles every fill and state change with the actual Solidity pricing libraries.
contract MarketReplayTest is Test {
    uint256 constant W = 1e18;
    uint256 constant D = 10_000;
    uint256 constant RECORD_BYTES = 11 * 32;
    uint256 constant SEARCH_STEPS = 48;
    address constant BASE = address(0x1111);
    address constant QUOTE = address(0x2222);
    IPMMHarness internal referencePmm;

    // kind: 0 XYC, 1 static CLMM, 2 PMM, 3 daily-rebalanced CLMM.
    struct Pool {
        uint256 B; uint256 Q; uint256 B0; uint256 Q0;
        uint256 i; uint256 K; uint256 R;
        uint256 sqrtMin; uint256 sqrtMax;
        uint256 kind; uint256 feeBps;
    }
    struct Fill { uint256 gross; uint256 net; uint256 out; uint256 fee; uint256 R; }
    struct Stats {
        uint256 requests; uint256 fills; uint256 rejected; uint256 partials;
        uint256 volume; uint256 offered; uint256 arbTrades; uint256 arbVolume;
        uint256 fees; uint256 rebalanceCost; uint256 rebalances; uint256 updates;
        uint256 peak; uint256 maxDrawdownBps; uint256 lastPrice; uint256 lastTime;
        uint256 maxAnchorAgeUs;
        int256 tradePnl; int256 holdingPnl; int256 customerCost; int256 arbLoss;
    }
    struct Event {
        uint256 time; uint256 quantity; uint256 price; bool baseIn;
        uint256 anchorTime; uint256 anchorPrice;
    }
    uint256 internal capital;
    uint256 internal lag;
    uint256 internal band;
    uint256 internal takerLimit;
    uint256 internal rebalanceFee;
    uint256 internal rebalanceFixed;
    uint256 internal rebalanceInterval;

    function setUp() public {
        bytes memory code = vm.getCode("../../reference/dodo/out/PMMHarness.sol/PMMHarness.json");
        address deployed;
        assembly { deployed := create(0, add(code, 32), mload(code)) }
        require(deployed != address(0), "build independent DODO reference first");
        referencePmm = IPMMHarness(deployed);
        capital = 100_000e18;
        band = 780;
        takerLimit = 50;
        rebalanceFee = 10;
        rebalanceFixed = 1e18;
        rebalanceInterval = 86400;
    }

    function _ceil(uint256 n, uint256 d) internal pure returns (uint256) {
        return n == 0 ? 0 : (n - 1) / d + 1;
    }

    function _value(Pool memory p, uint256 price) internal pure returns (uint256) {
        return p.B * price / W + p.Q;
    }

    function _band(Pool memory p, uint256 anchor) internal view {
        // Reciprocal bounds have geometric center = anchor. A 50/50 allocation
        // therefore starts at the same spot as XYC/PMM, unlike arithmetic +/- bands.
        p.sqrtMin = Math.sqrt(anchor * D / (D + band) * W);
        p.sqrtMax = Math.sqrt(anchor * (D + band) / D * W);
    }

    function _initial(uint256 kind, uint256 fee, uint256 k, uint256 price)
        internal view returns (Pool memory p)
    {
        p.B = capital / 2 * W / price;
        p.Q = capital - p.B * price / W;
        p.B0 = p.B; p.Q0 = p.Q; p.i = price; p.K = k;
        p.kind = kind; p.feeBps = fee;
        _band(p, price);
    }

    function _normalize(Pool memory p) internal view {
        if (p.R == 0) {
            // The net fill reached equilibrium. Reinvested input fees are added
            // to equilibrium capital; do not leave ONE with mismatched targets.
            p.B0 = p.B; p.Q0 = p.Q;
        } else {
            (p.B0, p.Q0) = referencePmm.adjustTarget(p.i, p.K, p.B, p.Q, p.B0, p.Q0, uint8(p.R));
        }
        _valid(p);
    }

    function _valid(Pool memory p) internal pure {
        require(p.B > 0 && p.Q > 0 && p.B0 > 0 && p.Q0 > 0, "PMM empty reserve/target");
        if (p.R == 0) require(p.B == p.B0 && p.Q == p.Q0, "PMM invalid equilibrium");
        else if (p.R == 1) require(p.B0 >= p.B && p.Q >= p.Q0, "PMM invalid ABOVE_ONE");
        else require(p.R == 2 && p.B >= p.B0 && p.Q0 >= p.Q, "PMM invalid BELOW_ONE");
    }

    function clmmQuote(Pool calldata p, bool baseIn, uint256 net, bytes calldata args)
        external pure returns (uint256 used, uint256 out)
    {
        Context memory ctx;
        ctx.query.isExactIn = true;
        ctx.query.tokenIn = baseIn ? BASE : QUOTE;
        ctx.query.tokenOut = baseIn ? QUOTE : BASE;
        ctx.swap.balanceIn = baseIn ? p.B : p.Q;
        ctx.swap.balanceOut = baseIn ? p.Q : p.B;
        ctx.swap.amountIn = net;
        XYCConcentrateSwap.exec(ctx, args);
        return (ctx.swap.amountIn, ctx.swap.amountOut);
    }

    function _quote(Pool memory p, bool baseIn, uint256 gross) internal view returns (Fill memory f) {
        if (gross == 0 || (baseIn ? p.Q : p.B) == 0) return f;
        f.gross = gross;
        f.fee = _ceil(gross * p.feeBps, D);
        f.net = gross - f.fee;
        if (f.net == 0) return Fill(0, 0, 0, 0, p.R);
        if (p.kind == 2) {
            uint8 r;
            if (baseIn) (f.out, r) = referencePmm.sellBase(p.i, p.K, p.B, p.Q, p.B0, p.Q0, uint8(p.R), f.net);
            else (f.out, r) = referencePmm.sellQuote(p.i, p.K, p.B, p.Q, p.B0, p.Q0, uint8(p.R), f.net);
            f.R = r;
        } else if (p.kind == 0) {
            Context memory ctx;
            ctx.query.isExactIn = true;
            ctx.swap.balanceIn = baseIn ? p.B : p.Q;
            ctx.swap.balanceOut = baseIn ? p.Q : p.B;
            ctx.swap.amountIn = f.net;
            XYCSwap.exec(ctx, msg.data[0:0]);
            f.out = ctx.swap.amountOut;
        } else {
            uint256 used;
            (used, f.out) = this.clmmQuote(p, baseIn, f.net, abi.encodePacked(p.sqrtMin, p.sqrtMax));
            if (used < f.net) {
                // Same partial-input gross-up as upstream FeeFlatIn.exec.
                f.net = used;
                f.fee = _ceil(used * p.feeBps, D - p.feeBps);
                f.gross = used + f.fee;
            }
        }
        require(f.gross <= gross && f.net + f.fee == f.gross, "invalid input accounting");
        require(f.out <= (baseIn ? p.Q : p.B), "output exceeds reserve");
    }

    function _apply(Pool memory p, bool baseIn, Fill memory f) internal view {
        if (baseIn) { p.B += f.gross; p.Q -= f.out; }
        else { p.Q += f.gross; p.B -= f.out; }
        if (p.kind == 2) { p.R = f.R; _normalize(p); }
    }

    function _marks(Fill memory f, bool baseIn, uint256 price)
        internal pure returns (uint256 input, uint256 output, uint256 fee)
    {
        input = baseIn ? f.gross * price / W : f.gross;
        output = baseIn ? f.out : f.out * price / W;
        fee = baseIn ? f.fee * price / W : f.fee;
    }

    function _mid(Pool memory p) internal view returns (uint256) {
        if (p.kind == 2) return referencePmm.midPrice(p.i, p.K, p.B, p.Q, p.B0, p.Q0, uint8(p.R));
        if (p.kind == 0) return p.Q * W / p.B;
        (, uint256 root) = XYCConcentrateSwap.computeLiquidityAndPrice(p.B, p.Q, p.sqrtMin, p.sqrtMax);
        return root * root / W;
    }

    function _profit(Pool memory p, bool baseIn, uint256 amount, uint256 price) internal view returns (int256) {
        Fill memory f = _quote(p, baseIn, amount);
        (uint256 input, uint256 output,) = _marks(f, baseIn, price);
        return int256(output) - int256(input);
    }

    function _arbitrage(Pool memory p, Stats memory s, uint256 price) internal view {
        uint256 mid = _mid(p);
        bool baseIn;
        if (mid * (D - p.feeBps) > price * D) baseIn = true;
        else if (mid * D >= price * (D - p.feeBps)) return;
        // Search all possibly profitable input, independent of the pool's input
        // reserve. That reserve may be zero on a CLMM reversal.
        uint256 hi = baseIn ? p.Q * W / price : p.B * price / W;
        uint256 lo;
        for (uint256 j = 0; j < SEARCH_STEPS; j++) {
            uint256 a = lo + (hi - lo) / 3;
            uint256 b = hi - (hi - lo) / 3;
            if (_profit(p, baseIn, a, price) < _profit(p, baseIn, b, price)) lo = a;
            else hi = b;
        }
        Fill memory f = _quote(p, baseIn, (hi + lo) / 2);
        (uint256 input, uint256 output, uint256 fee) = _marks(f, baseIn, price);
        if (output <= input + 1e10 || f.out == 0) return; // < 0.00000001 USDT: rounding noise
        _apply(p, baseIn, f);
        s.arbTrades++; s.arbVolume += input; s.fees += fee;
        s.tradePnl += int256(input) - int256(output);
        s.arbLoss += int256(output) - int256(input);
    }

    function _rebalance(Pool memory p, Stats memory s, uint256 market, uint256 anchor) internal view {
        uint256 before = _value(p, market);
        require(before > rebalanceFixed * 2, "insufficient capital for rebalance");
        // Pay the explicit fixed quote cost, selling base if the position is one-sided.
        if (p.Q < rebalanceFixed) {
            uint256 sell = _ceil((rebalanceFixed - p.Q) * W * D, market * (D - rebalanceFee));
            require(sell < p.B, "cannot fund rebalance");
            p.B -= sell;
            p.Q += sell * market / W * (D - rebalanceFee) / D;
        }
        p.Q -= rebalanceFixed;
        uint256 baseAtAnchor = p.B * anchor / W;
        if (baseAtAnchor > p.Q) {
            uint256 sell = (baseAtAnchor - p.Q) * W / (anchor + market * (D - rebalanceFee) / D);
            p.B -= sell;
            p.Q += sell * market / W * (D - rebalanceFee) / D;
        } else {
            uint256 spend = (p.Q - baseAtAnchor) * market / (market + anchor * (D - rebalanceFee) / D);
            p.Q -= spend;
            p.B += spend * (D - rebalanceFee) / D * W / market;
        }
        s.rebalanceCost += before - _value(p, market);
        s.rebalances++; s.updates++;
        _band(p, anchor);
    }

    function _mark(Pool memory p, Stats memory s, uint256 price) internal pure {
        uint256 equity = _value(p, price);
        if (equity > s.peak) s.peak = equity;
        uint256 dd = (s.peak - equity) * D / s.peak;
        if (dd > s.maxDrawdownBps) s.maxDrawdownBps = dd;
    }

    /// Each event gets its own EVM memory frame: repeated reference calls do not
    /// accumulate gigabytes of temporary memory over a multi-day replay.
    function step(Pool memory p, Stats memory s, Event memory e) external view returns (Pool memory, Stats memory) {
        require(e.time > s.lastTime && e.price > 0 && e.quantity > 0, "invalid event order/value");
        require(e.anchorTime <= e.time - lag * 1_000_000 && e.anchorPrice > 0, "look-ahead anchor");
        if (s.lastPrice != 0) s.holdingPnl += int256(p.B) * (int256(e.price) - int256(s.lastPrice)) / int256(W);
        _mark(p, s, e.price);
        if (p.kind == 2) {
            p.i = e.anchorPrice; _normalize(p); s.updates++;
        } else if (p.kind == 3 && s.lastTime != 0 &&
                   e.time / (rebalanceInterval * 1_000_000) != s.lastTime / (rebalanceInterval * 1_000_000)) {
            _rebalance(p, s, e.price, e.anchorPrice);
        }
        uint256 age = e.time - e.anchorTime;
        if (age > s.maxAnchorAgeUs) s.maxAnchorAgeUs = age;
        _arbitrage(p, s, e.price);
        uint256 gross = e.baseIn ? e.quantity : e.quantity * e.price / W;
        s.requests++;
        s.offered += e.quantity * e.price / W;
        Fill memory f = _quote(p, e.baseIn, gross);
        (uint256 input, uint256 output, uint256 fee) = _marks(f, e.baseIn, e.price);
        if (f.out == 0 || output * D < input * (D - takerLimit)) {
            s.rejected++;
        } else {
            _apply(p, e.baseIn, f);
            s.fills++; s.volume += input; s.fees += fee;
            if (f.gross < gross) s.partials++;
            int256 cost = int256(input) - int256(output);
            s.customerCost += cost; s.tradePnl += cost;
        }
        _arbitrage(p, s, e.price);
        _mark(p, s, e.price);
        s.lastPrice = e.price; s.lastTime = e.time;
        int256 accounted = int256(capital) + s.holdingPnl + s.tradePnl - int256(s.rebalanceCost);
        int256 delta = int256(_value(p, e.price)) - accounted;
        require(delta <= int256(s.requests * 10) && delta >= -int256(s.requests * 10), "equity does not reconcile");
        return (p, s);
    }

    function _word(bytes memory raw, uint256 at) internal pure returns (uint256 v) {
        assembly { v := mload(add(add(raw, 32), at)) }
    }

    function _event(bytes memory raw, uint256 at) internal view returns (Event memory e) {
        e.time = _word(raw, at); e.baseIn = _word(raw, at + 64) == 1;
        e.quantity = _word(raw, at + 96); e.price = _word(raw, at + 128);
        if (lag == 0) { e.anchorTime = e.time; e.anchorPrice = e.price; }
        else {
            uint256 slot = lag == 1 ? 0 : lag == 5 ? 1 : 2;
            e.anchorTime = _word(raw, at + 160 + slot * 64);
            e.anchorPrice = _word(raw, at + 192 + slot * 64);
        }
    }

    function processDay(Pool memory p, Stats memory s, string calldata day) external returns (Pool memory, Stats memory) {
        bytes memory raw = vm.readFileBinary(string.concat("data/", day, ".bin"));
        require(raw.length > 0 && raw.length % RECORD_BYTES == 0, "invalid fixture length");
        for (uint256 at = 0; at < raw.length; at += RECORD_BYTES) {
            (p, s) = this.step(p, s, _event(raw, at));
        }
        return (p, s);
    }

    function _report(Pool memory p, Stats memory s, string memory day) internal {
        string memory key = "replay";
        vm.serializeString(key, "through_date", day);
        vm.serializeUint(key, "final_equity_wad", _value(p, s.lastPrice));
        vm.serializeUint(key, "final_base_wad", p.B);
        vm.serializeUint(key, "final_quote_wad", p.Q);
        vm.serializeUint(key, "last_price_wad", s.lastPrice);
        vm.serializeUint(key, "requests", s.requests);
        vm.serializeUint(key, "fills", s.fills);
        vm.serializeUint(key, "rejected", s.rejected);
        vm.serializeUint(key, "partials", s.partials);
        vm.serializeUint(key, "volume_wad", s.volume);
        vm.serializeUint(key, "offered_wad", s.offered);
        vm.serializeUint(key, "arb_trades", s.arbTrades);
        vm.serializeUint(key, "arb_volume_wad", s.arbVolume);
        vm.serializeUint(key, "fees_wad", s.fees);
        vm.serializeUint(key, "rebalance_cost_wad", s.rebalanceCost);
        vm.serializeUint(key, "rebalances", s.rebalances);
        vm.serializeUint(key, "updates", s.updates);
        vm.serializeUint(key, "max_drawdown_bps", s.maxDrawdownBps);
        vm.serializeUint(key, "max_anchor_age_us", s.maxAnchorAgeUs);
        vm.serializeInt(key, "holding_pnl_wad", s.holdingPnl);
        vm.serializeInt(key, "trade_pnl_wad", s.tradePnl);
        vm.serializeInt(key, "customer_cost_wad", s.customerCost);
        string memory output = vm.serializeInt(key, "arb_loss_wad", s.arbLoss);
        console2.log(string.concat("REPLAY_RESULT ", output));
    }

    function test_RunReplay() public {
        vm.skip(!vm.envOr("RUN_MARKET_REPLAY", false), "run with make curves-replay");
        string memory config = vm.readFile("replay.json");
        capital = vm.parseJsonUint(config, ".initial_capital_quote") * W;
        takerLimit = vm.parseJsonUint(config, ".taker_limit_bps");
        rebalanceFee = vm.parseJsonUint(config, ".rebalance_fee_bps");
        rebalanceFixed = vm.parseJsonUint(config, ".rebalance_fixed_quote") * W;
        rebalanceInterval = vm.parseJsonUint(config, ".rebalance_interval_seconds");
        lag = vm.envUint("REPLAY_LAG");
        band = vm.envUint("REPLAY_BAND");
        require(lag == 0 || lag == 1 || lag == 5 || lag == 30, "unsupported lag");
        string[] memory dates = vm.envString("REPLAY_DATES", ",");
        bytes memory first = vm.readFileBinary(string.concat("data/", dates[0], ".bin"));
        uint256 price = _word(first, 128);
        Pool memory p = _initial(vm.envUint("REPLAY_KIND"), vm.envUint("REPLAY_FEE"),
                                vm.envUint("REPLAY_K_PERCENT") * W / 100, price);
        Stats memory s;
        s.peak = capital;
        for (uint256 j = 0; j < dates.length; j++) {
            (p, s) = this.processDay(p, s, dates[j]);
            _report(p, s, dates[j]);
        }
        assertEq(s.fills + s.rejected, s.requests);
        assertGt(s.requests, 0);
    }

    function test_FeeReinvestmentCanonicalAtEquilibriumCrossing() public view {
        Pool memory p = _initial(2, 30, W / 10, 2500e18);
        Fill memory buy = _quote(p, false, 5000e18);
        _apply(p, false, buy);
        assertEq(p.R, 1);
        uint256 required = p.B0 - p.B;
        // Choose gross input whose net amount reaches exactly the base target.
        uint256 gross = required + _ceil(required * p.feeBps, D - p.feeBps);
        Fill memory sell = _quote(p, true, gross);
        _apply(p, true, sell);
        _valid(p);
        assertGt(p.B * 2500e18 / W + p.Q, 0);
    }

    function test_PartialFillFeeAndBalancesReconcile() public view {
        Pool memory p = _initial(1, 30, 0, 2500e18);
        uint256 beforeB = p.B; uint256 beforeQ = p.Q;
        Fill memory f = _quote(p, true, 1000e18);
        assertLt(f.gross, 1000e18);
        assertEq(f.fee, _ceil(f.net * 30, D - 30));
        assertEq(f.out, beforeQ);
        _apply(p, true, f);
        assertEq(p.B, beforeB + f.gross);
        assertEq(p.Q, 0);
        Fill memory reverse = _quote(p, false, 100e18);
        assertGt(reverse.out, 0, "missing quote reserve must accept quote input");
    }

    function test_RejectsLookAheadAnchor() public {
        lag = 5;
        Pool memory p = _initial(2, 30, W / 10, 2500e18);
        Stats memory s; s.peak = capital;
        Event memory e = Event(100_000_000, 1e17, 2500e18, true, 96_000_000, 2500e18);
        vm.expectRevert("look-ahead anchor");
        this.step(p, s, e);
    }

    function test_CustomerLimitRejectsWithoutCustomerBalanceChange() public {
        Pool memory p = _initial(0, 30, 0, 2500e18);
        Stats memory s; s.peak = capital;
        Event memory e = Event(100_000_000, 100e18, 2500e18, true, 100_000_000, 2500e18);
        (Pool memory afterPool, Stats memory afterStats) = this.step(p, s, e);
        assertEq(afterStats.rejected, 1);
        assertEq(afterStats.fills, 0);
        assertEq(afterPool.B, p.B);
        assertEq(afterPool.Q, p.Q);
    }

    function test_FreshAnchorPreservesInventoryAndQuoteIsReadOnly() public view {
        Pool memory p = _initial(2, 30, W / 10, 2500e18);
        _apply(p, true, _quote(p, true, 1e18));
        uint256 b = p.B; uint256 q = p.Q;
        p.i = 2510e18; _normalize(p);
        assertEq(p.B, b); assertEq(p.Q, q);
        assertTrue(p.R != 0, "anchor update must not erase inventory imbalance");
        bytes32 before = keccak256(abi.encode(p));
        Fill memory a = _quote(p, false, 100e18);
        Fill memory c = _quote(p, false, 100e18);
        assertEq(a.out, c.out);
        assertEq(keccak256(abi.encode(p)), before);
    }

    function test_RebalanceChargesCostsAndMovesBothDirections() public view {
        Pool memory p = _initial(3, 30, 0, 2500e18);
        Stats memory s;
        p.B = 0; p.Q = capital;
        _rebalance(p, s, 2500e18, 2500e18);
        assertGt(p.B, 0);
        assertApproxEqAbs(p.B * 2500e18 / W, p.Q, 10000);
        assertEq(_value(p, 2500e18) + s.rebalanceCost, capital);
        p.B += p.Q * W / 2500e18; p.Q = 0;
        uint256 before = _value(p, 2500e18);
        uint256 costs = s.rebalanceCost;
        _rebalance(p, s, 2500e18, 2500e18);
        assertGt(p.Q, 0);
        assertEq(_value(p, 2500e18) + s.rebalanceCost - costs, before);
    }
}

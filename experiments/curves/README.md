# Curve experiments

These are economic counterfactuals using the real Solidity pricing libraries.
They are not Bastion contracts, Aqua settlement, or PMM-port conformance evidence.

## Run

```sh
make curves-data       # download the pinned archive files and verify SHA-256
make curves-check      # offline data and accounting/boundary tests
make curves-replay     # training selection, held-out evaluation, numeric report
make curves            # original daily-close experiment with corrected CLMM handling
```

The implementation uses the existing Foundry installation, the independently
compiled Solidity 0.6.9 DODO harness, SwapVM's Solidity 0.8.30 libraries, and the
Python standard library. No new package dependency or public deployment is needed.
The very large Foundry gas limit pays for entire historical simulations; its gas
numbers are not gas estimates for one production swap.

Results: [market replay](evidence/market-replay/REPORT.md), with selected training
and evaluation runs in [results.json](evidence/market-replay/results.json).
All curve evidence lives beside the experiment under `evidence/`. Individual
Forge logs and JSON caches in `evidence/market-replay/cases/` are generated locally
and ignored by Git; `make curves-replay` regenerates them when absent.
The original saved output remains in `evidence/curve-comparison.txt`; its CLMM
numbers were produced by the old harness. Re-run output is recorded separately in
`evidence/curve-comparison-corrected.txt`.
The legacy logs say USD, but their price source is ETH/USDT; read that quote unit
as USDT. The new replay labels the pair and quote asset explicitly.

## Frozen experiment

`replay.json` was written before running P&L. Dates are September 1–7, 2026:
September 1–2 select parameters; September 3–7 evaluate them. Every family starts
each phase with 100,000 USDT, split equally by value between ETH and USDT.
State then persists across all days of that phase. Evaluation starts from the
same capital for every family, not from its different training balance.

Data comes from Binance's [public spot aggregate-trade archives](https://github.com/binance/binance-public-data).
Each downloaded ZIP is verified against its published `.CHECKSUM`; source URLs,
archive hashes, fixture hashes, counts and timestamps are in `data/manifest.json`.
The ZIPs are cached under ignored `data/raw/`. The compact `.bin` fixtures and
manifest suffice to re-run the economic tests offline.

One real aggregate trade per UTC minute supplies an offered direction and size.
It is the first eligible trade in that minute, with at least 30 seconds of price
history available at the start of the dataset. Quantities are never resized.
This is **sampled hypothetical routing**, not a claim that this flow would come to
Bastion. The archive's `isBuyerMaker=true` means the aggressive trader sold base,
so the simulated maker receives ETH and pays USDT.

All 4,661,458 underlying records are read when building the 10,080 requests. For
execution timestamp `t` and assumed pipeline delay `L`, use the latest observed
trade at or before `t-L`. Unsampled observations still update that history.
Decimal strings become exact integers; no binary float enters the fixtures.
The ideal `L=0` control uses the contemporaneous execution print. Positive-delay
rows use only earlier records. A 1-second pipeline delay is **not** a promise of
exactly 1-second-old prices: intervals between source trades add more age.

Fixture schema is 11 big-endian uint256 words per event:

```text
timestamp_us, aggregate_trade_id, base_in, quantity_wad, market_price_wad,
anchor_1s_timestamp_us, anchor_1s_price_wad,
anchor_5s_timestamp_us, anchor_5s_price_wad,
anchor_30s_timestamp_us, anchor_30s_price_wad
```

## Curve and fill rules

| Family | Pricing implementation | Chosen on training only |
|---|---|---|
| XYC | upstream `XYCSwap.exec` | no curve parameter |
| Static CLMM | upstream `XYCConcentrateSwap.exec` | reciprocal halfwidth 200 or 780 bps |
| Daily CLMM | same instruction, daily external rebalance | reciprocal halfwidth 200 or 780 bps |
| PMM | independently compiled DODO `PMMPricing` | `K` = 0.01, 0.1, 0.5 or 1 |

Every family is evaluated separately at the same 5-bps and 30-bps input fees.
Within each common fee and delay, select the curve parameter with the greatest
training terminal equity. Report both CLMM policies; compare PMM against the
stronger evaluation control as well as XYC. There is no re-selection of `K` on
evaluation results. Thirty bps is the predeclared primary fee; it is not claimed
to be an optimized fee.

CLMM lower and upper prices are `anchor/(1+width)` and `anchor*(1+width)`. These
have geometric center `anchor`, so equal-value starting inventory has the same
initial spot across families. This is a benchmark band policy, not a reproduction
of Gamma's managed vault. Daily CLMM rebalances at the first sampled event after a
UTC-day boundary, aiming for equal value at its available anchor. External trades
execute at the contemporaneous reference print with an assumed 10-bps cost plus
1 USDT per rebalance; neither cost is presented as measured chain gas. The same
delayed observation is available to the PMM and daily CLMM in each scenario.

For each event, `MarketReplayTest.step` does:

```text
mark existing inventory at the new reference price
  -> update PMM anchor / perform scheduled CLMM rebalance
  -> search for profitable arbitrage
  -> quote the recorded customer request including the common input fee
  -> accept only if reference-value shortfall is <= 50 bps of consumed input
  -> update actual simulated reserves with gross input and actual output
  -> search for post-customer arbitrage
  -> reconcile equity and record risk / service metrics
```

Arbitrage is sized to maximize immediate profit, with zero external hedge cost.
Its maximum input is bounded by the market value of all available output, **not**
by the pool's input-token balance. That balance can be zero on a CLMM reversal.
Partial CLMM fills credit only input actually consumed by the upstream instruction;
fees gross up that consumed amount using upstream `FeeFlatIn` rounding. Unused
request input is not received, charged a fee, or counted as executed volume.
This benchmark exercises partial fills; it does not enable them in Bastion's
specified execution grammar, where they remain excluded.

PMM uses DODO reference output and returned `R`, credits gross input, then applies
reference `adjustedTarget` to reinvest fees into a canonical next state. If the
net trade reaches `R=ONE`, both targets become the post-fee reserves. A new anchor
never overwrites the reserves or erases an existing imbalance. This is the
explicit simulator reinvestment policy, not a passing Bastion conformance gate.

## Read the number correctly

```text
equity = ETH inventory * final ETH/USDT reference price + USDT inventory
edge_bps = 10,000 * (PMM equity - control equity) / initial capital

equity = initial capital + holding P&L + trade P&L - rebalancing costs
```

Holding P&L marks the ETH position held between sampled events. Trade P&L marks
actual gross input and output at each event's reference price. It already includes
fees; the separate fee column is attribution, not another additive revenue line.
Every event checks reconciliation within a small, cumulative integer-rounding
tolerance. Customer and arbitrage volumes are separate.

Report customer fills and rejections, partial fills, filled input notional,
volume-weighted customer cost, trade P&L, fees, arbitrage extraction, holding P&L,
final inventory, sampled drawdown, oracle-update counts and rebalance costs.
Additional oracle-cost scenarios are explicitly hypothetical. Break-even cost
headroom is the equity advantage divided by the difference in update counts.
If that advantage is negative, there is no positive cost budget.

Limitations:

- Single-venue trade prints are reference prices, not executable bid/ask quotes;
  external depth, hedge slippage and bid/ask costs are omitted.
- Arbitrage is only checked around the sampled requests. Opportunities between
  those requests are omitted, which can understate adverse selection.
- The 50-bps customer limit is assumed willingness to pay, not observed intent.
- One five-day holdout does not establish statistical significance or performance
  through other regimes. A higher equity result can come with different inventory
  exposure, lower service, or worse execution prices.
- This compares complete quoting/recentring strategies. It does not isolate pure
  curve geometry or test every possible CLMM management policy.
- Both model tokens have 18 decimals. No actual ETH/USDT transfers, WETH/USDC
  scaling, signed-anchor authentication, live keeper, Aqua settlement, shared-book
  coordination, budgets, or production transaction costs are validated here.

## Verification

`curves-check` verifies chronological/causal fixture selection, exact decimal
conversion, archive-derived fixture hashes, dates and counts. Solidity tests cover
CLMM recovery with zero input reserve, partial-input fee accounting, customer
rejection, future-price rejection, fee reinvestment at PMM equilibrium crossing,
read-only quotes, anchor updates preserving reserves, and external rebalancing
cost reconciliation. The legacy frozen-anchor `K=1` self-check now covers all four
old windows with a relative tolerance of `1e-8`, rather than one window at 1%.

`test_RunReplay` is deliberately marked skipped in the ordinary suite. The Python
runner invokes it explicitly for each training/evaluation case; each raw log
contains the actual `PASS` and the Solidity-generated per-day results. Cache keys
include fixtures, configuration, source hashes and compiled bytecode. A changed
model or fixture cannot reuse a result from the old inputs.

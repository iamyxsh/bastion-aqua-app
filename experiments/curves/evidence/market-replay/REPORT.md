# PMM market replay

Counterfactual experiment using actual Solidity curves; not live P&L or Aqua settlement.

Pinned market: **ETH/USDT**, 2026-09-01 through 2026-09-07. Train on the first 2 days; evaluate 2026-09-03 through 2026-09-07.

4,661,458 raw aggregate trades; 10,080 sampled requests; initial equity **100,000 USDT** per model and phase.

**Primary-fee example, 1-second assumed delay:** PMM ends at 112,863.70 USDT, versus 111,155.87 for CLMM daily, the strongest conventional control. The difference is **1,707.83 USDT / +170.78 bps of starting capital**, before additional deployment costs.

That difference comprises 853.11 USDT of trade-execution P&L, 682.93 of inventory holding P&L, and 171.80 of lower rebalancing costs. It is not all additional trading profit. All delays and both fees are reported below; a longer delay can sometimes increase terminal equity through different flow and inventory exposure.

## Held-out equity comparison

Each family selects its parameter on training equity only. PMM is compared against both CLMM policies; `best CLMM` means the larger evaluation equity of those two separately trained controls, a deliberately demanding comparison. Zero delay is an ideal control, not measured oracle performance. Values include reinvested swap fees and the stated CLMM rebalancing costs, but exclude deployment/transaction/oracle costs.

| Common fee (bps) | Delay (s) | Selected PMM K | PMM equity (USDT) | Extra vs XYC (USDT) | Extra vs best CLMM (USDT) | Edge vs strongest conventional (bps of initial capital) |
|---:|---:|---:|---:|---:|---:|---:|
| 5 | 0 | 0.01 | 107,644.43 | 5,332.07 | 1,440.17 | +144.02 |
| 5 | 1 | 0.01 | 107,624.36 | 5,312.01 | 1,420.10 | +142.01 |
| 5 | 5 | 0.01 | 107,571.46 | 5,259.11 | 1,367.20 | +136.72 |
| 5 | 30 | 0.01 | 106,779.35 | 4,466.99 | 575.08 | +57.51 |
| 30 | 0 | 0.01 | 112,834.24 | 10,383.26 | 1,678.09 | +167.81 |
| 30 | 1 | 0.01 | 112,863.70 | 10,412.72 | 1,707.83 | +170.78 |
| 30 | 5 | 0.01 | 113,065.97 | 10,614.99 | 1,956.31 | +195.63 |
| 30 | 30 | 0.01 | 113,165.37 | 10,714.39 | 2,081.00 | +208.10 |

## Price observation age

Pipeline delay is a scenario assumption. Actual age also includes gaps between source trades; the experiment uses last-trade prices, not a continuously published executable bid/ask quote.

| Assumed delay (s) | Maximum actual anchor age in evaluation (s) |
|---:|---:|
| 0 | 0.000000 |
| 1 | 9.576935 |
| 5 | 12.911048 |
| 30 | 38.340830 |

## Service and attribution

Filled volume is customer input notional at the recorded market price; arbitrage volume is separate. Customer cost is the reference-value shortfall as bps of filled input notional (negative is better for customers). Fees are already included in trade P&L: do not add them a second time. Equity reconciles to initial capital + inventory holding P&L + trade P&L − rebalancing costs at every event.

| Fee | Delay | Model / selected parameter | Equity USDT | Customer fills | Filled input / offered | Customer cost bps | Trade P&L USDT | Holding P&L USDT | Fees USDT | Arb loss USDT | Rebalance cost USDT | Max sampled drawdown bps |
|---:|---:|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| 5 | 0 | XYC  | 102,312.36 | 4301/7200 | 2.24% | 28.62 | 223.80 | 2,088.55 | 256.55 | 529.40 | 0.00 | 221 |
| 5 | 0 | CLMM fixed band=780 bps | 106,204.26 | 6876/7200 | 40.50% | 26.11 | 3,799.18 | 2,405.08 | 4,696.49 | 8,645.90 | 0.00 | 96 |
| 5 | 0 | CLMM daily band=200 bps | 105,545.58 | 6176/7200 | 55.43% | 19.05 | 4,178.88 | 1,532.79 | 6,582.38 | 8,242.03 | 166.08 | 271 |
| 5 | 0 | PMM K=0.01 | 107,644.43 | 7065/7200 | 56.06% | 17.39 | 5,586.80 | 2,057.63 | 5,594.39 | 5,887.98 | 0.00 | 203 |
| 5 | 1 | XYC  | 102,312.36 | 4301/7200 | 2.24% | 28.62 | 223.80 | 2,088.55 | 256.55 | 529.40 | 0.00 | 221 |
| 5 | 1 | CLMM fixed band=780 bps | 106,204.26 | 6876/7200 | 40.50% | 26.11 | 3,799.18 | 2,405.08 | 4,696.49 | 8,645.90 | 0.00 | 96 |
| 5 | 1 | CLMM daily band=200 bps | 105,545.38 | 6176/7200 | 55.43% | 19.05 | 4,178.96 | 1,532.50 | 6,582.34 | 8,242.80 | 166.08 | 271 |
| 5 | 1 | PMM K=0.01 | 107,624.36 | 7066/7200 | 56.19% | 17.47 | 5,597.91 | 2,026.45 | 5,641.90 | 5,955.03 | 0.00 | 204 |
| 5 | 5 | XYC  | 102,312.36 | 4301/7200 | 2.24% | 28.62 | 223.80 | 2,088.55 | 256.55 | 529.40 | 0.00 | 221 |
| 5 | 5 | CLMM fixed band=780 bps | 106,204.26 | 6876/7200 | 40.50% | 26.11 | 3,799.18 | 2,405.08 | 4,696.49 | 8,645.90 | 0.00 | 96 |
| 5 | 5 | CLMM daily band=200 bps | 105,525.59 | 6169/7200 | 55.39% | 19.06 | 4,176.96 | 1,514.81 | 6,575.80 | 8,247.33 | 166.18 | 272 |
| 5 | 5 | PMM K=0.01 | 107,571.46 | 7067/7200 | 56.32% | 17.51 | 5,591.47 | 1,980.00 | 5,749.93 | 6,011.14 | 0.00 | 205 |
| 5 | 30 | XYC  | 102,312.36 | 4301/7200 | 2.24% | 28.62 | 223.80 | 2,088.55 | 256.55 | 529.40 | 0.00 | 221 |
| 5 | 30 | CLMM fixed band=780 bps | 106,204.26 | 6876/7200 | 40.50% | 26.11 | 3,799.18 | 2,405.08 | 4,696.49 | 8,645.90 | 0.00 | 96 |
| 5 | 30 | CLMM daily band=200 bps | 105,476.59 | 6161/7200 | 55.08% | 18.93 | 4,143.98 | 1,499.13 | 6,538.98 | 8,123.46 | 166.52 | 273 |
| 5 | 30 | PMM K=0.01 | 106,779.35 | 7065/7200 | 55.97% | 17.18 | 4,902.16 | 1,877.19 | 6,316.09 | 6,414.23 | 0.00 | 229 |
| 30 | 0 | XYC  | 102,450.98 | 2620/7200 | 0.98% | 33.05 | 364.32 | 2,086.66 | 394.83 | 16.49 | 0.00 | 220 |
| 30 | 0 | CLMM fixed band=780 bps | 108,105.95 | 4871/7200 | 16.09% | 31.98 | 5,745.75 | 2,360.20 | 6,591.72 | 309.57 | 0.00 | 90 |
| 30 | 0 | CLMM daily band=200 bps | 111,156.15 | 4648/7200 | 29.65% | 30.61 | 9,962.02 | 1,365.93 | 12,205.03 | 715.59 | 171.80 | 255 |
| 30 | 0 | PMM K=0.01 | 112,834.24 | 5610/7200 | 29.93% | 30.80 | 10,771.77 | 2,062.47 | 10,782.05 | 72.71 | 0.00 | 184 |
| 30 | 1 | XYC  | 102,450.98 | 2620/7200 | 0.98% | 33.05 | 364.32 | 2,086.66 | 394.83 | 16.49 | 0.00 | 220 |
| 30 | 1 | CLMM fixed band=780 bps | 108,105.95 | 4871/7200 | 16.09% | 31.98 | 5,745.75 | 2,360.20 | 6,591.72 | 309.57 | 0.00 | 90 |
| 30 | 1 | CLMM daily band=200 bps | 111,155.87 | 4648/7200 | 29.65% | 30.61 | 9,962.09 | 1,365.57 | 12,204.91 | 715.57 | 171.80 | 255 |
| 30 | 1 | PMM K=0.01 | 112,863.70 | 5615/7200 | 29.95% | 30.95 | 10,815.20 | 2,048.49 | 10,845.08 | 93.37 | 0.00 | 182 |
| 30 | 5 | XYC  | 102,450.98 | 2620/7200 | 0.98% | 33.05 | 364.32 | 2,086.66 | 394.83 | 16.49 | 0.00 | 220 |
| 30 | 5 | CLMM fixed band=780 bps | 108,105.95 | 4871/7200 | 16.09% | 31.98 | 5,745.75 | 2,360.20 | 6,591.72 | 309.57 | 0.00 | 90 |
| 30 | 5 | CLMM daily band=200 bps | 111,109.66 | 4624/7200 | 29.55% | 30.64 | 9,937.34 | 1,344.23 | 12,172.26 | 714.96 | 171.91 | 256 |
| 30 | 5 | PMM K=0.01 | 113,065.97 | 5591/7200 | 30.35% | 30.91 | 10,958.29 | 2,107.68 | 11,009.64 | 80.73 | 0.00 | 184 |
| 30 | 30 | XYC  | 102,450.98 | 2620/7200 | 0.98% | 33.05 | 364.32 | 2,086.66 | 394.83 | 16.49 | 0.00 | 220 |
| 30 | 30 | CLMM fixed band=780 bps | 108,105.95 | 4871/7200 | 16.09% | 31.98 | 5,745.75 | 2,360.20 | 6,591.72 | 309.57 | 0.00 | 90 |
| 30 | 30 | CLMM daily band=200 bps | 111,084.37 | 4610/7200 | 29.53% | 30.63 | 9,928.60 | 1,328.06 | 12,159.51 | 714.24 | 172.29 | 257 |
| 30 | 30 | PMM K=0.01 | 113,165.37 | 5632/7200 | 31.12% | 31.21 | 11,275.16 | 1,890.20 | 11,587.53 | 153.09 | 0.00 | 205 |

## Additional cost budget

These are sensitivities, not measured gas. Charge the same assumed oracle cost per update to both models (PMM refreshes at every sampled request; daily CLMM refreshes on rebalance). Headroom is the extra edge divided by the difference in update counts; zero means PMM already fails to beat the control before extra costs. Transaction-count differences, external hedge costs and other operating expenses must also fit inside that budget.

| Fee | Delay | Strongest control | PMM updates | Control updates | Break-even USDT per additional update | Edge after 0.01 USDT/update | Edge after 0.10 USDT/update |
|---:|---:|---|---:|---:|---:|---:|---:|
| 5 | 0 | CLMM fixed | 7200 | 0 | 0.200023 | +1368.17 | +720.17 |
| 5 | 1 | CLMM fixed | 7200 | 0 | 0.197236 | +1348.10 | +700.10 |
| 5 | 5 | CLMM fixed | 7200 | 0 | 0.189889 | +1295.20 | +647.20 |
| 5 | 30 | CLMM fixed | 7200 | 0 | 0.079873 | +503.08 | -144.92 |
| 30 | 0 | CLMM daily | 7200 | 4 | 0.233197 | +1606.13 | +958.49 |
| 30 | 1 | CLMM daily | 7200 | 4 | 0.237330 | +1635.87 | +988.23 |
| 30 | 5 | CLMM daily | 7200 | 4 | 0.271861 | +1884.35 | +1236.71 |
| 30 | 30 | CLMM daily | 7200 | 4 | 0.289188 | +2009.04 | +1361.40 |

## Limits and interpretation

- One seven-day period and one five-day holdout; no statistical claim or guarantee across market regimes.
- One actual trade per minute is offered unchanged to each curve. This is hypothetical routing and willingness to pay, not observed Bastion order flow.
- All ticks inform lagged anchors, but arbitrage happens only before and after sampled requests; opportunities between samples are omitted. This can understate adverse selection.
- Reference and external hedge prices are trade prints, not executable bid/ask quotes; external depth, bid/ask costs and hedge slippage are omitted.
- The 50-bps input-value shortfall limit is an assumption. Rejected and partially filled demand is reported, not silently filled or discarded.
- A fixed reciprocal CLMM band and a daily external-rebalancing policy are benchmark strategies, not a reproduction of Gamma or all CLMM managers.
- This compares quoting and recentring strategies; it does not isolate pure curve geometry or test every possible CLMM management cadence.
- PMM fees are gross input retained in reserves; DODO adjustedTarget canonicalizes the next state. Exact equilibrium absorbs fees into equilibrium targets. This is the declared simulator reinvestment policy, not a verified Bastion implementation.
- Both model tokens have 18 decimals; actual WETH/USDC scaling, exact-out, signed-price authentication, Aqua settlement, shared books, budgets and deployed gas remain untested.
- More final equity alone can reflect different inventory exposure or less service. Read trade P&L, customer cost, fill volume and drawdown alongside the headline edge.

## Reproduce

```sh
make curves-data       # download / verify raw archives
make curves-check      # data + Solidity boundary checks
make curves-replay     # offline replay, training selection, evaluation, report
```

Input fingerprint: `570f490dcc30afeee310642ad302795cfdd539fbf3128e21bd5fd4d0736e5c1c`. Raw commands, per-day Solidity outputs and selected training configurations are retained in `experiments/curves/evidence/market-replay/`.

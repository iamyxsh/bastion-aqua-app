# Current progress

Updated 2026-09-09. Detailed execution record: [Milestones.MD](Milestones.MD), Entries 4–5.

- The approved market-data experiment is implemented and run. Seven Binance
  ETHUSDT days contain 4,661,458 raw records; 2 training days select parameters
  before 5 evaluation days. Same capital and fees for PMM, XYC and two CLMM policies.
- Primary result: at 30 bps and 1-second assumed delay, PMM finishes 1,707.83 USDT
  ahead of daily CLMM on 100,000 USDT starting capital. Only 853.11 of that edge is
  additional execution P&L; inventory exposure and rebalancing costs explain the rest.
  [Full results and limitations](experiments/curves/evidence/market-replay/REPORT.md).
- Verification: 6 Python data tests; 12 Solidity checks in `make curves`; 54 training,
  20 evaluation and 4 smoke replay cases passed. The ordinary suite intentionally
  skips the separately invoked replay. Offline fixture rebuild and diff checks passed.
- Corrected CLMM empty-reserve reversals, partial-fill accounting and arbitrage
  search bounds. Existing daily-close evidence is retained beside corrected results.
- Folder consolidation is implemented: all curve evidence now lives under
  `experiments/curves/evidence/`. The root `evidence/` directory is gone. Per-run
  replay caches and Python bytecode are ignored; source, fixtures and reports stay visible.
  Verified all 161 files on move; report regeneration changed only its location text
  and runner checksum metadata. Inputs, selected parameters and numeric results match.
  `make curves-check` passed 6 data and 9 Solidity tests (1 intentional replay skip);
  `make curves-replay` regenerated the report from existing cases. Owner review pending.
- Decision: evidence supports continuing the PMM feasibility work; it does not
  establish live profits or pass Bastion's port/shared-state/Aqua gates. Minute
  sampling, hypothetical routing, trade-print prices and unmeasured gas remain limits.
- Next proposed increment: M2 increment 1, one exact-in differential test against
  the independently compiled pinned DODO reference. Requires its own approval.
- Atomic signed-anchor delivery is under design review only. No anchor/router code
  changed. Current recommendation needs nonce reuse, candidate-anchor quote simulation,
  inventory-preserving recentring, input-first settlement and explicit-pause protection.
- Owner review and understanding are pending; no commits, pushes or deployments.

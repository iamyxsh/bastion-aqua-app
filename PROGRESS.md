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
- M2 increment 1 is implemented and verified (Entry 7). Our 0.8.30 port of DODO's PMM
  prices the R = ONE sell-quote direction and returns byte-identical results to DODO's
  own 0.6.9 code over 60,000 fuzz cases and 7 fixed cases — exact equality, not a
  tolerance. Gate P1 is PARTIAL: one direction, one entry state, 18/18 decimals.
  Worked example: 2,991 quote in against a 3,000 anchor with k = 0.1 and a 10-base
  target returns 0.986209759016173081 base on both sides, 1.09% slippage.
  The port is a pure library — no VM opcode, no Aqua settlement, no storage, no anchor.
- Two porting hazards found and handled: the reference's raw-multiply overflow probe
  must stay `unchecked` at 0.8.30 or it reverts where the reference falls through; and
  SafeMath's string reverts become panics, which is pinned by a test rather than hidden.
- The differential test was mutation-checked: a one-wei rounding-direction slip is
  caught. A sqrt-seed mutation was NOT caught, and the investigation corrected a
  planning claim — DODO's sqrt equals exact floor-sqrt except at x = 2, so "must use
  DODO's loop or rounding diverges" was overstated. The loop is kept for fidelity.
- M2 increment 2 is implemented and verified (Entry 8). The port is now complete as a
  pure library: both directions, all three entry states, fills that cross equilibrium
  inside one trade, adjustedTarget, getMidPrice, and 6/18-decimal anchor normalisation.
  400,000 fuzz cases against the 0.6.9 reference, 0 divergences. Gate P1 PASS over the
  declared domain. Five mutations of the new code were all caught by the tests.
- Gate P2's exact-in half FAILS as specified, and this is the increment's main result.
  DODO's PMM does NOT round toward the maker: three internal floors understate the
  quadratic's numerator, so the taker is handed slightly MORE than the exact answer. The
  error is amplified by 1/(1-k) — negligible for normal k, but at k = 1e18-3 on a dust
  book the curve returns 4.1x the correct output. Confirmed independently with exact
  rational arithmetic. Consequence carried to M3: maker-settable k must be constrained
  away from 1e18, and output caps, not rounding, are what bound giveaway.
- Also found: the reference reverts "DODOMath: should not be zero" on some ordinary
  trades (small target, near-zero k); the M3 router must surface that, not read it as a
  zero quote. And increment 1's declared domain was too wide for the sell-base leg,
  which solves on Q0 rather than B0; corrected.
- M2 increment 3 is implemented and verified (Entry 9), so milestone 2 is code-complete.
  PMMState turns the pure pricing function into a state machine: init opens at target,
  a fill prices on net input then credits gross, re-classifies R from the resulting
  balances, and applies the reference's own adjustedTarget rule as the fee-reinvestment
  step; recentring is explicit and a repeat at the same anchor does nothing.
  Gate P3 PASSES at library level, checked as a fixed point of DODO's own adjustedTarget
  rather than by inspection. All five mutations of the adapter's policy were caught.
- P4 preliminary: splitting a same-direction fill never pays the taker more. On one state,
  3,000 quote in at 30 bps, two halves return 16,609,441,371,369 base wei less than one
  fill. The cause is fee reinvestment, not rounding — suppressing the target re-solve
  collapses the gap to 18 wei. Library-level only; it is NOT evidence for the shared-state
  claim, which needs milestone 3.
- Two policy rules added, both the owner's to overturn: init rejects curvature in
  (0.999e18, 1e18) because of the 1/(1-k) amplification found in increment 2 (k = 1e18
  exactly is fine), and a fill that would empty a leg is refused because a zero leg cannot
  be priced or recentred afterwards.
- Also found, for M3's FeeFlatIn: charging a bps fee per slice floors it once per fill, so
  a taker who splits pays slightly less fee in total. Independent of the curve.
- M3 increment 1 is implemented and verified (Entry 10). The Bastion router now quotes the
  ported PMM from shared on-chain state through a real SwapVM program. Two equivalent books
  over one risk group quote identically from one state; a quote is proven write-free by a
  real staticcall; unadmitted programs, re-salted copies, wrong pairs and exact-out all
  revert. `make test` is 907 (882 upstream + 25 Bastion), 0 failing.
- Gate D1 was breached and fixed. With everything inlined the router was 26,842 bytes
  against EIP-170's 24,576 — undeployable. Moving the maker admin and then the PMM math into
  DEPLOYED, delegatecalled libraries brought it to 23,540 with 1,036 bytes of margin. State
  stays in the router because delegatecall preserves storage context. Deployment now needs
  two linked libraries.
- Three plan deviations, all forced and all reversible: an extra opcode (0x92
  PortfolioLedger) because upstream's FeeFlatIn hides the gross input from anything pricing
  inside it; PMMMath as a deployed library; and adjustedTarget returning instead of mutating,
  since memory does not survive a delegatecall. Milestone 2's 60 conformance tests still pass.
- NO TOKEN HAS MOVED YET. There is no Aqua settlement in this increment, so nothing here is
  evidence for the shared-state claim (gate P5) — only its shape. No maker lock, no trait
  validation, no budgets, no mandates, no access control.
- M3 increment 2 is implemented and verified (Entry 11), and it is the product claim: one
  real Aqua-settled fill on book A changes what book B quotes, by exactly what the milestone
  2 library predicts, while book B's own Aqua balances are unchanged and no transaction
  touched it. Book B's quote moved 331,198,832,121,712,192 -> 323,365,127,741,375,780 base
  out for the same 1,000 quote in. Gates P5, S1 and Q1 PASS for this grammar.
- It runs on a local anvil chain too: 12 real transactions, swap status 0x1 in block 38, and
  the deployed router codesize read back from chain at 23,540 bytes against EIP-170's 24,576.
  The 6/18-decimal anchor normalises to 3e9, not 3e18 — Scale.sol earning its place on a
  real pair. `make test` is 913 (882 upstream + 31 Bastion), 0 failing.
- Cross-check: splitting a fill across the two sibling books costs the taker
  16,609,441,371,369 base wei — byte-identical to the library-level split gap measured in
  milestone 2. The wired system reproduces the library model exactly.
- STILL MISSING, and it is the biggest hole: no maker lock, no settlement-trait validation,
  no output budgets. A taker can use trait combinations the spec excludes and nothing caps
  maker-wide output across sibling books. Do not describe the desk as safe yet.
- Next: milestone 3 increment 3 — preflight hooks, trait validation, the per-maker lock and
  rollback. It is the SECOND upstream file modification (two empty virtual hooks in
  SwapVM.sol, ladder decision D3b) and requires its own explicit approval.
- Atomic signed-anchor delivery is under design review only. No anchor/router code
  changed. Current recommendation needs nonce reuse, candidate-anchor quote simulation,
  inventory-preserving recentring, input-first settlement and explicit-pause protection.
- Owner review and understanding are pending; no commits, pushes or deployments.
- 2026-09-09 planning pass: a step-by-step increment ladder (M2/i1 through M8/i3)
  and open owner decisions D1–D6 are recorded in [Milestones.MD](Milestones.MD),
  section "Increment ladder", with findings in Entry 6. Planning only; no code changed.

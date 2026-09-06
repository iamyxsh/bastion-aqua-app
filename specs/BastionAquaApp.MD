# Bastion — an Aqua trading desk with segmented books over one inventory

**Status:** living specification, v0.1 (2026-09-06). This is an implementation specification, not a description of a deployed product. It will be revised as the build proceeds; see the change log at the end.

**Headline:** Segmented flow. Unified inventory.

Bastion lets a maker publish public, resolver-specific and timed Aqua books on different commercial terms while all of them quote from one pricing state and obey one set of aggregate outflow limits. A fill through one book changes the inventory used to quote the others. A public Coverage Lens shows advertised balances, available backing and the constraints on a proposed fill.

> Aqua enables inventory reuse. Bastion coordinates pricing and bounds authorized outflow across that reuse.

---

## 1. Problem

- [Aqua](https://github.com/1inch/aqua) records virtual balances keyed by `(maker, app, strategyHash, token)`. `ship()` writes those records and moves no tokens; tokens leave the maker's wallet only when a swap settles through `pull()`.
- One wallet can therefore back many strategies at once. That is the feature: capital is not fragmented across pools.
- Each SwapVM program prices from its own strategy balances. [`SwapVM`](https://github.com/1inch/swap-vm/blob/main/src/SwapVM.sol) loads `AQUA.safeBalances(maker, router, orderHash, tokenIn, tokenOut)` per order before running the program. A fill through one book does not change the quotes of a sibling book backed by the same wallet, and nothing bounds the maker's aggregate outflow across books.
- Bastion is a maker-side coordination and risk layer on top of unmodified Aqua: one pricing state per risk group, one outflow policy per maker, and per-book terms. It changes nothing in Aqua's accounting and makes no claim that Aqua's design is defective.

## 2. Product

**Customer.** A professional maker, or a treasury's appointed trading operator, who maintains a price and wants to offer different terms to public takers and selected counterparties over one inventory.

**Minimum useful product.** Create a desk, configure its price source and limits, publish three books, execute real trades, inspect backing and stop or replace any book independently.

### 2.1 Segmented books on WETH/USDC

Fee values are demonstration fixtures, not calibrated recommendations. Directions are named from the maker's perspective.

| Book | Access | Fixed input fee | Maker instruction | Lifecycle |
|---|---|---|---|---|
| A: public market | Any taker | 30 bps | Buy or sell WETH within per-token authorizations | Open until its quota is exhausted or the maker stops it |
| B: resolver agreement | Explicitly authorized execution addresses | 5 bps | Buy or sell WETH within separately assigned limits | Independently replaceable or revocable |
| C: timed WETH sale | Any taker | 30 bps | Sell at most a specified amount of WETH | Active only inside its configured time window |

- Every book reads the same pre-fee PMM state. Executable quotes differ only by the selected book's fee and eligibility.
- A fill in A changes B's and C's next quotes. Revoking B leaves A available. Expiring C stops that sale mandate; it does not prohibit selling through other eligible books.
- Books are execution authorizations with pricing terms. They do not schedule TWAP slices or guarantee that a sale completes.
- Each book has its own Aqua identity, discovery entry, quota and close/replace lifecycle. A maker can renegotiate a resolver's fee or end a sale window without touching the public book, while every fill updates the common inventory. A single program could encode equivalent branches; the contribution is that independently managed Aqua positions share coherent pricing and limits.

### 2.2 Coverage Lens

A read-only tool, usable for any maker on the configured Aqua deployment, that reports advertised virtual balances, actual backing (`min(balance, allowance)`), the advertised/backing ratio per token, and, for a Bastion book and a given caller, the binding constraint on a proposed fill. Details in §10.1.

## 3. Scope of the first release

- One chain and one canonical two-token pair per risk group; WETH/USDC is the demonstration pair.
- One maker token belongs to at most one active Bastion risk group.
- The maker may have other wallet activity; Bastion cannot govern trades through other apps or direct transfers.
- A fixed deployment allowlist admits conventional ERC-20 tokens with tested decimals. Fee-on-transfer and rebasing tokens are excluded.
- Pricing uses an explicit ledger. Tokens stay in the maker's wallet and move through Aqua only on settlement.
- Every caller must satisfy the selected book's admission rules and pays its fixed fee. There are no auction or order-in-block discounts. A book may additionally charge the priority toll of §6.4; it is a surcharge on the caller's own tip, never a discount.

## 4. Architecture

Bastion uses official Aqua contracts and a documented, bounded fork of SwapVM: upstream settlement is preserved and the required instructions are appended. Pin upstream commits, opcode encoding and compiler settings before implementation. At the time of writing the pins are `1inch/swap-vm@9502fd4` and `1inch/aqua@9c5c42e`.

### 4.1 Executable grammar

```text
AccessGate(bookTerms.access)                    // optional compiled upstream access guard
MakerPriceAnchor(riskGroupId)                   // validate shared anchor and policy
MakerBudget(riskGroupId) {                      // load ledger; final aggregate checks
  BookMandate(mandateId) {                      // direction, window, per-token amounts and quotas
    FeeFlatIn(bookTerms.feeUnits) {             // fixed fee for this admitted book (upstream)
      FeePriorityIn(riskGroupId, bookTerms.toll) {   // optional; omitted when the book's factor is zero
        PortfolioSwap(riskGroupId)              // canonical finite-trade PMM adapter
      }
    }
  }
}
Salt(bookIdentity)
```

| Instruction | Kind | Purpose |
|---|---|---|
| `MakerPriceAnchor` | leaf, custom | Validates the accepted on-chain anchor and policy for the risk group |
| `MakerBudget` | wrapper, custom | Loads the shared ledger; enforces per-block, per-token gross output caps on final amounts |
| `BookMandate` | wrapper, custom | Enforces direction, window, per-fill sizes and lifetime quotas on final amounts |
| `FeeFlatIn` | wrapper, upstream | Fixed input fee, unchanged upstream arithmetic |
| `FeePriorityIn` | wrapper, custom, optional | Charges the transaction's priority fee above a floor; stateless |
| `PortfolioSwap` | leaf, custom | Finite-trade PMM pricing on the shared state |
| `AccessGate` | compiler fragment | Upstream `PrivateOrder` or `WhitelistCoequal` with a rejecting fallthrough; not a new opcode |
| `Salt` | leaf, upstream | Distinct order identity per book |

- Wrappers inspect final amounts in both exact-in and exact-out modes. The nested notation describes VM execution, not external calls.
- Preflight, in both quote and swap, resolves the actual order, recipient, direction, exact amount, threshold and deadline, validates settlement traits and the registered program, then executes it. Static quotes make no writes and do not depend on transient storage.
- The fork's dispatcher must gain one entry per custom instruction. The upstream Aqua dispatcher ([`AquaOpcodes.sol`](https://github.com/1inch/swap-vm/blob/main/src/opcodes/AquaOpcodes.sol)) rejects unknown opcodes; adding a library alone changes nothing.

### 4.2 State

| State | Key | Purpose |
|---|---|---|
| Risk policy | maker, riskGroupId, policyVersion | Pair, signer, allowed fee and toll bounds, PMM parameters, anchor acceptance rules |
| Shared ledger and PMM state | maker, riskGroupId | One persistent inventory and curve state |
| Portfolio nonce | maker, riskGroupId | Identifies accepted changes to shared pricing state |
| Anchor | maker, riskGroupId | Accepted price, signed time, expiry, monotone nonce |
| Mandate terms | maker, riskGroupId, mandateId, revision | Fixed fee, toll parameters, access mode and list, direction, window, per-token limits |
| Mandate usage | maker, riskGroupId, mandateId, tokenOut | Cumulative authorized output consumed; survives book replacement |
| Admitted book | maker, router, orderHash | Exact policy and mandate identity, revision, program hash |
| Global output counter | maker, token | Gross token output used in the current block |
| Maker execution lock | maker | Prevents overlapping execution or state mutation during settlement |

### 4.3 Registry rules

- Policy and mandate changes require the maker's authority. Raising caps or widening access takes effect through a scheduled revision; reducing caps, pausing or revoking takes effect immediately. A fee change of either sign is a scheduled mandate revision with a newly shipped immutable order; activation retires the previous order and keeps cumulative usage.
- One active order identity is bound to a mandate revision. Replacing a book resets neither its lifetime usage nor the maker's output counters. A new mandate is a new maker authorization, never a taker-selected identifier.
- The registry validates the exact grammar: fee bytes, toll bytes, access guard, jump destinations and every identifier. Different fixed fees and access lists are permitted. Another curve, a dynamic fee outside §6.4, an unapproved callback or an arbitrary receiver rule is outside the grammar. A copied program has no admission authority.

### 4.4 Counterparty identity

- Access modes: `PUBLIC` and `DIRECT_ALLOWLIST`. Allowlists bind full 160-bit execution addresses in registered terms and are checked in preflight.
- Upstream whitelist instructions compare only the last 10 bytes of an address ([`Whitelist.sol`](https://github.com/1inch/swap-vm/blob/main/src/instructions/Whitelist.sol)). They may be compiled as an additional guard; they never replace the full-address check.
- `ctx.query.taker` is the immediate caller. The resolver book admits execution accounts that authenticate who may execute through them. Allowlisting a publicly callable router does not establish the identity behind it; arbitrary relaying into the restricted book is excluded.
- An authorized counterparty may choose its cheapest eligible book and may arbitrage. A lower resolver fee is a commercial term, not evidence of benign flow.

## 5. Pricing

### 5.1 `PortfolioSwap`

- A port of DODO's finite-trade Proactive Market Maker: [`PMMPricing.sol`](https://github.com/DODOEX/contractV2/blob/main/contracts/lib/PMMPricing.sol) and [`DODOMath.sol`](https://github.com/DODOEX/contractV2/blob/main/contracts/lib/DODOMath.sol), taken from one pinned source revision with attribution and license.
- The untouched reference libraries are vendored into a test-only tree, compiled in their own compilation unit with a compatible compiler (they target Solidity 0.6.9), and compared against the port through a harness. Expected values never come from another copy of the port.
- State `(i, k, B, Q, B0, Q0, R)` persists per `(maker, riskGroupId)` across trades. All direction and exactness combinations, equilibrium crossings, token scaling and rounding require a deterministic adapter and differential tests. Numerical integration does not define the Solidity implementation.
- The reference provides exact-in pricing only. Exact-out is a derived inversion with its own gate; see Open decisions.
- Recentring is an explicit transition: a new anchor or approved target change applies once to the current shared state. Repeated quotes at an unchanged anchor cannot reset the curve. Initialization and recentring must satisfy the canonical solver's state relationships; a portfolio preference is not permission to choose inconsistent `B0`, `Q0` and `R`.
- Provider fees increase the maker's actual input balance. The adapter accounts for fee reinvestment after the trade and leaves a valid next state. A state classification computed on net curve input is not assumed valid after gross input is credited.
- The ledger changes before settlement's external calls and rolls back if settlement fails. Quotes after a successful sibling trade read the new state. Pending mempool transactions do not affect on-chain quotes.

### 5.2 `MakerPriceAnchor`

- An EIP-712 signed update binds chain, router, maker, risk group, policy version, price, issued time, expiry, confidence bound and a monotone nonce. `priceWad` is quote units per base unit after pinned decimal normalization.
- Updates are published into shared on-chain state. Once a newer update is accepted, no taker can select an older one for any book. Future-dated, expired, replayed, wrongly scoped or unauthorized updates revert. Freshness derives from the signed issue time, never from publication time.
- Posting is permissionless because the signature carries authorization. A keeper publishes updates promptly in normal operation; a maker, relayer or builder can still delay an unpublished update.
- Acceptance rules: expiry, maximum age at fill, maximum deviation from the previously accepted anchor, and a maximum signed confidence bound. These are policy checks, not proof of price truth.
- The maker delegates only anchor signing to a revocable session key. A compromised signer can post plausible but harmful prices; output limits, key rotation and pause remain necessary.

### 5.3 Expiry and recovery

- When the anchor is missing or expired, new quotes and fills pause. The console shows `ANCHOR_STALE` and the route is unavailable.
- A valid fresh update restores eligibility unless the maker has explicitly paused the desk. An explicit pause clears only with maker authorization; a keeper cannot undo it by posting an anchor.
- There is no automatic transition to another curve on expiry. Continuous trading through signer outages is not offered.

## 6. Fees and limits

### 6.1 Fixed input fee

Uses upstream [`FeeFlatIn`](https://github.com/1inch/swap-vm/blob/main/src/instructions/FeeFlat.sol) unchanged. Its denominator is `D = 1e7` and `uint24 feeUnits` satisfies `0 <= f < D`; 30 and 5 conventional basis points encode as 30,000 and 5,000. The console performs and tests this conversion. Partial fills are excluded.

```text
exact-in:   grossIn fixed;  fee = ceil(grossIn * f / D);  curveIn = grossIn - fee;  amountOut = PMM.exactIn(curveIn)
exact-out:  amountOut fixed; curveIn = PMM.requiredInput(amountOut);  grossIn = curveIn + ceil(curveIn * f / (D - f))
```

The maker receives gross input through Aqua; the fee stays in that wallet. No protocol fee is set. Output rounds down and required input rounds up.

### 6.2 Mandate checks

- Each mandate fixes `BUY_BASE`, `SELL_BASE` or `BOTH`, its access terms and fee, inclusive start, exclusive end, `maxGrossInputPerFill[tokenIn]`, `maxOutputPerFill[tokenOut]` and `lifetimeOutflowQuota[tokenOut]`. A bidirectional book specifies output authorization for both tokens.
- Zero authorizes zero units. Unlimited is `type(uint256).max` and is displayed as unlimited. Global caps and live backing still apply.
- Usage is denominated in the output token: USDC when the maker buys WETH, WETH when the maker sells it. The two counters are tracked separately, so authorization is independent of anchor valuation. A lifetime quota never replenishes.
- Limits are enforced on final gross input and final output after the inner fee and curve return. Quota is consumed only by a successful swap; quotes never consume quota. Direction, window and quota failures revert in both quote and execution.

### 6.3 `MakerBudget`

- Per output token, a packed `(used, blockNumber)` slot; in a new block, effective usage is zero. Across every admitted book:

```text
usedOut[maker][tokenOut] + finalAmountOut <= maxOutflowPerBlock[maker][tokenOut]
```

- Both tokens require a cap: buying WETH spends USDC, and a WETH-only cap cannot bound that. Incoming tokens never replenish gross outflow within a block.
- The executable output ceiling is the minimum of book virtual output capacity, shared output reserve, live maker output balance, live Aqua allowance, remaining global budget, remaining mandate quota and the mandate's per-fill output limit. Input availability is checked on the taker side; the maker is never required to pre-fund the incoming transfer.
- The budget is a token-quantity rate limit, not a dollar loss bound, a drawdown guarantee or reserved capacity. One successful trade can exhaust it, and a slow drain across blocks remains possible.

### 6.4 `FeePriorityIn` (optional)

A per-book toll on the priority fee a caller attaches, after the [MEV tax](https://www.paradigm.xyz/2024/06/priority-is-all-you-need) mechanism used in production by [Angstrom L2](https://docs.angstrom.xyz/l2/arbitrage-auction). No upstream SwapVM instruction reads `tx.gasprice`; [`BaseFeeAdjuster`](https://github.com/1inch/swap-vm/blob/main/src/instructions/BaseFeeAdjuster.sol) reads `block.basefee` to give takers a gas discount.

- Encoding `[uint64 factor, uint64 floorWeiPerGas, uint64 maxTollWad]`, registered in mandate terms within the policy's bounds. A zero factor compiles to no instruction; such a book is identical in fee behaviour to a fixed-fee book. The instruction is stateless.

```text
tip     = tx.gasprice > block.basefee ? tx.gasprice - block.basefee : 0   // eth_call without gasPrice gives 0
taxable = tip > floorWeiPerGas ? tip - floorWeiPerGas : 0
tollWei = factor * TAXED_GAS * taxable                                     // TAXED_GAS is a pinned constant
tollIn  = min(convert(tollWei), amountIn * maxTollWad / 1e18)             // input-token units; rounded up

exact-in : amountIn -= tollIn; run inner curve; amountIn += tollIn        // same wrap structure as FeeFlatIn
exact-out: run inner curve; amountIn += tollIn; FeeFlatIn grosses up as today
```

- `convert` uses the accepted anchor: identity when `tokenIn` is WETH, `tollWei × priceWad` with pinned decimal normalization when `tokenIn` is the quote token. This binds the toll to pairs containing WETH.
- The toll is an input fee retained in maker inventory like the flat fee. It sits inside `FeeFlatIn`, so registered fixed-fee bytes are unchanged whether or not the toll is compiled.
- **Quote rule.** A quote through `eth_call` without `gasPrice` sees a zero tip and returns the fixed-fee floor. `desk.quoteBook` accepts `priorityFeePerGas` and sets `gasPrice`, so a quote at a stated tip equals execution at that tip. Execution exceeds a zero-tip quote only by the toll, bounded by the taker's threshold. This is the same declared quote/swap divergence class as upstream `BaseFeeAdjuster`.
- **Parameters.** `floorWeiPerGas` is set from observed ordinary wallet tips on the target chain so benign flow is exempt. `maxTollWad` prevents any tip from taking the full input. The resolver book registers factor zero.
- **Conditions.** The toll has value only where the sequencer orders by tip and at least two callers contend for the same window. It is zero where builders or bundles can zero the tip, zero for a solo searcher, and under Base Flashblocks applies only to same-window contention because ordering is by fee at selection within 200 ms windows ([Base docs](https://docs.base.org/base-chain/flashblocks/faq)). It captures a share of contested bids, not LVR.

## 7. Settlement and concurrency

```text
taker pays gross input  -> Aqua credits maker input
maker pays final output -> Aqua debits book output -> recipient receives output
shared ledger input delta  = actual Aqua gross input credit
shared ledger output delta = actual Aqua output debit
```

- The upstream input-first, direct ERC-20 settlement grammar is kept. Maker hooks, taker callbacks, native value, WETH unwrapping, output-first settlement, partial fills and alternative input-payment modes are rejected. Recipient, threshold and deadline are enforced from actual taker traits.
- A conservative maker execution lock spans validation, reservations and settlement. Nested same-maker swaps and quotes during settlement revert with `MakerBusy`. Policy, anchor, ledger and mandate mutations use the same lock authority. Sequential sibling swaps, including within one outer transaction, are supported; independent makers execute separately.
- Final ledger deltas, mandate usage and global output usage are reserved before external settlement. The lock releases only after settlement succeeds; a revert restores every reservation, counter, state transition and the lock.
- Pricing inventory is initialized by an explicit maker operation. Donations and unrelated wallet transfers never increase the ledger. Later ledger increases are explicit, checked against backing and delayed. Live balance and allowance remain settlement ceilings and may reduce capacity below the ledger.
- Aqua book balances remain independent: input credited through A does not replenish B's virtual balance. The console shows this constraint; replacement books require explicit maker authorization and preserve mandate usage. Summing virtual balances does not measure owned inventory.

## 8. MEV and LVR

Loss-versus-rebalancing is an LP's execution disadvantage against a benchmark trading at reference market prices; better-informed arbitrageurs profit from stale quotes ([Milionis, Moallemi, Roughgarden, Zhang](https://arxiv.org/abs/2208.06046)). Updating the anchor reduces some stale opportunity; it does not make every quote current or every trade favourable to the maker.

| Exposure | Mechanism | Practical limit |
|---|---|---|
| Repeated stale pricing across overlapping books | Every admitted book reads the same updated PMM state | Applies to Bastion books; implies no superiority over one equivalent aggregate book |
| Selecting an older signed price | Monotone, published shared anchor | Cannot prevent delayed publication of a newer price |
| Signer outage | Expired-anchor fills rejected | Trading stops; uptime and fee revenue suffer |
| Wrong but fresh price | Quantity caps, deviation and confidence acceptance rules, key rotation, maker pause | No on-chain guarantee of price accuracy or mark-to-market loss |
| Aggregate inventory leaving through sibling routes | Both-token block budgets and lifetime quotas | Limits quantity; can be exhausted by ordinary successful trades |
| Adverse selection inside a valid price window | Inventory feedback and the selected book's fixed fee | Residual LVR remains; a discounted counterparty may still arbitrage |
| Contested arbitrage bidding for position | `FeePriorityIn` charges the tip above the floor | Zero without tip ordering, for a solo searcher, and across Flashblock windows |
| Taker sandwiches | Slippage threshold and deadline | Sandwiches can occur within those bounds |
| Builder censorship and ordering | No fee privilege or selected-winner dependency | Builders still decide inclusion and ordering |
| Multi-block depletion | Lifetime quotas constrain authorized spending | No general dollar drawdown stop; makers can authorize more quota |

**Claims the product can make after validation.** A successful trade updates one shared inventory state used by subsequent sibling quotes. Per-mandate authorizations and the maker's aggregate quantity limits bind across admitted routes. No trade succeeds on an expired anchor. Every eligible caller pays the selected book's registered fixed fee. On a chain that orders by tip, two otherwise identical fills with different tips pay fees differing by exactly the toll formula, capped.

**Claims the product does not make.** Zero MEV, zero LVR, sandwich resistance, guaranteed yield, guaranteed arbitrage recovery, a dollar loss cap, a universal advantage over conventional market making, physical netting of opposing fills, LVR protection from the toll, or any recovered value before it is measured. Fee revenue, arbitrage extraction, mark-to-market change and LVR are different measurements; formal LVR requires an explicit rebalancing benchmark.

## 9. Automation

- A deterministic price keeper reads maker-approved sources, applies a documented selection and freshness policy, signs with an anchor-only session key and publishes updates. Missing, inconsistent or stale source data follows the configured failure policy.
- The anchor key cannot transfer tokens, grant approvals, create mandates, change fees, loosen budgets or undo an explicit pause. On-chain nonce, expiry and policy checks remain authoritative. A compromised key can still misprice within those rules.
- The client maps structured errors and coverage data to explanations: unauthorized caller, inactive window, exhausted quota, global budget used, inadequate backing, stale anchor.
- No planner, sentinel or autonomous mandate agent is part of the first release. Book configuration uses a typed form with maker-authorized transactions. Taker bots may execute any book their execution identity is eligible for, at that book's fee, with no priority.

## 10. Console, Coverage Lens and SDK

**Console.** Actual inventory and coverage, portfolio preference and realized inventory, anchor health, active books with fee, toll and access terms, remaining per-token quotas, current-block output usage, and transaction-backed results. Opcode bytes and WAD parameters are visible in an advanced view.

Each book row shows maker direction, fee, toll factor and floor, permitted counterparties, window, remaining authorizations and a status: active, unauthorized caller, not started, expired, quota exhausted, maker paused, anchor stale, insufficient backing, budget exhausted. Several may apply; `ship()` alone does not establish fillability. The approval view shows exact assets, decimal conversions, both-token limits, fee, access list, expiry, policy and mandate revision and transaction targets.

### 10.1 Coverage Lens

For each maker and token at a pinned block:

- Sum of live virtual balances in a declared, deduplicated book scope.
- Actual token balance, allowance to Aqua and `backing = min(balance, allowance)`.
- Advertised/backing ratio, live book count, chain, Aqua address, apps, block number and hash, and the source of the enumerated book set.
- For a specified Bastion book and caller: access, window and anchor status, and the output ceiling from virtual capacity, ledger, backing, global budget and per-token mandate limits, reported separately from quote or simulation status.

Rules: ratios are per token; never sum raw amounts across tokens or count one wallet's backing once per app. Zero backing yields an explicit `ZERO_BACKING` result, not a numeric percentage. A ratio above one is expected under shared liquidity and is not itself a finding. Aqua does not enumerate books on-chain; index `Shipped` and `Docked` events to the snapshot block, verify live balances, deduplicate `(app, strategyHash)`, and label a supplied or partial list as such. An output ceiling is a necessary bound only; re-simulate before sending.

### 10.2 SDK

```text
desk.previewBook(terms)                          -> validated fee, toll, access and limits; policy references
desk.buildProgram(mandate)                       -> pinned bytecode and program hash
desk.shipAndRegister(mandate)                    -> maker-authorized transactions
desk.quoteBook(order, taker, amount, priorityFeePerGas) -> caller-aware quote at that tip, snapshot, limits, expiry
desk.getHealth(maker, group)                     -> backing, anchor, quotas, budget, route status
coverage.snapshot(maker, scope)                  -> per-token coverage, block and indexing provenance
desk.pauseMandate(id)                            -> maker-authorized transaction
desk.replaceBook(id, revision)                   -> replacement retaining mandate usage
desk.signAnchor(update)                          -> scoped session-key signature
desk.postAnchor(signedUpdate)                    -> transaction
```

- Related quote reads are pinned to one block. Quote metadata carries block number and hash, anchor nonce, portfolio nonce, policy version, mandate revision and the tip assumed for the toll. Metadata describes a snapshot; execution enforces actual threshold, deadline and current contract rules.
- The `taker` parameter selects the simulation context; it does not authorize that address.
- A resolver-style client quotes, simulates and settles a real Aqua swap. A custom router is not automatically indexed or selected by production 1inch routing; the tested integration and remaining routing work are reported as such.

## 11. Validation gates

All gates are pending until an experiment in this repository produces the result.

| Gate | Required result |
|---|---|
| P1 | The PMM port matches the independently compiled, unmodified DODO reference across all states and equilibrium crossings |
| P2 | Exact-in and, if supported, exact-out satisfy declared inverse and maker-favouring rounding bounds in both token orientations |
| P3 | Initialization, target changes, anchor changes and fee reinvestment leave a valid canonical PMM state |
| P4 | One trade versus same-direction splits across equivalent eligible books meets the declared additivity tolerance |
| P5 | A successful fill on A changes B's next quote through shared state without any B transaction |
| A1 | Wrong signer or domain, stale or future timestamps, replay, regressing nonces, excessive deviation and wide confidence are rejected |
| A2 | Expiry pauses all affected books; fresh updates restore only books not explicitly paused |
| M1 | Wrong direction, pre-start, expired, oversized and exhausted mandates fail in every supported exactness mode |
| M2 | Replacing, re-salting or copying a book cannot reset usage or acquire admission |
| M3 | Expiring C or revoking B leaves A operational within its own terms |
| M4 | Distinct fixed-fee bytes are enforced; scheduled replacement changes terms without resetting usage |
| M5 | Unauthorized callers fail; full-address admission rejects suffix-only matches; malformed access branches fail preflight |
| B1 | Both-token global caps hold across eligible sibling books, callers and transaction sequences |
| B2 | Incoming tokens do not replenish gross output usage; block rollover does not reset lifetime quota |
| F1 | Same state and fill at tips of zero, the floor and above the floor pay fees differing exactly by the toll formula at the accepted anchor; the cap binds |
| F2 | A zero factor compiles to no instruction and matches the fixed-fee book; a quote at a stated `gasPrice` equals execution at that tip |
| F3 | The toll is retained in maker inventory and reconciles in settlement |
| S1 | Aqua credits and debits, gross fee accounting, ledger changes and token balances reconcile |
| S2 | A failed settlement rolls back every reservation and the maker lock |
| S3 | Nested same-maker execution and concurrent policy changes are rejected; sequential routes work |
| S4 | Every excluded settlement trait, unknown instruction and unauthorized program fails preflight |
| Q1 | Static quotes make no writes and agree with execution from the same state within exact rounding rules |
| Q2 | Every capacity component is tested independently; maker input prefunding is never required |
| K1 | Typed form, compiler and contracts agree on fee units, decimals, per-token limits and execution identity |
| K2 | Anchor-only keys cannot exercise maker permissions; revocation, stale-source handling and pause semantics work |
| L1 | Coverage matches live virtual balances, wallet balance and allowance at the stated block, including zero backing |
| L2 | Multi-app enumeration, docked books, duplicate hashes and pagination never double-count; partial scope is labelled |
| L3 | Output ceilings, caller eligibility and simulated fills are reported distinctly; unsupported checks are marked unknown |
| E1 | Matched-curve controls isolate shared-state exposure from curve choice, fees, routing and rejected flow |
| E2 | A capacity-stress replay reproduces a quoted-but-unfillable overlapping book; Bastion rejects output above live backing |
| D1 | Deployed runtime is below 24,576 bytes with recorded headroom; gas and encoding are measured |
| D2 | Console, signer and resolver-style client execute the complete real-token demonstration |

Order independence of mixed-direction trades is not asserted; fees and state transitions make order economically relevant. Slicing tests use explicitly equivalent eligibility, fee and starting conditions and report rounding assumptions.

### 11.1 Economic evaluation

- Compare, with identical initial real capital, reference price paths, demand and counterparty identities: one aggregate fixed-fee `XYCSwap` book; honestly split `XYCSwap` books with proportional routing plus a labelled overlapping-book stress control; one aggregate PMM with equivalent anchor policy, fee and access choices and capacity limits; Bastion's mandates on the shared PMM state.
- Isolate coordination first with a matched-curve control: isolated overlapping states, one aggregate state and shared state behind multiple books, all on the same curve and fee policy. A vanilla-versus-Bastion comparison changes curve and coordination at once and cannot attribute the difference to shared state.
- Give every counterparty equivalent fee and access choices, including the cheapest eligible route. Do not force orders to fill regardless of price; report rejected flow as an outcome.
- Measure maker marked-equity change adjusted for external cash flows, fee revenue, reference-mark trade losses, inventory exposure, user execution cost, successful volume, failure reasons and gas. Include keeper, indexing and routing costs in any profitability claim.
- Sweep anchor cadence, volatility, jumps, wrong anchors, one-sided and scarce flow, fees, quotas and budgets on held-out paths with reported uncertainty. A desk that avoids losses by rejecting demand has reduced service, which is reported beside maker results.
- The toll enters no economic comparison until a contention process is modelled. No external percentage is carried into Bastion's results.

## 12. Demonstration

A four-minute recording plus a linked technical replay.

1. **Repeated exposure.** Replay one external price move against five independent overlapping books, five coordinated books and one aggregate control, on the same curve, fees and initial real capital. Display measured extraction and actual output.
2. **Three commercial books.** Public A at 30 bps, restricted B at 5 bps, timed sale C; typed setup and receipts show one wallet and one shared pre-fee state, and that shipping moved no inventory.
3. **Shared feedback.** Fill A with a real ERC-20 swap; B's and C's quotes move without any update to them. An authorized resolver uses B, an unauthorized caller is rejected, C expires without retiring A.
4. **Coverage failure.** In a separate capacity-stress fixture, show a vanilla book's advertised balance, remaining backing and failed settlement; then show Bastion rejecting output above its remaining ceiling with an explanation.
5. **One aggregate budget.** Fill eligible sibling books until the shared output cap binds; switching books or callers does not reset it. The Coverage Lens shows backing, the scoped ratio and the binding constraint beside real transfers.

The technical replay covers both-token quota exhaustion, keeper expiry and recovery, explicit pause, quote-to-inclusion races, unauthorized policy changes and, if built, the toll: two identical fills on A at different tips, and the same fill on B at factor zero. Transaction hashes, snapshot blocks, inputs and real token movements are displayed; a counter animation is not proof of settlement.

## 13. Delivery order and cut policy

| Milestone | Deliverable |
|---|---|
| 1 | Freeze source versions, the independent DODO reference, three book fixtures and matched economic controls |
| 2 | Canonical finite-trade solver, state initialization and recentring, fee-accounting conformance |
| 3 | Shared ledger, maker lock, global budgets, real Aqua settlement |
| 4 | Per-book fixed fees, full-address access checks, direction, window and amount checks, persistent per-token quotas |
| 4b (conditional) | `FeePriorityIn` opcode, dispatch entry, registry parameters, anchor conversion and the F gates; started only when milestones 1–4 are green, otherwise cut without replacement |
| 5 | Anchor keeper, expiry pause and recovery, scoped key handling |
| 6 | Coverage Lens, scoped indexing, typed console, structured health explanations |
| 7 | Caller-aware resolver-style client and the complete transaction-backed demonstration |
| 8 | Economic controls, gas and size evidence, final documentation and recording |

- The PMM adapter is the first feasibility gate. If its conformance fails, the blocker is reported and the curve re-scoped explicitly; no substitute curve is presented as the canonical PMM.
- Protected: differentiated books, shared-state demonstration, real settlement, capacity checks, the Coverage Lens, typed console, keeper.
- Cut order: extra charts, a second chain, additional integrations, then `FeePriorityIn`, before the console and the lens.

## 14. Deferred

- **Fee privilege by auction.** Reconsidered only after an ex-ante bidder model shows positive net maker improvement over an optimized fixed-fee baseline at comparable user cost, including inclusion competition, sparse bidders, spoilage, gas, capital cost and flow leakage. Reference: [am-AMM](https://arxiv.org/abs/2403.03367).
- **Block-volume tranche fee.** Its incidence depends on block position, which builders assign. Reconsidered only after an integrated shared-state implementation shows a useful maker and user trade-off under adversarial ordering. Reference: [Triangle fees](https://arxiv.org/abs/2306.17316).
- **Restricted maker account.** A contract maker that binds spending to admitted Bastion execution would close the external-wallet-spend gap at the cost of inventory mobility; requires approvals, execution modules and override policy, not a wrapper.
- **Automatic stale-to-curve transition.** Requires a specified boundary and adversarial testing on both sides of it.
- **External reference band.** A push oracle used only as a deviation guard on anchor acceptance, never as the quoting price.
- **Third-party anchor source.** A pull oracle as signer for makers without a pricer, gated on same-block publication and a confidence bound.
- **Toll extensions.** Dynamic factor, proceeds splitting, an ETH reference for pairs without WETH.
- **Agents.** A typed-proposal planner, a read-only sentinel, and cumulative on-chain grants for autonomous mandate renewal.
- **Multi-asset risk groups, asynchronous netting, uniform-price settlement.** Each requires its own valuation or settlement architecture.

## 15. Limits

- One chain and one pair in the demonstration; no security-review claim.
- Custom routing demonstrates execution, not inclusion in production 1inch routes or organic order flow.
- The maker's signer can be wrong; stale anchors halt trading. Fixed fees and inventory feedback do not eliminate MEV or LVR.
- Budgets bound token outflow, not dollar losses or multi-block drawdown. Other wallet and app activity is outside Bastion's controls.
- Coverage is a scoped snapshot, not reserved liquidity or a guarantee that a quoted trade will settle.
- The priority toll applies only where the sequencer orders by tip; it is zero for uncontested or bundled flow and is not a measured benefit.

## 16. Prior art and attribution

| Component | Origin | Bastion's difference |
|---|---|---|
| `PortfolioSwap` | DODO PMM, `P = i·R` with `k` | Maker-signed anchor instead of a third-party feed; state shared across separately admitted orders; explicit recentring transitions |
| `MakerPriceAnchor` | First-party signed prices; gating after [Lifinity](https://docs.lifinity.io/dex/oracle) | Published on-chain and unselectable by the taker; deviation and confidence acceptance rules |
| Upstream [`OraclePriceAdjuster`](https://github.com/1inch/swap-vm/blob/main/src/instructions/OraclePriceAdjuster.sol) | Chainlink-compatible, single-direction, taker-favourable adjustment | Bidirectional curve input with freshness and policy checks |
| Upstream [`DynamicBalances`](https://github.com/1inch/swap-vm/blob/main/src/instructions/Balances.sol) | Per-order state | State keyed by maker and risk group |
| `MakerBudget`, quotas | Token-bucket rate limiting | Maker-wide, both tokens, per block, across books |
| `FeePriorityIn` | [Paradigm MEV tax](https://www.paradigm.xyz/2024/06/priority-is-all-you-need); [Angstrom L2](https://docs.angstrom.xyz/l2/arbitrage-auction) | Stateless input-fee wrapper with floor and per-book factor; first on SwapVM, not first |
| Aqua predecessors | [ProaqctiveMM](https://ethglobal.com/showcase/proaqctivemm-f0y6v) (PMM with Pyth), [Vortex](https://ethglobal.com/showcase/vortex-aowex) (inventory-aware pricing and limits), [Aqua Outcome Market](https://ethglobal.com/showcase/aqua-outcome-market-0va0j) (research invariant as custom instructions) | Shared state across books, aggregate budgets, per-book terms, public coverage tooling |

These are component-level differences, not claims of being the first PMM or the first inventory-aware pricing on Aqua. The [upstream program guide](https://github.com/1inch/swap-vm/blob/main/docs/PROGRAMS.md) asks for bounded parameters, composition evidence and reviewed programs; Bastion supplies maker-configured controls within that model.

## 17. Open decisions

- **Exact-out in the first increment.** The DODO reference is exact-in only. Either derive and gate the inversion (P2, F1) or reject exact-out in preflight for the first release and defer.
- **Toll conversion source.** The accepted anchor (fresh, validated, WETH pairs only) versus a maker-set ETH price constant (any pair, drifts).
- **Resolver identity in the demonstration.** A direct EOA allowlist versus an execution-account adapter.
- **Coverage indexing.** An on-chain view over a caller-supplied scope plus an event script, versus a hosted indexer.

## Change log

- **v0.1, 2026-09-06.** Initial specification: segmented books, shared PMM state, maker-signed anchor, mandates and budgets, optional priority toll, Coverage Lens, gates, demonstration and delivery order.

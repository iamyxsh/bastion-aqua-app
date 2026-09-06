# Bastion

**Segmented flow. Unified inventory.**

An [Aqua](https://github.com/1inch/aqua) trading desk where one maker runs public, resolver-only and timed books on different commercial terms — all quoting from one pricing state, all bound by one set of aggregate outflow limits.

> Aqua enables inventory reuse. Bastion coordinates pricing and bounds authorized outflow across that reuse.

Built for the **ETHGlobal ETHOnline** hackathon.

## Why

Aqua keys virtual balances by `(maker, app, strategyHash, token)`, so one wallet backs many strategies at once — capital stops fragmenting across pools. But each [SwapVM](https://github.com/1inch/swap-vm) program prices from *its own* strategy balances: a fill through one book does not move a sibling book's quotes, and nothing bounds the maker's aggregate outflow across books.

Bastion is a maker-side coordination and risk layer over **unmodified Aqua accounting**:

- **One PMM state per risk group** — a fill in any book reprices every sibling.
- **One outflow policy per maker** — per-block, per-token gross output caps and lifetime quotas that survive book replacement.
- **Per-book terms** — fee, access list, direction, window, quotas; each independently pausable and replaceable.

## The three books (WETH/USDC)

| Book | Access | Fixed fee | Lifecycle |
|---|---|---|---|
| A — public market | any taker | 30 bps | open until quota exhausted or stopped |
| B — resolver agreement | allowlisted execution addresses | 5 bps | independently revocable |
| C — timed sale | any taker | 30 bps | active only inside its window |

Same pre-fee price. Fill A and both B and C requote, with no transaction touching them. Revoke B and A keeps trading.

## Coverage Lens

Read-only, for any maker on the deployment: advertised virtual balances against `backing = min(balance, allowance)`, the per-token ratio, and — for a given book and caller — the binding constraint on a proposed fill.

## What it does not claim

Zero MEV, zero LVR, sandwich resistance, guaranteed yield, or a dollar loss cap. Budgets bound token quantity, not drawdown, and Bastion cannot govern the maker's activity through other apps.

## Status

Specification only — v0.1, no contracts yet. Design, validation gates and delivery order live in [`specs/BastionAquaApp.MD`](specs/BastionAquaApp.MD).

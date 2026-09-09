#!/usr/bin/env python3
"""Run actual Solidity pricing, select on training only, report held-out numbers.

Uses only the Python standard library and the repository's existing Foundry tool.
Fixtures must already be downloaded: this runner never contacts a market API.
"""
import argparse
from datetime import date, timedelta
from decimal import Decimal
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess

ROOT = Path(__file__).resolve().parents[1]
EXPERIMENT = ROOT / "experiments/curves"
EVIDENCE = EXPERIMENT / "evidence/market-replay"
W = 10**18
NAMES = {0: "XYC", 1: "CLMM fixed", 2: "PMM", 3: "CLMM daily"}


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def preflight():
    config = json.loads((EXPERIMENT / "replay.json").read_text())
    manifest = json.loads((EXPERIMENT / "data/manifest.json").read_text())
    if manifest["config_sha256"] != sha(EXPERIMENT / "replay.json"):
        raise ValueError("config changed after data pin; rebuild fixtures before running")
    expected = [(date.fromisoformat(config["start_date"]) + timedelta(days=j)).isoformat() for j in range(config["days"])]
    if [d["date"] for d in manifest["days"]] != expected:
        raise ValueError("fixture dates do not match preregistered consecutive dates")
    for day in manifest["days"]:
        if sha(EXPERIMENT / "data" / day["fixture"]) != day["fixture_sha256"]:
            raise ValueError(f'fixture checksum mismatch: {day["fixture"]}')
    if config["lag_seconds"] != [0, 1, 5, 30]:
        raise ValueError("fixture schema has exactly 0/1/5/30-second observations")
    files = ["experiments/curves/replay.json", "experiments/curves/data/manifest.json",
             "experiments/curves/test/MarketReplay.t.sol", "experiments/curves/foundry.toml",
             "reference/dodo/src/PMMHarness.sol", "reference/dodo/foundry.toml",
             "reference/dodo/lib/PMMPricing.sol", "reference/dodo/lib/DODOMath.sol",
             "reference/dodo/lib/DecimalMath.sol", "reference/dodo/lib/SafeMath.sol",
             "contracts/src/instructions/XYCSwap.sol", "contracts/src/instructions/XYCConcentrate.sol",
             "contracts/node_modules/@openzeppelin/contracts/utils/math/Math.sol",
             "scripts/fetch-curve-data.py"]
    sources = {f: sha(ROOT / f) for f in files}
    # Include compiled creation code, so changes in any transitive Solidity import
    # invalidate cached results even when the directly named sources did not change.
    for artifact in ["experiments/curves/out/MarketReplay.t.sol/MarketReplayTest.json",
                     "reference/dodo/out/PMMHarness.sol/PMMHarness.json"]:
        obj = json.loads((ROOT / artifact).read_text())
        sources[artifact + ":bytecode"] = hashlib.sha256(obj["bytecode"]["object"].encode()).hexdigest()
    fingerprint = hashlib.sha256(json.dumps(sources, sort_keys=True).encode()).hexdigest()
    return config, manifest, sources, fingerprint


def run_case(phase, days, kind, fee, lag, k, band, fingerprint, refresh=False):
    label = f"{phase}-kind{kind}-fee{fee}-lag{lag}-k{k}-band{band}"
    folder = EVIDENCE / "cases" / fingerprint[:16]
    folder.mkdir(parents=True, exist_ok=True)
    cached = folder / f"{label}.json"
    if cached.exists() and not refresh:
        result = json.loads(cached.read_text())
        if result["fingerprint"] != fingerprint or result["dates"] != days:
            raise ValueError("cached case provenance mismatch")
        return result
    print(f"{label}: {days[0]}..{days[-1]}", flush=True)
    env = dict(os.environ)
    env.update({"FOUNDRY_GAS_LIMIT": "9223372036854775807", "RUN_MARKET_REPLAY": "true",
                "REPLAY_DATES": ",".join(days), "REPLAY_KIND": str(kind), "REPLAY_FEE": str(fee),
                "REPLAY_LAG": str(lag), "REPLAY_K_PERCENT": str(k), "REPLAY_BAND": str(band)})
    command = ["forge", "test", "--root", "experiments/curves", "--match-contract", "MarketReplayTest",
               "--match-test", "test_RunReplay", "-vv"]
    process = subprocess.run(command, cwd=ROOT, env=env, text=True, capture_output=True)
    log = process.stdout + process.stderr
    (folder / f"{label}.txt").write_text(log)
    if process.returncode:
        raise RuntimeError(f"replay failed: {label}\n{log[-12000:]}")
    daily = [json.loads(m.group(1)) for m in re.finditer(r"REPLAY_RESULT (\{[^\n]+\})", log)]
    if len(daily) != len(days) or [d["through_date"] for d in daily] != days:
        raise ValueError("missing/reordered Solidity replay results")
    result = {"fingerprint": fingerprint, "phase": phase, "dates": days,
              "kind": kind, "fee_bps": fee, "lag_seconds": lag, "k_percent": k, "band_bps": band,
              "command": command, "daily": daily, "final": daily[-1]}
    cached.write_text(json.dumps(result, indent=2) + "\n")
    final = result["final"]
    print(f'  equity {final["final_equity_wad"]/W:,.2f} USDT; '
          f'customer fills {final["fills"]}/{final["requests"]}; '
          f'arb trades {final["arb_trades"]}', flush=True)
    return result


def money(wad):
    return f"{Decimal(wad) / W:,.2f}"


def ratio_bps(n, d):
    return Decimal(n) * 10000 / d if d else Decimal(0)


def render(config, manifest, selected, sources, fingerprint):
    cap = config["initial_capital_quote"] * W
    evaluation = [d["date"] for d in manifest["days"] if d["phase"] == "evaluation"]
    rows = ["# PMM market replay", "", "Counterfactual experiment using actual Solidity curves; not live P&L or Aqua settlement.", "",
            f'Pinned market: **ETH/USDT**, {config["start_date"]} through {manifest["days"][-1]["date"]}. '
            f'Train on the first {config["training_days"]} days; evaluate {evaluation[0]} through {evaluation[-1]}.', "",
            f'{sum(d["raw_trades"] for d in manifest["days"]):,} raw aggregate trades; '
            f'{sum(d["sampled_trades"] for d in manifest["days"]):,} sampled requests; '
            f'initial equity **{config["initial_capital_quote"]:,} USDT** per model and phase.', "",
            "## Held-out equity comparison", "",
            "Each family selects its parameter on training equity only. PMM is compared against both CLMM policies; "
            "`best CLMM` means the larger evaluation equity of those two separately trained controls, a deliberately demanding comparison. "
            "Zero delay is an ideal control, not measured oracle performance. Values include reinvested swap fees and the stated CLMM rebalancing costs, "
            "but exclude deployment/transaction/oracle costs.", "",
            "| Common fee (bps) | Delay (s) | Selected PMM K | PMM equity (USDT) | Extra vs XYC (USDT) | Extra vs best CLMM (USDT) | Edge vs strongest conventional (bps of initial capital) |",
            "|---:|---:|---:|---:|---:|---:|---:|"]
    comparisons = []
    for fee in config["fee_bps"]:
        for lag in config["lag_seconds"]:
            group = selected[f"fee{fee}-lag{lag}"]
            m, x = group["PMM"]["evaluation"], group["XYC"]["evaluation"]
            candidates = [group[name]["evaluation"] for name in ["CLMM fixed", "CLMM daily"]]
            c = max(candidates, key=lambda r: r["final"]["final_equity_wad"])
            strongest = max([x, *candidates], key=lambda r: r["final"]["final_equity_wad"])
            equity = m["final"]["final_equity_wad"]
            dx = equity - x["final"]["final_equity_wad"]
            dc = equity - c["final"]["final_equity_wad"]
            delta = equity - strongest["final"]["final_equity_wad"]
            comparisons.append({"fee_bps": fee, "lag_seconds": lag, "pmm": m, "strongest": strongest,
                                "edge_quote_wad": delta, "edge_bps": str(ratio_bps(delta, cap))})
            rows.append(f'| {fee} | {lag} | {m["k_percent"]/100:g} | {money(equity)} | {money(dx)} | {money(dc)} | {ratio_bps(delta,cap):+.2f} |')
    primary = next(c for c in comparisons if c["fee_bps"] == config["primary_fee_bps"] and c["lag_seconds"] == 1)
    pm, control = primary["pmm"]["final"], primary["strongest"]["final"]
    headline = [
        f'**Primary-fee example, 1-second assumed delay:** PMM ends at {money(pm["final_equity_wad"])} USDT, '
        f'versus {money(control["final_equity_wad"])} for {NAMES[primary["strongest"]["kind"]]}, the strongest conventional control. '
        f'The difference is **{money(primary["edge_quote_wad"])} USDT / {Decimal(primary["edge_bps"]):+.2f} bps of starting capital**, before additional deployment costs.', "",
        f'That difference comprises {money(pm["trade_pnl_wad"]-control["trade_pnl_wad"])} USDT of trade-execution P&L, '
        f'{money(pm["holding_pnl_wad"]-control["holding_pnl_wad"])} of inventory holding P&L, and '
        f'{money(control["rebalance_cost_wad"]-pm["rebalance_cost_wad"])} of lower rebalancing costs. '
        'It is not all additional trading profit. All delays and both fees are reported below; a longer delay can sometimes increase terminal equity through different flow and inventory exposure.', ""
    ]
    at = rows.index("## Held-out equity comparison")
    rows[at:at] = headline
    rows += ["", "## Price observation age", "",
             "Pipeline delay is a scenario assumption. Actual age also includes gaps between source trades; "
             "the experiment uses last-trade prices, not a continuously published executable bid/ask quote.", "",
             "| Assumed delay (s) | Maximum actual anchor age in evaluation (s) |",
             "|---:|---:|"]
    for lag in config["lag_seconds"]:
        age = max(d["max_anchor_age_us"][str(lag)] for d in manifest["days"] if d["phase"] == "evaluation") if lag else 0
        rows.append(f'| {lag} | {age/1_000_000:.6f} |')
    rows += ["", "## Service and attribution", "",
             "Filled volume is customer input notional at the recorded market price; arbitrage volume is separate. "
             "Customer cost is the reference-value shortfall as bps of filled input notional (negative is better for customers). "
             "Fees are already included in trade P&L: do not add them a second time. "
             "Equity reconciles to initial capital + inventory holding P&L + trade P&L − rebalancing costs at every event.", "",
             "| Fee | Delay | Model / selected parameter | Equity USDT | Customer fills | Filled input / offered | Customer cost bps | Trade P&L USDT | Holding P&L USDT | Fees USDT | Arb loss USDT | Rebalance cost USDT | Max sampled drawdown bps |",
             "|---:|---:|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|"]
    for fee in config["fee_bps"]:
        for lag in config["lag_seconds"]:
            for name, entry in selected[f"fee{fee}-lag{lag}"].items():
                r = entry["evaluation"]; f = r["final"]
                parameter = f'K={r["k_percent"]/100:g}' if r["kind"] == 2 else (f'band={r["band_bps"]} bps' if r["kind"] in (1,3) else "")
                rows.append(f'| {fee} | {lag} | {name} {parameter} | {money(f["final_equity_wad"])} | {f["fills"]}/{f["requests"]} '
                            f'| {ratio_bps(f["volume_wad"],f["offered_wad"])/100:.2f}% | {ratio_bps(f["customer_cost_wad"],f["volume_wad"]):.2f} '
                            f'| {money(f["trade_pnl_wad"])} | {money(f["holding_pnl_wad"])} | {money(f["fees_wad"])} '
                            f'| {money(f["arb_loss_wad"])} | {money(f["rebalance_cost_wad"])} | {f["max_drawdown_bps"]} |')
    rows += ["", "## Additional cost budget", "",
             "These are sensitivities, not measured gas. Charge the same assumed oracle cost per update to both models "
             "(PMM refreshes at every sampled request; daily CLMM refreshes on rebalance). "
             "Headroom is the extra edge divided by the difference in update counts; zero means PMM already fails to beat the control before extra costs. "
             "Transaction-count differences, external hedge costs and other operating expenses must also fit inside that budget.", "",
             "| Fee | Delay | Strongest control | PMM updates | Control updates | Break-even USDT per additional update | Edge after 0.01 USDT/update | Edge after 0.10 USDT/update |",
             "|---:|---:|---|---:|---:|---:|---:|---:|"]
    for c in comparisons:
        m, b = c["pmm"]["final"], c["strongest"]["final"]
        count = m["updates"] - b["updates"]
        edge = Decimal(c["edge_quote_wad"]) / W
        headroom = max(Decimal(0), edge) / count if count > 0 else Decimal(0)
        rows.append(f'| {c["fee_bps"]} | {c["lag_seconds"]} | {NAMES[c["strongest"]["kind"]]} '
                    f'| {m["updates"]} | {b["updates"]} | {headroom:.6f} | {edge-Decimal("0.01")*count:+.2f} | {edge-Decimal("0.10")*count:+.2f} |')
        c["cost_sensitivity"] = {price: str(edge - Decimal(price) * count) for price in config["oracle_cost_quote_scenarios"]}
    rows += ["", "## Limits and interpretation", "",
             "- One seven-day period and one five-day holdout; no statistical claim or guarantee across market regimes.",
             "- One actual trade per minute is offered unchanged to each curve. This is hypothetical routing and willingness to pay, not observed Bastion order flow.",
             "- All ticks inform lagged anchors, but arbitrage happens only before and after sampled requests; opportunities between samples are omitted. This can understate adverse selection.",
             "- Reference and external hedge prices are trade prints, not executable bid/ask quotes; external depth, bid/ask costs and hedge slippage are omitted.",
             "- The 50-bps input-value shortfall limit is an assumption. Rejected and partially filled demand is reported, not silently filled or discarded.",
             "- A fixed reciprocal CLMM band and a daily external-rebalancing policy are benchmark strategies, not a reproduction of Gamma or all CLMM managers.",
             "- This compares quoting and recentring strategies; it does not isolate pure curve geometry or test every possible CLMM management cadence.",
             "- PMM fees are gross input retained in reserves; DODO adjustedTarget canonicalizes the next state. Exact equilibrium absorbs fees into equilibrium targets. This is the declared simulator reinvestment policy, not a verified Bastion implementation.",
             "- Both model tokens have 18 decimals; actual WETH/USDC scaling, exact-out, signed-price authentication, Aqua settlement, shared books, budgets and deployed gas remain untested.",
             "- More final equity alone can reflect different inventory exposure or less service. Read trade P&L, customer cost, fill volume and drawdown alongside the headline edge.", "",
             "## Reproduce", "", "```sh", "make curves-data       # download / verify raw archives", "make curves-check      # data + Solidity boundary checks", "make curves-replay     # offline replay, training selection, evaluation, report", "```", "",
             f'Input fingerprint: `{fingerprint}`. Raw commands, per-day Solidity outputs and selected training configurations are retained in `{EVIDENCE.relative_to(ROOT)}/`.']
    EVIDENCE.mkdir(parents=True, exist_ok=True)
    (EVIDENCE / "REPORT.md").write_text("\n".join(rows) + "\n")
    payload = {"fingerprint": fingerprint, "config": config, "manifest": manifest, "source_checksums": sources,
               "runner_sha256": sha(Path(__file__)), "selected": selected, "comparisons": comparisons}
    (EVIDENCE / "results.json").write_text(json.dumps(payload, indent=2) + "\n")
    print(f"\nSaved {EVIDENCE.relative_to(ROOT)}/REPORT.md and results.json", flush=True)
    for c in comparisons:
        if c["fee_bps"] == config["primary_fee_bps"]:
            print(f'PRIMARY fee={c["fee_bps"]} lag={c["lag_seconds"]}: '
                  f'PMM extra vs strongest conventional = {money(c["edge_quote_wad"])} USDT / {Decimal(c["edge_bps"]):+.2f} bps', flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--smoke", action="store_true", help="one training day, four model families; no economic conclusion")
    parser.add_argument("--refresh", action="store_true", help="rerun rather than reuse matching Solidity outputs")
    args = parser.parse_args()
    config, manifest, sources, fingerprint = preflight()
    training = [d["date"] for d in manifest["days"] if d["phase"] == "training"]
    evaluation = [d["date"] for d in manifest["days"] if d["phase"] == "evaluation"]
    if args.smoke:
        for kind in [0, 1, 2, 3]:
            run_case("smoke", training[:1], kind, config["primary_fee_bps"], 1, 10 if kind == 2 else 0,
                     780, fingerprint, args.refresh)
        return
    selected = {}
    for fee in config["fee_bps"]:
        for lag in config["lag_seconds"]:
            group = {}
            for kind in [0, 1, 3, 2]:
                actual_lag = lag if kind in [2, 3] else 0
                ks = config["pmm_k_percent"] if kind == 2 else [0]
                bands = config["clmm_halfwidth_bps"] if kind in [1, 3] else [780]
                candidates = [run_case("training", training, kind, fee, actual_lag, k, band, fingerprint, args.refresh)
                              for k in ks for band in bands]
                winner = max(candidates, key=lambda r: r["final"]["final_equity_wad"])
                result = run_case("evaluation", evaluation, kind, fee, actual_lag, winner["k_percent"],
                                  winner["band_bps"], fingerprint, args.refresh)
                group[NAMES[kind]] = {"training": winner, "evaluation": result}
            selected[f"fee{fee}-lag{lag}"] = group
    render(config, manifest, selected, sources, fingerprint)


if __name__ == "__main__":
    main()

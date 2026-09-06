# Upstream sources and pins

Bastion is a **bounded fork of SwapVM** plus an **unmodified Aqua** dependency and an
**unmodified DODO PMM reference**. This file is the manifest that makes "bounded" checkable.

Run `make check-upstream` to verify every claim below. It re-downloads each pinned tree
and diffs it against the working copy.

## Pins

| Tree | Upstream | Pinned commit | Our copy | May we edit it? |
|---|---|---|---|---|
| SwapVM | [`1inch/swap-vm`](https://github.com/1inch/swap-vm) | `9502fd44254fef12fa448c3059868505b4c9dfff` (2026-08-21) | `contracts/` | **Yes — bounded.** Every edit must be listed in "Fork surface" below. |
| Aqua | [`1inch/aqua`](https://github.com/1inch/aqua) | `9c5c42e5840e8741fba3597c48456c9510212b66` (2026-08-21) | `aqua/` | **No.** Spec §4 requires unmodified Aqua accounting. Diff must stay empty. |
| DODO PMM | [`DODOEX/contractV2`](https://github.com/DODOEX/contractV2) | `2f1bcdac7ef1beee7599a756e2eed26732c2536d` (2025-11-12) | `reference/dodo/lib/` | **No.** It is the independent oracle for gate P1. Diff must stay empty. |

Spec §4 records the short pins `1inch/swap-vm@9502fd4` and `1inch/aqua@9c5c42e`
([specs/BastionAquaApp.MD:56](specs/BastionAquaApp.MD)). Both resolve to the full SHAs above.

### Why two copies of Aqua exist

`contracts/package.json` pins `"@1inch/aqua": "github:1inch/aqua#v1.0.0"`, which resolves to
commit `81c26e4619ce21556ab02b3284ee2685de21fb18`. That is what SwapVM compiles against, in
`contracts/node_modules/@1inch/aqua/`.

Our standalone `aqua/` clone is at the spec's pin `9c5c42e`, used to **deploy Aqua on anvil**
and to read the source. The two differ by 5 commits touching only `.github/workflows/*` and
`README.md` — **zero Solidity difference**, verified via the GitHub compare API. So the
contract behaviour is identical and no reconciliation is needed.

### Intentional deviations from the pinned trees

These are the only differences `check-upstream.sh` tolerates:

- `.github/` removed from `contracts/` and `aqua/` — upstream CI workflows are not ours to run.
- `.git/` removed from both, per the project decision to vendor rather than submodule.
- Generated dirs (`node_modules/`, `out/`, `cache/`, `artifacts/`, `deployments/`) are ignored.
- `contracts/snapshots/*.json` are excluded from the diff: upstream tests use gas-snapshot
  cheatcodes, so **any** test run rewrites them. They are committed at their pinned values;
  if you see them dirty in `git status`, that is a test run, not an edit.
- `contracts/broadcast/` is excluded from the diff (local anvil deploys write there), but its
  43 upstream deployment records **are** committed — the root `.gitignore` deliberately does
  not blanket-ignore `broadcast/`.

## Fork surface

Every file we have changed or added inside `contracts/`. Keep this list exhaustive — it is
the evidence that upstream settlement is preserved.

| Path | Status | Why |
|---|---|---|
| `contracts/script/bastion/SmokeSwapLocal.s.sol` | **added** | Milestone 1 increment 3 local-anvil smoke test. Calls only — no upstream file changed. |

No upstream file has been **modified** yet. `AquaOpcodes.sol` and every instruction are
still byte-identical to the pin; `make check-upstream` proves it and prints anything new.

### Known forge issue this repo works around

`forge script` 1.0.0-stable aborts with `Failed to decode constructor arguments` /
`ABI decoding failed: buffer overrun while deserializing` when the script deploys
`AquaSwapVMRouter`. The whole broadcast is dropped — the script reports
"Script ran successfully" while the chain stays at block 0, so it fails silently.

`forge create` deploys the same contract fine. `scripts/anvil-smoke.sh` therefore does
every deployment with `forge create` and leaves `SmokeSwapLocal.s.sol` to do calls only.
Root cause not established; the observed constructor-args blob is short by 66 bytes,
which is consistent with forge slicing against the wrong artifact's creation bytecode
(`AquaSwapVMRouterDebug` also exists). Treat that as a hypothesis, not a finding.

## DODO reference file checksums

Verified byte-identical to upstream at the pin above (`make check-upstream` re-verifies):

```text
4d41bb46d60b97a1bc1e43985733ce1050354a15d6a187b16dceab07929927c9  PMMPricing.sol
cd2393bdb50542b082d6abbd9ce88c5e2b80e91dd4732c8217c10147c2b63b5f  DODOMath.sol
48806173e99f16e2728ce25e336e2a1dc2b491226acd8d8e9d73f5259104c5d8  DecimalMath.sol
534db7f95a0b0c4e98bcfc70a4dac8e20ed6ed343f526bcaa91b6ef8f24e1d24  SafeMath.sol
```

## Compiler settings

| Tree | solc | optimizer runs | via-IR | source |
|---|---|---|---|---|
| SwapVM | 0.8.30 | 700 | yes | `contracts/foundry.toml`, `contracts/hardhat.config.ts` |
| Aqua | 0.8.30 | 10,000,000 | yes | `aqua/foundry.toml` |
| DODO reference | 0.6.9 | 200 | no (unsupported pre-0.8.13) | `reference/dodo/foundry.toml` |

The DODO reference is deliberately a **separate Foundry project**. Two reasons:

1. `contracts/hardhat.config.ts` declares only solc 0.8.30. Putting 0.6.9 files under
   `contracts/test/` would break `npx hardhat test solidity`, our authoritative regression command.
2. Keeping it out of `contracts/` keeps the fork diff minimal, which is the point of this file.

Milestone 2 will bridge the two with `vm.getCode()` against `reference/dodo/out/`, so the
differential test runs in one process without either tree being modified.

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
| `contracts/src/bastion/pmm/PMMMath.sol` | **added** | Milestone 2 increments 1-2. Our 0.8.30 port of DODO's PMM (Apache-2.0 derivative work, attribution in the file header). Both directions, all three entry states, `adjustedTarget` and `getMidPrice`. A library of `internal` functions: it adds no deployable bytecode and no Hardhat test, so `make test` stays at 882. |
| `contracts/src/bastion/pmm/Scale.sol` | **added** | Milestone 2 increment 2. Bastion's own (not DODO's): the pinned decimal normalisation behind spec 5.2's `priceWad`. Not in the pricing path — the contract consumes an already-normalised `i`. |
| `contracts/src/bastion/pmm/PMMState.sol` | **added** | Milestone 2 increment 3. Bastion's own transition policy over DODO's pricing: initialisation, gross-input fee reinvestment, explicit recentring. Not a port of any DODO pool — only `PMMPricing`/`DODOMath` are vendored, so no claim is made about how DODO sequences these steps. |
| `contracts/src/libs/OpcodeList.sol` | **MODIFIED** | Milestone 3 increment 1, ladder decision D3a. The FIRST upstream file Bastion modifies. Five previously free enum slots are given names: `0x33 MakerPriceAnchor`, `0x34 MakerBudget`, `0x35 BookMandate`, `0x52 PortfolioSwap`, `0x92 PortfolioLedger`. No existing entry is renamed, reordered or removed, so every upstream opcode keeps its value — upstream's own `OpcodeEnumCheck.t.sol` passes unchanged and `test/bastion/PortfolioSwap.t.sol` pins the five new ones. Naming is required because `InstructionBuilder.pushHeader` takes the `Opcode` enum type. |
| `contracts/src/bastion/desk/DeskStorage.sol` | **added** | M3/i1. The ERC-7201 namespaced slot holding risk groups and book admission — the shared state itself. |
| `contracts/src/bastion/desk/DeskAdmin.sol` | **added** | M3/i1. A DEPLOYED library holding the bodies of the maker-administration calls. Delegatecalled, so it runs in the router's storage context. It exists because of gate D1; see below. |
| `contracts/src/bastion/desk/BastionDesk.sol` | **added** | M3/i1. Thin admin entrypoints and views on the router. |
| `contracts/src/bastion/instructions/PortfolioLedger.sol` | **added** | M3/i1. Wrapper opcode `0x92`: admits the book, then commits the shared PMM state with the GROSS input. |
| `contracts/src/bastion/instructions/PortfolioSwap.sol` | **added** | M3/i1. Leaf opcode `0x52`: prices one exact-in fill from the shared state. |
| `contracts/src/bastion/instructions/MakerPriceAnchor.sol` | **added** | M3/i1. Leaf opcode `0x33`: refuses to trade without a live signed anchor. |
| `contracts/src/bastion/opcodes/BastionOpcodes.sol` | **added** | M3/i1. Overrides `AquaOpcodes._runOpcode` (already `internal virtual`) and falls through to `super`, so `AquaOpcodes.sol` needs no edit. |
| `contracts/src/bastion/routers/BastionAquaSwapVMRouter.sol` | **added** | M3/i1. The only router Bastion books ship to. |
| `contracts/test/bastion/*` | **added** | M3/i1-i2. 31 Hardhat-runnable tests. `make test` is 882 + 31 = 913. |
| `contracts/script/bastion/BastionSmokeLocal.s.sol` | **added** | M3/i2 local-anvil demonstration. Calls only — deploys are done by `scripts/anvil-bastion.sh` because `forge create` works where `forge script` silently drops this router family's broadcast. |

`make check-upstream` reports the additions as `Only in <ours>/{script,src,test}: bastion`
and prints `OpcodeList.sol` as differing. That one differing line is the whole of Bastion's
modification to upstream source. `SwapVM.sol`, `AquaOpcodes.sol`, `AquaSwapVMRouter.sol` and
every upstream instruction remain byte-identical to the pin.

### Gate D1: why two Bastion libraries are deployed separately

EIP-170 caps runtime bytecode at 24,576 bytes. Measured at milestone 3 increment 1, exactly
where the plan required it:

| Router composition | Runtime (B) | Margin |
|---|---|---|
| upstream `AquaSwapVMRouter` | 20,376 | +4,200 |
| + Bastion instructions, PMM math inlined | 23,526 | +1,050 |
| + maker administration inlined | **26,842** | **-2,266 (undeployable)** |
| admin moved to the deployed `DeskAdmin` library | 24,883 | -307 |
| PMM math also deployed (`PMMMath` linked) | **23,404** | **+1,172** |

Both moves keep state where ladder decision D2 put it: an `external` library function is
reached by DELEGATECALL, so `DeskStorage.layout()` still resolves to the router's own slot.
Only code moves. The costs are one delegatecall per administrative call, and one per PMM
math call on the pricing path. `PMMMath.adjustedTarget` had to change from mutating its
memory argument to returning the new targets, because a callee's memory changes do not
survive a delegatecall; the arithmetic is untouched and milestone 2's 60 conformance tests
still pass against the 0.6.9 reference.

Deployment therefore requires linking: `PMMMath` and `DeskAdmin` must be deployed before
`BastionAquaSwapVMRouter`.

Two Bastion test/experiment projects live **outside** `contracts/`, each its own Foundry
project: `experiments/curves/` (the curve premise check) and `conformance/` (gate P1, the
PMM differential test). A test inside `contracts/` that loads a cross-project artifact via
`vm.getCode` fails under Hardhat's resolver and turns `make test` red (882 passing +
1 failing). Keeping both outside also keeps this table to two lines.

### Gotcha: Foundry edits upstream's `.gitignore`

Running `forge script --broadcast` appends `broadcast/` to `contracts/.gitignore`. That
silently un-tracks the 43 upstream deployment records **and** our own smoke-test evidence.
`make check-upstream` catches it; revert the file to the pin when it does.

One upstream file is now **modified**: `libs/OpcodeList.sol`, and only to name free enum
slots (see the table above). `AquaOpcodes.sol`, `SwapVM.sol` and every instruction are still
byte-identical to the pin; `make check-upstream` proves it and prints anything new.
Both `aqua/` and `reference/dodo/lib/` are still byte-identical to their pins as of the
milestone 2 increment 1 run — the DODO check matters most, since a modified reference
would silently invalidate gate P1.

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

Milestone 2 increment 1 bridged the two: `conformance/test/PMMConformance.t.sol` loads
`reference/dodo/out/PMMHarness.sol/PMMHarness.json` with `vm.getCode()` and drives it and
the 0.8.30 port through one identical ABI, so the differential test runs in a single
process with neither tree modified.

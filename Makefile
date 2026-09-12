# Bastion — top-level commands.
# `make help` lists everything. Sub-projects keep their own upstream tooling;
# these targets just call it so you never have to remember which is which.

SHELL := /bin/bash
.DEFAULT_GOAL := help

# contracts/ = SwapVM fork  (Hardhat 3 + Foundry-style .t.sol tests)
# aqua/      = Aqua, unmodified (pure Foundry)
# reference/dodo/ = DODO PMM oracle, unmodified (Foundry, solc 0.6.9)

## setup: install node deps in both vendored trees (run once)
setup:
	cd contracts && yarn install --frozen-lockfile
	cd aqua && yarn install --frozen-lockfile

## build: compile all three trees
build:
	cd aqua && forge build
	cd contracts && forge build
	forge build --root reference/dodo

## test: authoritative regression suite (upstream's own runner, 882 tests)
test:
	cd contracts && npx hardhat test solidity

## test-fast: quick Foundry loop. Excludes 3 tests that fail only under forge
## (see MILESTONES / UPSTREAM.md — runner artifact, they pass under hardhat).
test-fast:
	cd contracts && forge test --no-match-path 'test/TakerCallbackAquaNegative.t.sol'

## test-aqua: Aqua's own suite (50 tests)
test-aqua:
	cd aqua && forge test

## test-all: everything
test-all: test-aqua test conformance

## check-upstream: prove aqua/ + DODO are unmodified and list the SwapVM fork surface
check-upstream:
	./scripts/check-upstream.sh

## anvil: local chain on 127.0.0.1:8545, chainId 31337 (matches contracts/hardhat.config.ts)
anvil:
	anvil --host 127.0.0.1 --port 8545 --chain-id 31337

## smoke: deploy local fixtures on anvil and run one real Aqua-settled swap
smoke:
	./scripts/anvil-smoke.sh

## bastion: deploy the Bastion desk on anvil; one fill on A moves book B's quote
bastion:
	./scripts/anvil-bastion.sh

## boundary: dock the strategy, replay Bob's calldata, expect a real reverted tx
boundary:
	./scripts/anvil-boundary.sh

## demo: smoke + boundary back to back (needs `make anvil` running elsewhere)
demo: smoke boundary

## conformance: gate P1 — the PMM port vs the independently compiled DODO reference
conformance:
	forge build --root reference/dodo
	forge test --root conformance -vv

## curves: the PMM vs XYK vs CLMM premise check (real ETH prices, real Gamma band)
curves:
	forge build --root reference/dodo
	FOUNDRY_GAS_LIMIT=9223372036854775807 forge test --root experiments/curves -vv

## curves-data: download and checksum seven pinned days of ETHUSDT aggregate trades
curves-data:
	python3 scripts/fetch-curve-data.py

## curves-check: offline data and curve boundary tests (market replay is separately invoked)
curves-check:
	python3 -m unittest discover -s experiments/curves -p 'test_data.py' -v
	forge build --root reference/dodo
	FOUNDRY_GAS_LIMIT=9223372036854775807 forge test --root experiments/curves --no-match-test 'test_CurveComparison|test_KSweep|test_FreshnessSweep' -vv

## curves-replay: train on two days, evaluate five untouched days, write numeric report
curves-replay:
	forge build --root reference/dodo
	forge build --root experiments/curves
	python3 scripts/run-curve-replay.py

## clean: drop build output (keeps node_modules)
clean:
	cd contracts && forge clean
	cd aqua && forge clean
	rm -rf reference/dodo/out reference/dodo/cache experiments/curves/out experiments/curves/cache conformance/out conformance/cache

help:
	@echo "Bastion targets:"
	@grep -E '^## ' $(MAKEFILE_LIST) | sed 's/^## /  /'

.PHONY: setup build test test-fast test-aqua test-all check-upstream conformance anvil smoke bastion boundary demo curves curves-data curves-check curves-replay clean help

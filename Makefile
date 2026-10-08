.PHONY: help test test-deep fmt fmt-check manifests bundle apps build clean proof native native-fmt-check publish-testnet publish-personal-mainnet publish-dry-run publish-build test-publisher test-publish-devnet

export RPC FROM NAME REGISTRY NAMES WALLET_COMMAND WALLET_RPC

help:
	@echo "test       forge test (default fuzz runs)"
	@echo "test-deep  forge test with FOUNDRY_FUZZ_RUNS=5000 (fund-holding invariants)"
	@echo "fmt        forge fmt"
	@echo "fmt-check  forge fmt --check (CI parity)"
	@echo "manifests  validate examples/*/manifest.json against eastsea-app/1"
	@echo "apps       regenerate static front-ends under apps/"
	@echo "bundle     print canonical bundle hash for an example (make bundle SLUG=vending)"
	@echo "proof      H1-H11 hazard probes + offline fidelity check (proof/)"
	@echo "native     EastSea-native templates: forge test + fmt check (native/)"
	@echo "publish-testnet  publish caller-owned copies (RPC, FROM, REGISTRY, NAMES; NAME or reverse name)"
	@echo "publish-personal-mainnet  local-only personal instances (RPC, FROM; PUBLISH_ARGS must include --chain-id)"
	@echo "publish-dry-run  offline publishing plan (FROM, optional NAME/PUBLISH_ARGS)"
	@echo "publish-build    compile publisher artifacts under tmp/ (honors shared compile gate)"
	@echo "test-publisher   offline publisher + EIP-1193 + manifest regressions"
	@echo "test-publish-devnet  owned offline devnet + all 17 Chrome smokes (explicit fixture build)"

test:
	cd contracts && forge test

test-deep:
	cd contracts && FOUNDRY_FUZZ_RUNS=5000 forge test

fmt:
	cd contracts && forge fmt

fmt-check:
	cd contracts && forge fmt --check

manifests:
	python3 templates/publish/validate-manifests.py

bundle:
	@test -n "$(SLUG)" || (echo "usage: make bundle SLUG=<example-slug>" && exit 2)
	templates/publish/bundle-hash.sh apps/$(SLUG)

apps:
	python3 scripts/gen-apps.py

proof:
	cd proof && forge test
	python3 proof/fidelity.py
	python3 proof/bench/validate.py

build: test manifests fmt-check

native:
	cd native && forge test
	cd native && forge fmt --check

clean:
	cd contracts && forge clean

publish-testnet:
	python3 scripts/publish.py $(PUBLISH_ARGS)

publish-personal-mainnet:
	python3 scripts/publish.py --network mainnet --personal-test $(PUBLISH_ARGS)

publish-dry-run:
	python3 scripts/publish.py --dry-run $(PUBLISH_ARGS)

publish-build:
	@mkdir -p "$(CURDIR)/tmp"
	@cd contracts && export TMPDIR="$(CURDIR)/tmp" && if [ -f "$(HOME)/.claude/playbooks/aether-team/wait-compile.sh" ]; then bash "$(HOME)/.claude/playbooks/aether-team/wait-compile.sh"; fi && forge build --out ../tmp/publish-artifacts --cache-path ../tmp/publish-forge-cache

test-publisher:
	PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s tests -p 'test_publish*.py' -v
	python3 scripts/check-apps.py
	python3 templates/publish/validate-manifests.py

test-publish-devnet:
	python3 scripts/test-publish-devnet.py --build-fixtures $(DEVNET_ARGS)

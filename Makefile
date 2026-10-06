.PHONY: help test test-deep fmt fmt-check manifests bundle apps build clean proof

help:
	@echo "test       forge test (default fuzz runs)"
	@echo "test-deep  forge test with FOUNDRY_FUZZ_RUNS=5000 (fund-holding invariants)"
	@echo "fmt        forge fmt"
	@echo "fmt-check  forge fmt --check (CI parity)"
	@echo "manifests  validate examples/*/manifest.json against eastsea-app/1"
	@echo "apps       regenerate static front-ends under apps/"
	@echo "bundle     print canonical bundle hash for an example (make bundle SLUG=vending)"
	@echo "proof      H1-H11 hazard probes + offline fidelity check (proof/)"

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

clean:
	cd contracts && forge clean

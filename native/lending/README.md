# lending: personal mainnet testing boundary

<!-- i18n: personal_test.unavailable personal_test.mainnet -->

This item is a [design](DESIGN.md), with no executable contract or publisher
recipe in this repository. It cannot be deployed by the current toolbox.
A future implementation must support the same [personal deployment policy](../../docs/personal-mainnet-testing.md):
wallet-owned allowlist, small immutable admitted-value caps, zero protocol
fee, no administrator withdrawal of others' funds, and an on-chain
`personal-test` marker. Testnet may have a shared test-coin demo; mainnet
must use each person's own private instance and local frontend.

Use the guarded AMM, locks or native escrow to rehearse the currently
implemented flows; this does not constitute a lending or yield-vault test.

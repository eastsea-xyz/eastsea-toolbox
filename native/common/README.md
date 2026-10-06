# native/common: shared pieces for the Lane B templates

- `src/INativeBrake.sol`, `src/NativeBrake.sol`: the local deterministic entry brake of [PRIMITIVES M2](../PRIMITIVES.md#capability-and-dependency-register). Guardian is always zero; the brake is a predicate over on-chain facts, anyone may latch it while the predicate holds, the latch is permanent, and it closes new entry only. **Lane A0's shared brake file did not exist when B0-B2 were written, so the interface is defined here from the designs. Reconcile with A0 when it lands.** The `since` value is a block height, not a timestamp (the older `contracts/src/system/IEastSeaBrake.sol` documents seconds and a guardian key; native templates do not use it).
- `src/ExactToken.sol`: exact-transfer movement. Pulls and pushes are checked by balance deltas on both sides; fee-on-transfer, no-op "true" and false-returning tokens revert the whole call.
- `src/TransientLock.sol`: reentrancy lock in transient storage, so it never occupies a paid slot.
- `test/Tokens.sol`: adversarial test tokens (fee, lying, blocking, false-return, callback). `test/SlotDiff.sol`: final-diff slot occupancy for layout tests. Neither is the EastSea executor meter.

Build and test from this folder's parent: `cd native && forge test`.

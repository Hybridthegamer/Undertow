# Evidence

All evidence is reproducible from the pinned public source revision of this repository.

## Build configuration
- forge 1.7.1 · Solidity 0.8.26 · EVM Cancun · optimizer enabled, 1000 runs · `via_ir = false` · `bytecode_hash = none`
  · `cbor_metadata = false` · `ffi = false`.
- Restore pinned dependencies with `script/bootstrap.sh` (exact SHAs in `submissions/undertow/dependency-lock.json`).

## Source under review
- `src/Undertow.sol` — the single fee-enforcing hook.

## Dependency baseline (exact SHAs)
- Uniswap v4-core `59d3ecf53afa9264a16bba0e38f4c5d2231f80bc`
- Uniswap v4-periphery `ad04c9f24a170accf5ea1b2836bbafd514537ca6`
- OpenZeppelin uniswap-hooks `26dc8e53f812a1ca390d470342adb6cd8c3286ad`
- OpenZeppelin contracts `21c8312b022f495ebe3621d5daeed20552b43ff9`
- Permit2 `cc56ad0f3439c502c246fc5cfcc3db92bb8b7219` · forge-std `3b20d60d14b343ee4f908cb8079495c07f5e8981`

## Tests
- Command: `forge test` (fork suite: `MAINNET_RPC_URL=<rpc> forge test`).
- Result: **19 passed, 0 failed, 0 skipped** across 4 suites.
- Invariants: 256 runs × 64 depth = **16,384 calls** each, **0 reverts**, on both `invariant_*` properties.
- Mainnet fork: `test_fork_platformFeeAndSolvency` passes against PoolManager
  `0x000000000004444c5dc75cB358380D2e3dE08A90` at recent head (block ≈ 25,705,061).

## Static analysis (Slither)
- Slither 0.x on `src/Undertow.sol`: **no model-owned findings of consequence.** All detector hits are in the pinned
  dependencies (`lib/`) — solc-version pragmas, too-many-digits, naming — except:
  - `unimplemented-functions` on `getHookPermissions()` — **false positive**: the function is implemented as
    `public pure override`; Slither mis-attributes the `virtual` base declaration.
- No reentrancy, arbitrary-call, delegatecall, selfdestruct, unchecked-transfer, or tx.origin findings on the model.

## Disposition notes
- The unused-constant warning on `MAX_LP_FEE` was resolved by exposing it as a `public constant` (a getter uses it).
- No finding was deleted; dependency findings are separated from model-owned analysis per the security-and-evidence
  workflow.

## Not claimed
Independent audit, deployment, live collection, routing approval, and availability are separate and not claimed here.

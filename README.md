# Undertow

[![ci](https://github.com/Hybridthegamer/Undertow/actions/workflows/ci.yml/badge.svg)](https://github.com/Hybridthegamer/Undertow/actions/workflows/ci.yml)
[![license: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](./LICENSE)

**An LVR-recapture launch hook for Uniswap v4 — a submission to the [Programmable](https://github.com/0xprogrammable/programmable) Custom Hook Hookathon.**

Built through the mandatory Programmable v4 Builder skill (`gh skill install 0xprogrammable/programmable
programmable-v4-hook-builder`) — see [`submissions/undertow/SKILL_FLOW.md`](submissions/undertow/SKILL_FLOW.md). Every
test claim below is reproducible via CI (the badge above) and committed, hashed evidence artifacts.

Undertow's canonical pool recaptures **loss-versus-rebalancing (LVR)** for its own liquidity providers — oracle-free and
keeper-free — while enforcing the mandatory Programmable **10 bps** volume fee non-bypassably on the same pool.

The longer a pool sits untraded, the further the fair price drifts, and the larger the next arbitrage that realigns it
([Milionis, Moallemi, Roughgarden & Zhang, arXiv:2208.06046](https://arxiv.org/abs/2208.06046) — the arbitrageur's
profit *is* the LPs' LVR). Undertow prices that staleness into a dynamic LP fee that spikes on the realigning swap and
is routed to in-range LPs by the v4 core's own fee-growth accounting. Staleness (elapsed blocks) is a
manipulation-resistant, purely on-chain LVR proxy — no external price, no keeper.

- **Hook:** [`src/Undertow.sol`](src/Undertow.sol)
- **Proposal:** [`submissions/undertow/PROPOSAL.md`](submissions/undertow/PROPOSAL.md)
- **Threat model:** [`submissions/undertow/THREAT_MODEL.md`](submissions/undertow/THREAT_MODEL.md)
- **Tests / evidence:** [`TEST_PLAN.md`](submissions/undertow/TEST_PLAN.md) · [`EVIDENCE.md`](submissions/undertow/EVIDENCE.md)

## Build & test

```sh
./script/bootstrap.sh          # restore pinned dependencies (exact SHAs)
forge test                     # 19 tests
MAINNET_RPC_URL=<rpc> forge test   # includes the mainnet-fork rehearsal
```

Foundry (forge 1.7.1), Solidity 0.8.26, EVM Cancun, optimizer 1000 runs, `via_ir = false`, no CBOR metadata — the
Programmable-tested baseline.

## Status

Builder proposal + prototype for maintainer review. **Not** accepted, audited, routed, deployed, or available.

## License

MIT.

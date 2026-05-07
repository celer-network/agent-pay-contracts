# Celer AgentPay state-channel contracts

Smart contracts for **Celer AgentPay** — a generalized state-channel payment network
that enables real-time, trust-free micropayments between AI agents, decentralized
services, and human users.

This repo contains the on-chain L1 contract suite. Almost all activity happens
off-chain via co-signed simplex states; the chain is touched only for deposits,
withdrawals, settlement, and dispute resolution. For the full architecture — design
principles, data structures, off-chain protocols, app channels — see the canonical
docs:

- 📖 [agentpay-docs.celer.network](https://agentpay-docs.celer.network/)

A condensed in-repo orientation lives at [`docs/architecture-summary.md`](docs/architecture-summary.md).

---

## Quick Start

```bash
# Install submodule dependencies (forge-std, openzeppelin)
git submodule update --init --recursive

# Build
forge build

# Test
forge test

# Format / lint
forge fmt
forge lint
```

Verified with `forge 1.3.5-stable`. See [foundry.toml](foundry.toml) for compiler /
optimizer settings.

---

## Components

Six top-level contracts in [`src/`](src/), grouped by role:

### Asset custody (permanent, audited, not versioned)

- **[CelerWallet](src/CelerWallet.sol)** — Multi-owner / multi-token wallet shared by
  the whole network; the only contract that holds funds. Operated by a `CelerLedger`.
- **[PayRegistry](src/PayRegistry.sol)** — Append-only global record of resolved
  conditional-payment results, indexed by `payId = keccak256(payHash, setterAddress)`.
- **[VirtContractResolver](src/VirtContractResolver.sol)** — On-demand deployer for
  virtual (off-chain) contracts when disputes need them on-chain.

`CelerLedger` additionally depends on the chain's canonical wrapped-native
(WETH9-style) contract for the multi-party-funding path on native channels —
wired at deploy time via the `_nativeWrap` constructor argument. Users still
deposit and receive native; wrapped-native is internal plumbing only.

### Channel & payment logic (versioned, peer-controlled migration)

- **[CelerLedger](src/CelerLedger.sol)** — Channel state machine and primary user entry
  point; operator of `CelerWallet`. Logic split across libraries in
  [`src/lib/ledgerlib/`](src/lib/ledgerlib/).
- **[PayResolver](src/PayResolver.sol)** — On-chain resolution of conditional payments;
  evaluates conditions or vouched results and writes outcomes to `PayRegistry`.

### Networking

- **[RouterRegistry](src/RouterRegistry.sol)** — Optional registry where relay-router
  operators advertise themselves.

For per-contract APIs, constructor args, events, and storage, see
[`docs/contracts.md`](docs/contracts.md).

---

## Structure

```
src/
├── CelerLedger.sol           # channel state machine; primary entry point (versioned)
├── CelerLedgerMock.sol       # test-only ledger variant
├── CelerWallet.sol           # multi-owner asset custodian (permanent)
├── PayRegistry.sol           # global resolved-payment registry (permanent)
├── PayResolver.sol           # conditional-pay resolution (versioned)
├── RouterRegistry.sol        # optional relay-router registry
├── VirtContractResolver.sol  # on-demand virtual-contract deployer
├── helper/                   # test fixtures (mocks + sample ERC20) — NOT production
├── interfaces/              # I*.sol — public ABI surface
└── lib/
    ├── data/                 # auto-generated protobuf decoders + .proto sources
    └── ledgerlib/            # CelerLedger logic split into libraries (EIP-170 size-split)

test/                         # Foundry tests
script/                       # Forge deploy scripts (TBD)
lib/                          # git submodules: forge-std, openzeppelin
```

`broadcast/`, `cache/`, `out/`, `deployments/`, `.env`, `.mcp.json`, `.vscode/` are
gitignored.

---

## Documentation

| Document | Purpose |
|---|---|
| [docs/architecture-summary.md](docs/architecture-summary.md) | One-page on-chain orientation; links into the full architecture docs. |
| [docs/contracts.md](docs/contracts.md) | Per-contract API reference (constructor, functions, events, storage). |

---

## Supported tokens

Native (e.g. ETH) and **plain ERC-20** only. Tokens whose `transferFrom`
delivers anything other than the requested amount — fee-on-transfer,
deflationary, rebasing, ERC-777 with hooks, etc. — are **not supported**:
channel accounting credits the requested amount, so any actual-vs-requested
mismatch will desync the wallet's internal balance from its real token
holdings.

---

## Dependencies

| Package | Version | Purpose |
|---|---|---|
| [forge-std](https://github.com/foundry-rs/forge-std) | latest | Testing & scripting |
| [openzeppelin-contracts](https://github.com/OpenZeppelin/openzeppelin-contracts) | release-v5.3 | Access control, ERC-20, ECDSA, Pausable |

Pinned via git submodules; see [.gitmodules](.gitmodules).

---

## Toolchain

- [Foundry](https://book.getfoundry.sh) (`forge`, `cast`, `anvil`)
- Solidity `^0.8.20` (see `pragma` in [src/](src/))
- Optimizer enabled, `runs = 200` ([foundry.toml](foundry.toml))

---

## License

MIT — see [LICENSE](LICENSE).
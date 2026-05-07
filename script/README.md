# Deployment Guide

Foundry deploy scripts for AgentPay, split by lifecycle so a network can be brought
up incrementally and new ledger / resolver versions can be deployed against an
existing core without touching the asset-custody contracts.

## Prerequisites

- [Foundry](https://book.getfoundry.sh/getting-started/installation) installed
- RPC URL for the target network
- Deployer private key with sufficient native gas
- Block-explorer API key for verification (optional, used by `--verify`)

## Scripts

| Script | Deploys | Lifecycle |
|---|---|---|
| [`DeployCore.s.sol`](DeployCore.s.sol) | `PayRegistry`, `VirtContractResolver`, `CelerWallet` | Once per network. Permanent — never redeployed. |
| [`DeployLedger.s.sol`](DeployLedger.s.sol) | `CelerLedger` (+ 4 ledger libraries; see below) | Versioned. Run again for each new ledger version; peers cooperatively migrate. |
| [`DeployPayResolver.s.sol`](DeployPayResolver.s.sol) | `PayResolver` | Versioned per-payment. Run when adding a new resolver. |
| [`DeployRouterRegistry.s.sol`](DeployRouterRegistry.s.sol) | `RouterRegistry` | Optional. Independent of the channel graph. |

## How the libraries are deployed

`CelerLedger` is split across five Solidity `library` contracts under
[`src/lib/ledgerlib/`](../src/lib/ledgerlib/) (forced by EIP-170's 24,576-byte
deployed-bytecode limit — see
[`docs/contracts.md` § Why split into libraries?](../docs/contracts.md#why-split-into-libraries)).
The deploy script doesn't mention them by name, but they **are** deployed — Foundry
handles it implicitly:

1. The Solidity compiler emits **20-byte zero placeholders** in `CelerLedger`'s
   bytecode wherever a library function is called, recording each placeholder offset
   in `out/CelerLedger.sol/CelerLedger.json` under `bytecode.linkReferences`.
2. When `forge script` evaluates `new CelerLedger(...)`, it walks the link references,
   **deploys each library as its own contract** (one transaction each), and **patches
   the placeholders** in `CelerLedger`'s bytecode with the freshly-deployed library
   addresses.
3. The now-linked `CelerLedger` is deployed last.

So a single `forge script script/DeployLedger.s.sol --broadcast` call actually emits
**5 deployment transactions** in this order: `LedgerOperation`, `LedgerChannel`,
`LedgerMigrate`, `LedgerBalanceLimit`, then `CelerLedger`. All five appear in the
broadcast log under
`broadcast/DeployLedger.s.sol/<chainId>/run-latest.json` (see
[Broadcast outputs](#broadcast-outputs) below).

Library calls happen via `DELEGATECALL`, so the libraries execute in `CelerLedger`'s
storage context — they're code on a separate address but operate on `CelerLedger`'s
state.

### Etherscan verification

`forge verify-contract` (and `forge script ... --verify`) need the library addresses
to reproduce the linked bytecode. When verification is run as part of the same
`forge script ... --broadcast --verify` invocation, Foundry passes the addresses it
just deployed automatically. To verify after the fact, supply them explicitly:

```bash
forge verify-contract <CELER_LEDGER_ADDR> CelerLedger \
  --chain-id <CHAIN_ID> \
  --libraries src/lib/ledgerlib/LedgerOperation.sol:LedgerOperation:<ADDR> \
  --libraries src/lib/ledgerlib/LedgerChannel.sol:LedgerChannel:<ADDR> \
  --libraries src/lib/ledgerlib/LedgerMigrate.sol:LedgerMigrate:<ADDR> \
  --libraries src/lib/ledgerlib/LedgerBalanceLimit.sol:LedgerBalanceLimit:<ADDR> \
  --watch
```

### Sharing libraries across ledger versions (optional)

By default each `DeployLedger` run **redeploys all four libraries** — fine for a
clean version cut, wasteful if you're iterating. To pin already-deployed library
addresses and link `CelerLedger` against them at compile time, add to `foundry.toml`:

```toml
[profile.default]
libraries = [
  "src/lib/ledgerlib/LedgerOperation.sol:LedgerOperation:0x...",
  "src/lib/ledgerlib/LedgerChannel.sol:LedgerChannel:0x...",
  "src/lib/ledgerlib/LedgerMigrate.sol:LedgerMigrate:0x...",
  "src/lib/ledgerlib/LedgerBalanceLimit.sol:LedgerBalanceLimit:0x...",
]
```

With those set, `forge build` resolves the link references at compile time and
`forge script` emits exactly **one** transaction (`new CelerLedger(...)`) instead of
five. Most production deploys won't bother — re-deploying ~30 KB of library bytecode
costs a few hundred thousand gas, which is negligible against the audit / coordination
cost of pinning shared libraries across ledger versions.

## Quick start (fresh network)

```bash
# 1. Copy and fill in env + config
cp script/.env.example script/.env             # private key, RPC URL, optional verify key
cp script/example_config.json config.json      # addresses (filled in across deploy steps)

# 2. Load the env into the shell
set -a; source script/.env; set +a

# 3. Deploy the permanent core contracts
forge script script/DeployCore.s.sol --rpc-url $RPC_URL --broadcast --verify -vv

# 4. Paste the three addresses from step 3 into config.json's `core` block,
#    plus the chain's canonical `nativeWrap` (wrapped-native) address — see
#    `example_config.json` for canonical values per chain.

# 5. Deploy the first ledger and resolver
forge script script/DeployLedger.s.sol --rpc-url $RPC_URL --broadcast --verify -vv
forge script script/DeployPayResolver.s.sol --rpc-url $RPC_URL --broadcast --verify -vv

# 6. (Optional) Deploy the router registry
forge script script/DeployRouterRegistry.s.sol --rpc-url $RPC_URL --broadcast --verify -vv
```

## Adding a new ledger or resolver later

Peer-controlled migration means a new `CelerLedger` is just a fresh deploy pointing at
the same core contracts. Likewise, a new `PayResolver` is a fresh deploy that future
`ConditionalPay` messages can pin via field 8.

```bash
# New ledger version
forge script script/DeployLedger.s.sol --rpc-url $RPC_URL --broadcast --verify -vv

# New resolver version
forge script script/DeployPayResolver.s.sol --rpc-url $RPC_URL --broadcast --verify -vv
```

After deploy, coordinate off-chain so peers know the new addresses and can co-sign a
migration request (for the ledger) or include the new resolver in their accepted list
(for `PayResolver`).

## Post-deployment checklist

After **`DeployCore`**:

1. Decide whether to keep the deployer as `CelerWallet` owner, or transfer to a
   security multisig:
   ```bash
   cast send <CELER_WALLET> "transferOwnership(address)" <MULTISIG> --rpc-url $RPC_URL --private-key $PRIVATE_KEY
   ```
   The owner can `pause` / `unpause` and (when paused) `drainToken` for emergency
   recovery — pick the holder accordingly.

After **`DeployLedger`**:

1. Configure per-token deposit caps **or** disable the limit. The ledger ships with
   balance limits **enabled by default** but no limits set — every deposit will
   revert until you do one of:
   ```bash
   # Option A: set caps for the tokens you'll use (address(0) = native)
   cast send <CELER_LEDGER> "setBalanceLimits(address[],uint256[])" "[0x0000000000000000000000000000000000000000]" "[1000000000000000000000]" --rpc-url $RPC_URL --private-key $PRIVATE_KEY

   # Option B: disable limits entirely
   cast send <CELER_LEDGER> "disableBalanceLimits()" --rpc-url $RPC_URL --private-key $PRIVATE_KEY
   ```
2. Optionally transfer ledger ownership to the same multisig.

After **`DeployPayResolver`**:

1. No on-chain configuration needed — the address is referenced per-payment by the
   payment source. Distribute the new resolver's address to off-chain node operators
   so they can add it to their accepted-resolver list.

After **`DeployRouterRegistry`**:

1. No on-chain configuration needed. Routers self-register via `registerRouter()`.

## Configuration

The `DeployLedger` and `DeployPayResolver` scripts read addresses from a JSON config
at `config.json` (default), or any path set in the `DEPLOY_CONFIG` env var:

```bash
export DEPLOY_CONFIG=./deploys/sepolia.json
forge script script/DeployLedger.s.sol --rpc-url $RPC_URL --broadcast -vv
```

The committed [`example_config.json`](example_config.json) is the schema reference;
copy it to `config.json` (gitignored) and fill in.

## Broadcast outputs

Per-script artifacts (transaction hashes, deployed addresses, gas) are saved to:

```
broadcast/<ScriptName>.s.sol/<chainId>/run-latest.json
```

`broadcast/` is gitignored; check it in only if you want a per-network audit trail.

## Verification

`--verify` triggers Etherscan-style verification automatically. Requires
`ETHERSCAN_API_KEY` (or the appropriate per-chain variant) in the environment. To
verify retroactively:

```bash
forge verify-contract <ADDRESS> <ContractName> --chain-id <CHAIN_ID> --watch
```

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
| [`DeployCore.s.sol`](DeployCore.s.sol) | `EthPool`, `PayRegistry`, `VirtContractResolver`, `CelerWallet` | Once per network. Permanent — never redeployed. |
| [`DeployLedger.s.sol`](DeployLedger.s.sol) | `CelerLedger` | Versioned. Run again for each new ledger version; peers cooperatively migrate. |
| [`DeployPayResolver.s.sol`](DeployPayResolver.s.sol) | `PayResolver` | Versioned per-payment. Run when adding a new resolver. |
| [`DeployRouterRegistry.s.sol`](DeployRouterRegistry.s.sol) | `RouterRegistry` | Optional. Independent of the channel graph. |

## Quick start (fresh network)

```bash
# 1. Copy and fill in env + config
cp script/.env.example script/.env             # private key, RPC URL, optional verify key
cp script/example_config.json config.json      # addresses (filled in across deploy steps)

# 2. Load the env into the shell
set -a; source script/.env; set +a

# 3. Deploy the permanent core contracts
forge script script/DeployCore.s.sol --rpc-url $RPC_URL --broadcast --verify -vv

# 4. Paste the four addresses from step 3 into config.json's `core` block

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
   # Option A: set caps for the tokens you'll use (address(0) = ETH)
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

# Contracts API Reference

Per-contract reference for the on-chain layer of Celer AgentPay. For high-level
context, read [`architecture-summary.md`](architecture-summary.md) first. For per-function
details (parameters, semantics, edge cases), follow the source links — NatSpec in the
contract file is authoritative.

## Table of Contents

- [CelerWallet](#celerwallet)
- [CelerLedger](#celerledger)
- [PayResolver](#payresolver)
- [PayRegistry](#payregistry)
- [VirtContractResolver](#virtcontractresolver)
- [EthPool](#ethpool)
- [RouterRegistry](#routerregistry)
- [Ledger libraries](#ledger-libraries) (where the channel logic actually lives)
- [Helpers and mocks](#helpers-and-mocks)

---

## CelerWallet

[Source](../src/CelerWallet.sol) · [Interface](../src/lib/interface/ICelerWallet.sol) · **Permanent** (not versioned)

Multi-owner, multi-token wallet that holds the funds for every channel in the network.
A single `CelerWallet` instance is shared globally; every `CelerLedger` (current or
future versions) is an *operator* over individual wallets within it. The contract has
deliberately minimal logic — it only knows how to deposit, withdraw, and transfer
operatorship — to keep the audit surface small.

### Constructor

```solidity
constructor() Ownable(msg.sender)
```

No parameters. Inherits `Ownable` (deployer is initial owner) and `Pausable`. The owner
can `pause` / `unpause` and (when paused) `drainToken` to recover stuck funds.

### Roles

- **Owners** — the channel peers; receive withdrawals and vote on operator proposals.
- **Operator** — exactly one per wallet; the `CelerLedger` instance authorized to move
  funds. Operatorship is the migration pivot point.
- **Contract owner** (Ownable) — can pause / unpause and drain when paused.

### External / public functions

| Function | Caller | Purpose |
|---|---|---|
| [`create`](../src/CelerWallet.sol#L66) | anyone (typically a `CelerLedger`) | Create a new wallet for a peer-pair, returning its `walletId`. |
| [`depositETH`](../src/CelerWallet.sol#L89) | anyone (payable) | Deposit native ETH into a wallet. |
| [`depositERC20`](../src/CelerWallet.sol#L101) | anyone | Deposit ERC-20 tokens (requires prior `approve`). |
| [`withdraw`](../src/CelerWallet.sol#L119) | operator only | Withdraw funds to a receiver. |
| [`transferToWallet`](../src/CelerWallet.sol#L141) | operator only | Move funds between two wallets sharing the same operator (channel rebalancing). |
| [`transferOperatorship`](../src/CelerWallet.sol#L164) | current operator | Transfer operatorship to a new operator (the migration path). |
| [`proposeNewOperator`](../src/CelerWallet.sol#L179) | wallet owner | Propose a new operator; takes effect when *all* owners propose the same address (manual fallback for stuck migrations). |
| [`drainToken`](../src/CelerWallet.sol#L207) | contract owner, when paused | Emergency token recovery. |
| `pause` / `unpause` | contract owner | Pause guard for deposits / withdrawals / operator changes. |
| `getWalletOwners` / `getOperator` / `getBalance` / `getProposedNewOperator` / `getProposalVote` | view | Wallet introspection. |

### Events

`CreateWallet`, `DepositToWallet`, `WithdrawFromWallet`, `TransferToWallet`,
`ChangeOperator`, `ProposeNewOperator`, `DrainToken`. See
[`ICelerWallet.sol`](../src/lib/interface/ICelerWallet.sol).

### Storage

```solidity
struct Wallet {
    address[] owners;
    address operator;
    mapping(address => uint256) balances;            // tokenAddr (0 = ETH) → balance
    address proposedNewOperator;
    mapping(address => bool) proposalVotes;
}
uint256 public walletNum;
mapping(bytes32 => Wallet) private wallets;
```

---

## CelerLedger

[Source](../src/CelerLedger.sol) · [Interface](../src/lib/interface/ICelerLedger.sol) · **Versioned**

The channel state machine and primary user entry point. The contract itself is a thin
wrapper — the actual logic is split across five libraries under
[`src/lib/ledgerlib/`](../src/lib/ledgerlib/) and attached via `using ... for ...`. See
[Ledger libraries](#ledger-libraries) below.

### Constructor

```solidity
constructor(address _ethPool, address _payRegistry, address _celerWallet) Ownable(msg.sender)
```

| Param | Purpose |
|---|---|
| `_ethPool` | Address of the deployed [`EthPool`](#ethpool). |
| `_payRegistry` | Address of the deployed [`PayRegistry`](#payregistry). |
| `_celerWallet` | Address of the deployed [`CelerWallet`](#celerwallet). |

Balance limits are **enabled by default** post-deployment. Configure them via
`setBalanceLimits` or call `disableBalanceLimits` for unlimited per-channel deposits.

### External functions — channel lifecycle

| Function | Purpose |
|---|---|
| [`openChannel`](../src/CelerLedger.sol#L66) | Open a fully-funded channel from a co-signed `PaymentChannelInitializer` (single tx). |
| [`deposit`](../src/CelerLedger.sol#L78) | Deposit ETH (msg.value) and/or pull from `EthPool`/ERC20 into a channel. |
| [`depositInBatch`](../src/CelerLedger.sol#L91) | Batch deposit across multiple channels in one tx. |
| [`snapshotStates`](../src/CelerLedger.sol#L114) | Persist a co-signed simplex state on-chain (lightweight checkpoint). |

### External functions — withdrawals

| Function | Purpose |
|---|---|
| [`cooperativeWithdraw`](../src/CelerLedger.sol#L153) | Single-tx withdrawal with a co-signed `CooperativeWithdrawInfo`. |
| [`intendWithdraw`](../src/CelerLedger.sol#L126) | Start a unilateral withdrawal challenge window. |
| [`vetoWithdraw`](../src/CelerLedger.sol#L145) | Counterparty cancels an in-flight unilateral withdrawal. |
| [`confirmWithdraw`](../src/CelerLedger.sol#L135) | Finalize a unilateral withdrawal after the window closes. |

### External functions — settlement

| Function | Purpose |
|---|---|
| [`cooperativeSettle`](../src/CelerLedger.sol#L192) | Single-tx close with a co-signed `CooperativeSettleInfo`. |
| [`intendSettle`](../src/CelerLedger.sol#L165) | Start unilateral settlement using the latest co-signed simplex states. |
| [`clearPays`](../src/CelerLedger.sol#L175) | Settle additional pending pays via a `PayIdList` after `intendSettle`. |
| [`confirmSettle`](../src/CelerLedger.sol#L184) | Finalize unilateral settlement after the challenge window. |

### External functions — migration (decentralized versioning)

| Function | Purpose |
|---|---|
| [`migrateChannelFrom`](../src/CelerLedger.sol#L210) | Called on the **new** ledger; orchestrates the migration end-to-end. |
| [`migrateChannelTo`](../src/CelerLedger.sol#L201) | Called on the **old** ledger by the new one; transfers operatorship and exposes state. |

### External functions — admin

| Function | Caller | Purpose |
|---|---|---|
| `setBalanceLimits` | `Ownable` owner | Set per-token per-channel deposit caps. |
| `enableBalanceLimits` / `disableBalanceLimits` | `Ownable` owner | Toggle the balance-limit gate globally. |

### View functions

A wide set of getters: `getChannelStatus`, `getTokenContract`, `getTokenType`,
`getTotalBalance`, `getBalanceMap`, `getStateSeqNumMap`, `getTransferOutMap`,
`getNextPayIdListHashMap`, `getLastPayResolveDeadlineMap`, `getPendingPayOutMap`,
`getWithdrawIntent`, `getCooperativeWithdrawSeqNum`, `getSettleFinalizedTime`,
`getDisputeTimeout`, `getMigratedTo`, `getChannelMigrationArgs`,
`getPeersMigrationInfo`, `getChannelStatusNum`, `getEthPool`, `getPayRegistry`,
`getCelerWallet`, `getBalanceLimit`, `getBalanceLimitsEnabled`. See
[`ICelerLedger.sol`](../src/lib/interface/ICelerLedger.sol).

### Events

Open/Deposit/Snapshot: `OpenChannel`, `Deposit`, `SnapshotStates`.
Withdraw: `IntendWithdraw`, `ConfirmWithdraw`, `VetoWithdraw`, `CooperativeWithdraw`.
Settle: `IntendSettle`, `ClearOnePay`, `ConfirmSettle`, `ConfirmSettleFail`,
`CooperativeSettle`. Migration: `MigrateChannelFrom`, `MigrateChannelTo`.

### Storage

```solidity
LedgerStruct.Ledger private ledger;
// → channelStatusNums, ethPool, payRegistry, celerWallet,
//   balanceLimits, balanceLimitsEnabled, channelMap (bytes32 → Channel)
```

See [`LedgerStruct.sol`](../src/lib/ledgerlib/LedgerStruct.sol) for the full layout.

---

## PayResolver

[Source](../src/PayResolver.sol) · [Interface](../src/lib/interface/IPayResolver.sol) · **Versioned** (chosen per-payment)

On-chain conditional-payment resolution. Payment senders embed the resolver address in
field 8 of `ConditionalPay`, which means each payment is tightly bound to a specific
resolver version (the resolver address goes into `payID = keccak256(payHash, resolver)`).

### Constructor

```solidity
constructor(address _registryAddr, address _virtResolverAddr)
```

| Param | Purpose |
|---|---|
| `_registryAddr` | Address of the [`PayRegistry`](#payregistry). |
| `_virtResolverAddr` | Address of the [`VirtContractResolver`](#virtcontractresolver). |

### External functions

| Function | Purpose |
|---|---|
| [`resolvePaymentByConditions`](../src/PayResolver.sol#L44) | Evaluate every condition (hash-locks via preimages, deployed/virtual contracts via `isFinalized`+`getOutcome`), apply the `transfer_func`, write to `PayRegistry`. Reverts if any condition is not finalized. |
| [`resolvePaymentByVouchedResult`](../src/PayResolver.sol#L71) | Bypass condition evaluation by accepting a result co-signed by `pay.src` and `pay.dest`; capped at `pay.transferFunc.maxTransfer.receiver.amt`. |

### Resolution rules

- A payment must be resolved before `pay.resolveDeadline` (block number).
- A result equal to the maximum-transfer amount **finalizes immediately** — no challenge
  window.
- A partial result opens a challenge window of length `pay.resolveTimeout`. During the
  window the result may be **raised** (never lowered), protecting relay nodes against
  collusive source/dest pairs.
- Supported transfer functions: `BOOLEAN_AND`, `BOOLEAN_OR`, `NUMERIC_ADD`,
  `NUMERIC_MAX`, `NUMERIC_MIN`. (`BOOLEAN_CIRCUIT` is reserved in the protobuf but not
  yet implemented — `assert(false)` on encounter.)
- Hash-lock conditions must always evaluate `true`; their role is multi-hop secret
  unlocking, not transfer-amount gating.

### Events

`ResolvePayment(bytes32 payId, uint256 amount, uint256 resolveDeadline)` from this
contract; `PayInfoUpdate` emitted on the registry as a side effect.

---

## PayRegistry

[Source](../src/PayRegistry.sol) · [Interface](../src/lib/interface/IPayRegistry.sol) · **Permanent**

Global mapping `payId → (amount, deadline)`. Append-only; any contract can be a setter
because the `payId` derivation `keccak256(payHash, msg.sender)` namespaces results by
setter address.

### Constructor

No constructor (no state to initialize).

### External / public functions

| Function | Purpose |
|---|---|
| [`calculatePayId`](../src/PayRegistry.sol#L25) | Pure helper: `keccak256(payHash, setter)`. |
| [`setPayAmount`](../src/PayRegistry.sol#L29) | Setter writes the resolved amount under its own namespace. |
| [`setPayDeadline`](../src/PayRegistry.sol#L37) | Setter writes the resolve deadline under its own namespace. |
| [`setPayInfo`](../src/PayRegistry.sol#L45) | Combined `setPayAmount` + `setPayDeadline`. |
| [`setPayAmounts`](../src/PayRegistry.sol#L54) / [`setPayDeadlines`](../src/PayRegistry.sol#L68) / [`setPayInfos`](../src/PayRegistry.sol#L82) | Batched variants. |
| [`getPayAmounts`](../src/PayRegistry.sol#L107) | Bulk read for settlement (verifies each pay's deadline ≤ a per-channel `lastPayResolveDeadline`). |
| [`getPayInfo`](../src/PayRegistry.sol#L126) | Single-pay read. |
| `payInfoMap` (auto-getter) | Public mapping accessor. |

### Events

`PayInfoUpdate(bytes32 indexed payId, uint256 amount, uint256 resolveDeadline)`.

### Storage

```solidity
struct PayInfo { uint256 amount; uint256 resolveDeadline; }
mapping(bytes32 => PayInfo) public payInfoMap;
```

---

## VirtContractResolver

[Source](../src/VirtContractResolver.sol) · [Interface](../src/lib/interface/IVirtContractResolver.sol) · **Permanent**

Materializes off-chain "virtual" contracts on-chain when a dispute requires it. The
virtual address (used in `Condition.virtual_contract_address`) is
`keccak256(code, nonce)`; deployment uses the `CREATE` opcode.

### External functions

| Function | Purpose |
|---|---|
| [`deploy`](../src/VirtContractResolver.sol#L20) | Deploy bytecode under the (code, nonce) virtual address; reverts if already deployed. |
| [`resolve`](../src/VirtContractResolver.sol#L40) | Look up the deployed address for a virtual address. |

### Events

`Deploy(bytes32 indexed virtAddr)`.

---

## EthPool

[Source](../src/EthPool.sol) · [Interface](../src/lib/interface/IEthPool.sol) · **Permanent**

ERC-20-shaped wrapper for native ETH. Used so that `CelerLedger.openChannel` and
`deposit` can pull funds via a uniform `transferFrom` flow regardless of token type.
Etherscan-friendly metadata: `name = "EthInPool"`, `symbol = "EthIP"`, `decimals = 18`.

### External / public functions

| Function | Purpose |
|---|---|
| [`deposit`](../src/EthPool.sol#L24) (payable) | Deposit `msg.value` ETH for a receiver. |
| [`withdraw`](../src/EthPool.sol#L35) | Withdraw ETH back to `msg.sender`. |
| [`approve`](../src/EthPool.sol#L44) / [`increaseAllowance`](../src/EthPool.sol#L93) / [`decreaseAllowance`](../src/EthPool.sol#L106) | ERC-20-style allowance management. |
| [`transferFrom`](../src/EthPool.sol#L59) | Pull-based ETH transfer to a payable address. |
| [`transferToCelerWallet`](../src/EthPool.sol#L73) | Specialized transfer that funds a `CelerWallet` wallet directly. |
| [`balanceOf`](../src/EthPool.sol#L119) / [`allowance`](../src/EthPool.sol#L129) | Standard ERC-20 views. |

### Events

`Deposit`, `Transfer`, `Approval` (ERC-20 shape).

---

## RouterRegistry

[Source](../src/RouterRegistry.sol) · [Interface](../src/lib/interface/IRouterRegistry.sol) · **Permanent**

Optional global registry where relay-router operators advertise their addresses to the
network. Each entry stores the latest registration / refresh `block.number`.

### External functions

| Function | Purpose |
|---|---|
| [`registerRouter`](../src/RouterRegistry.sol#L18) | Add `msg.sender` to the registry. Reverts if already present. |
| [`deregisterRouter`](../src/RouterRegistry.sol#L29) | Remove `msg.sender`. |
| [`refreshRouter`](../src/RouterRegistry.sol#L40) | Update the stored block number for `msg.sender`. |

### Events

`RouterUpdated(RouterOperation indexed op, address indexed routerAddress)` —
`op ∈ {Add, Remove, Refresh}`.

---

## Ledger libraries

`CelerLedger.sol` is intentionally thin. The actual channel logic lives in five
libraries under [`src/lib/ledgerlib/`](../src/lib/ledgerlib/), attached to `CelerLedger`
via `using ... for ...`:

| Library | Responsibility |
|---|---|
| [`LedgerStruct`](../src/lib/ledgerlib/LedgerStruct.sol) | All shared structs and the `ChannelStatus` enum. No logic. |
| [`LedgerOperation`](../src/lib/ledgerlib/LedgerOperation.sol) | Open / deposit / withdraw / settle / snapshot — the bulk of the user-facing flows. |
| [`LedgerChannel`](../src/lib/ledgerlib/LedgerChannel.sol) | View functions and channel-state derivations (balance maps, peer state, withdraw intent, etc.). |
| [`LedgerMigrate`](../src/lib/ledgerlib/LedgerMigrate.sol) | `migrateChannelFrom` / `migrateChannelTo` — peer-controlled version migration. |
| [`LedgerBalanceLimit`](../src/lib/ledgerlib/LedgerBalanceLimit.sol) | Per-token per-channel deposit caps (gate enabled by default). |

**When debugging or extending channel behavior, the implementation almost always lives
in one of these libraries — not in `CelerLedger.sol`.**

---

## Helpers and mocks

These contracts are **test fixtures, not production**. They live under `src/`
because Foundry compiles everything in that directory together, but they should
never be deployed to a production network.

| File | Purpose |
|---|---|
| [`CelerLedgerMock`](../src/CelerLedgerMock.sol) | Test ledger with extra hooks; used in migration tests where two ledger versions must coexist. |
| [`BooleanCondMock`](../src/helper/BooleanCondMock.sol) | Mock condition contract returning a settable boolean outcome. Used in `PayResolver` tests. |
| [`NumericCondMock`](../src/helper/NumericCondMock.sol) | Mock condition contract returning a settable numeric outcome. |
| [`WalletTestHelper`](../src/helper/WalletTestHelper.sol) | Helper for direct `CelerWallet` integration tests. |
| [`ERC20ExampleToken`](../src/helper/ERC20ExampleToken.sol) | Sample ERC-20 used in token-channel tests. |

The protobuf decoders [`Pb.sol`](../src/lib/data/Pb.sol),
[`PbChain.sol`](../src/lib/data/PbChain.sol),
[`PbEntity.sol`](../src/lib/data/PbEntity.sol) are **auto-generated** by
[`pb3-gen-sol`](https://github.com/celer-network/pb3-gen-sol) from
[`proto/chain.proto`](../src/lib/data/proto/chain.proto) and
[`proto/entity.proto`](../src/lib/data/proto/entity.proto). Do not hand-edit; change
the `.proto` and regenerate.

---

**See also:** [`architecture-summary.md`](architecture-summary.md) · [`README.md`](../README.md)

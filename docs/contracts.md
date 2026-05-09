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
- [RouterRegistry](#routerregistry)
- [Ledger libraries](#ledger-libraries) (where the channel logic actually lives)
- [Helpers and mocks](#helpers-and-mocks)

---

## CelerWallet

[Source](../src/CelerWallet.sol) · [Interface](../src/interfaces/ICelerWallet.sol) · **Permanent** (not versioned)

Multi-owner, multi-token wallet that holds the funds for every channel in the network.
A single `CelerWallet` instance is shared globally; every `CelerLedger` (current or
future versions) is an *operator* over individual wallets within it. The contract has
deliberately minimal logic — it only knows how to deposit, withdraw, and transfer
operatorship — to keep the audit surface small.

> **Supported tokens:** native (e.g. ETH) and plain ERC-20 only. `depositERC20`
> credits the requested `_amount`, so tokens that deliver less than requested
> (fee-on-transfer, deflationary, rebasing, ERC-777 hooks) will desync this
> wallet's accounting from its real token balance. Use only standard ERC-20s.

### Constructor

```solidity
constructor() Ownable(msg.sender)
```

No parameters. Inherits `Ownable` (deployer is initial owner) and `Pausable`. The owner
can `pause` / `unpause` and (when paused) `drainToken` to recover stuck funds.

### Roles

- **Owners** — the channel peers; receive withdrawals and vote on operator candidates.
- **Operator** — exactly one per wallet; the `CelerLedger` instance authorized to move
  funds. Operatorship is the migration pivot point.
- **Contract owner** (Ownable) — can pause / unpause and drain when paused.

### External / public functions

| Function | Caller | Purpose |
|---|---|---|
| [`create`](../src/CelerWallet.sol#L66) | anyone (typically a `CelerLedger`) | Create a new wallet for a peer-pair, returning its `walletId`. |
| [`depositNative`](../src/CelerWallet.sol#L89) | anyone (payable) | Deposit native (e.g., ETH) into a wallet. |
| [`depositERC20`](../src/CelerWallet.sol#L101) | anyone | Deposit ERC-20 tokens (requires prior `approve`). |
| [`withdraw`](../src/CelerWallet.sol#L119) | operator only | Withdraw funds to a receiver. |
| [`transferBetweenWallets`](../src/CelerWallet.sol#L141) | operator only | Move funds between two wallets sharing the same operator (channel rebalancing). |
| [`transferOperatorship`](../src/CelerWallet.sol#L164) | current operator | Transfer operatorship to a new operator (the migration path). |
| [`voteForOperator`](../src/CelerWallet.sol#L179) | wallet owner | Vote for a new operator candidate; the change takes effect when *all* owners have voted for the same candidate (manual fallback for stuck migrations). |
| [`drainToken`](../src/CelerWallet.sol#L207) | contract owner, when paused | Emergency token recovery. |
| `pause` / `unpause` | contract owner | Pause guard for deposits / withdrawals / operator changes. |
| `walletOwners` / `walletOperator` / `balanceOf` / `pendingOperator` / `hasVoted` | view | Wallet introspection. |

### Events

`WalletCreated`, `Deposited`, `Withdrawn`, `TransferredBetweenWallets`,
`OperatorChanged`, `OperatorVoted`, `TokenDrained`. See
[`ICelerWallet.sol`](../src/interfaces/ICelerWallet.sol).

### Storage

```solidity
struct Wallet {
    address[] owners;
    address operator;
    mapping(address => uint256) balances;            // tokenAddr (0 = native) → balance
    address pendingOperator;
    mapping(address => bool) votes;
}
uint256 public walletCount;
mapping(bytes32 => Wallet) private wallets;
```

### Wallet ID derivation

```
walletId = keccak256(chainid, walletAddr, creatorAddr, nonce)
```

`creatorAddr` is `msg.sender` at the time `CelerWallet.create` is called — typically
the `CelerLedger` contract, not the end-user operator. The `chainid` prefix prevents
cross-chain wallet-id collisions when the same creator and nonce are reused across
chains.

---

## CelerLedger

[Source](../src/CelerLedger.sol) · [Interface](../src/interfaces/ICelerLedger.sol) · **Versioned**

The channel state machine and primary user entry point. The contract is a thin
facade — the bulk of channel logic is split across three libraries under
[`src/lib/ledgerlib/`](../src/lib/ledgerlib/) and attached via `using ... for ...`,
with the type-only `LedgerStruct` namespace alongside them. See
[Ledger libraries](#ledger-libraries) below.

> **Supported tokens:** native (e.g. ETH) and plain ERC-20 only — see the same
> note under [CelerWallet](#celerwallet). Non-standard ERC-20s
> (fee-on-transfer / rebasing / ERC-777 hooks) will desync channel accounting
> from the wallet's real token balance.

### Constructor

```solidity
constructor(address _nativeWrap, address _payRegistry, address _celerWallet) Ownable(msg.sender)
```

| Param | Purpose |
|---|---|
| `_nativeWrap` | Chain's canonical wrapped-native (wrapped-native) address. Used internally as a funding-flow primitive for native channels; never user-visible. Constructor-set; no setter. |
| `_payRegistry` | Address of the deployed [`PayRegistry`](#payregistry). |
| `_celerWallet` | Address of the deployed [`CelerWallet`](#celerwallet). |

Balance limits are **enabled by default** post-deployment. Configure them via
`setBalanceLimits` or call `disableBalanceLimits` for unlimited per-channel deposits.

### External functions — channel lifecycle

| Function | Purpose |
|---|---|
| [`openChannel`](../src/CelerLedger.sol#L66) | Open a fully-funded channel from a co-signed `PaymentChannelInitializer` (single tx). |
| [`deposit`](../src/CelerLedger.sol#L78) | Deposit native (msg.value) and/or pull from pre-approved wrapped-native or ERC-20 into a channel. |
| [`depositInBatch`](../src/CelerLedger.sol#L91) | Batch deposit across multiple channels in one tx. Not payable — native entries fund only via pre-approved wrapped-native (no `msg.value` path). |
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
`getNextPayIdListHashMap`, `getPayClearDeadlineMap`, `getPendingPayOutMap`,
`getWithdrawIntent`, `getCooperativeWithdrawSeqNum`, `getSettleFinalizedTime`,
`getDisputeTimeout`, `getMigratedTo`, `getChannelMigrationArgs`,
`getPeersMigrationInfo`, `getChannelStatusNum`, `getNativeWrap`, `getPayRegistry`,
`getCelerWallet`, `getBalanceLimit`, `getBalanceLimitsEnabled`. See
[`ICelerLedger.sol`](../src/interfaces/ICelerLedger.sol).

### Events

Open/Deposit/Snapshot: `OpenChannel`, `Deposit`, `SnapshotStates`.
Withdraw: `IntendWithdraw`, `ConfirmWithdraw`, `VetoWithdraw`, `CooperativeWithdraw`.
Settle: `IntendSettle`, `ClearOnePay`, `ConfirmSettle`, `ConfirmSettleFail`,
`CooperativeSettle`. Migration: `MigrateChannelFrom`, `MigrateChannelTo`.

### Storage

```solidity
LedgerStruct.Ledger private ledger;
// → channelStatusNums, nativeWrap, payRegistry, celerWallet,
//   balanceLimits, balanceLimitsEnabled, channelMap (bytes32 → Channel)
```

See [`LedgerStruct.sol`](../src/lib/ledgerlib/LedgerStruct.sol) for the full layout.

---

## PayResolver

[Source](../src/PayResolver.sol) · [Interface](../src/interfaces/IPayResolver.sol) · **Versioned** (chosen per-payment)

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

- A payment's `chain_id` must equal `block.chainid`.
- A payment's `pay_resolver` must equal the executing resolver's address.
- A payment must be resolved before `pay.resolveDeadline` (Unix timestamp, seconds).
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

[Source](../src/PayRegistry.sol) · [Interface](../src/interfaces/IPayRegistry.sol) · **Permanent**

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
| [`getPayAmounts`](../src/PayRegistry.sol#L107) | Bulk read for settlement; gates each pay by its own `resolveDeadline` if resolved, or the per-channel `pay_clear_deadline` (`max(pay.resolveDeadline) + clearMargin`) if never resolved. |
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

[Source](../src/VirtContractResolver.sol) · [Interface](../src/interfaces/IVirtContractResolver.sol) · **Permanent**

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

## RouterRegistry

[Source](../src/RouterRegistry.sol) · [Interface](../src/interfaces/IRouterRegistry.sol) · **Permanent**

Optional global registry where relay-router operators advertise their addresses to the
network. Each entry stores the Unix timestamp (seconds) of the latest registration /
refresh.

### External functions

| Function | Purpose |
|---|---|
| [`registerRouter`](../src/RouterRegistry.sol#L18) | Add `msg.sender` to the registry. Reverts if already present. |
| [`deregisterRouter`](../src/RouterRegistry.sol#L29) | Remove `msg.sender`. |
| [`refreshRouter`](../src/RouterRegistry.sol#L40) | Update the stored timestamp for `msg.sender`. |

### Events

`RouterUpdated(RouterOperation indexed op, address indexed routerAddress)` —
`op ∈ {Add, Remove, Refresh}`.

---

## Ledger libraries

`CelerLedger.sol` is intentionally thin. The bulk of channel logic lives in three
libraries under [`src/lib/ledgerlib/`](../src/lib/ledgerlib/), attached to `CelerLedger`
via `using ... for ...`. A fourth file, `LedgerStruct.sol`, holds shared types but
compiles to no bytecode (no functions).

| Library | Responsibility |
|---|---|
| [`LedgerStruct`](../src/lib/ledgerlib/LedgerStruct.sol) | All shared structs and the `ChannelStatus` enum. No logic; type-only namespace. |
| [`LedgerOperation`](../src/lib/ledgerlib/LedgerOperation.sol) | Open / deposit / withdraw / settle / snapshot — the bulk of the user-facing flows. |
| [`LedgerChannel`](../src/lib/ledgerlib/LedgerChannel.sol) | Channel-scoped view functions and state derivations (balance maps, peer state, withdraw intent, etc.). Operates on `LedgerStruct.Channel`. |
| [`LedgerMigrate`](../src/lib/ledgerlib/LedgerMigrate.sol) | `migrateChannelFrom` / `migrateChannelTo` — peer-controlled version migration. |

**When debugging or extending channel behavior, the implementation almost always lives
in one of these libraries — not in `CelerLedger.sol`.**

Balance-limit admin (`setBalanceLimits` / `disableBalanceLimits` / `enableBalanceLimits` /
`getBalanceLimit` / `getBalanceLimitsEnabled`) and ledger-wide config getters
(`getNativeWrap` / `getPayRegistry` / `getCelerWallet`) live **directly on
`CelerLedger`** rather than in a library. They're pure storage reads / writes — going
through a library would only add a DELEGATECALL hop with no logic benefit.

### Why split into libraries?

The split is **forced by the EIP-170 deployed-bytecode limit (24,576 bytes)**. The
hot-path library `LedgerOperation` alone is ~20.5 KB, leaving only ~4.0 KB of
headroom; merging the rest back into a single `CelerLedger` contract would total
~37.9 KB and fail to deploy.

| Component | Deployed size | % of 24,576 budget |
|---|---:|---:|
| `LedgerOperation` | ~20.5 KB | 84% |
| `CelerLedger` (facade + balance-limit admin + config getters) | ~8.4 KB | 34% |
| `LedgerMigrate` | ~5.2 KB | 21% |
| `LedgerChannel` | ~3.8 KB | 15% |

The split-by-responsibility above also keeps the cold migration path out of the hot
path's bytecode budget.

### How the libraries work mechanically

1. **Storage layout** is owned by `CelerLedger` — the `Ledger` and `Channel` structs
   defined in [`LedgerStruct`](../src/lib/ledgerlib/LedgerStruct.sol) describe the
   slots; `CelerLedger` declares the actual storage variable.
2. **Library functions take a `storage` pointer** as their first parameter (e.g.
   `function openChannel(LedgerStruct.Ledger storage _self, ...) external`).
3. **`using LedgerOperation for LedgerStruct.Ledger;`** in `CelerLedger` lets the
   facade write `ledger.openChannel(...)`; the compiler rewrites that as a `DELEGATECALL`
   into the deployed library, passing the storage pointer.
4. **DELEGATECALL semantics** mean the library code executes in `CelerLedger`'s
   context: storage reads/writes hit `CelerLedger`'s slots; `msg.sender` and
   `msg.value` are whatever the user sent to `CelerLedger`. The library is just code
   on a separate address.

The libraries are deployed as their own contracts; `CelerLedger`'s bytecode contains
20-byte placeholders that are patched with each library's address at deployment time.
See [`script/README.md`](../script/README.md#how-the-libraries-are-deployed) for the
deployment mechanics.

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

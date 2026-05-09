# Architecture Summary

A one-page orientation for the on-chain layer of **Celer AgentPay**. For the full
specification — design principles, off-chain protocols, app channels, message flows —
see the canonical architecture docs:

> 📖 **Full architecture:** [agentpay-docs.celer.network](https://agentpay-docs.celer.network/)

This page is a quick map. **It does not duplicate the architecture docs** — it gives you
just enough context to read the Solidity in this repo without bouncing back and forth.

---

## On-chain layer in two paragraphs

AgentPay is a generalized state-channel payment network. The on-chain contracts in this
repo bind two off-chain primitives — the **duplex payment channel** and the
**conditional payment** — to a minimal, verifiable on-chain footprint. Almost all
activity happens off-chain: peers exchange co-signed simplex states and forward
conditional payments through routed paths. The blockchain is only touched for deposits,
withdrawals, settlement, dispute resolution, and (rarely) deploying virtual contracts.

The six contracts split cleanly into two roles. **Asset custody** lives in
permanent, audited contracts that change rarely or never (`CelerWallet`, `PayRegistry`,
`VirtContractResolver`). **Channel and payment logic** lives in *versioned*
contracts (`CelerLedger`, `PayResolver`) that peers can cooperatively migrate between
without disturbing the assets — see [Decentralized Versioning][versioning] in the full
docs. `RouterRegistry` is an optional advertisement registry for relay nodes.

`CelerLedger` additionally depends on the chain's canonical wrapped-native
(wrapped-native) contract for the multi-party-funding path on native channels —
wired at deploy time, never user-visible. Users still deposit and receive native.

[versioning]: https://agentpay-docs.celer.network/agentpay-architecture/on-chain-contracts/decentralized-versioning

---

## Five design principles (one-line each)

These shape every choice in the codebase. Read the full text in
[system-overview.md][system-overview] when context matters.

1. **Minimize on-chain footprint.** Touch the chain only for deposits / withdrawals /
   disputes; keep storage compact.
2. **Minimize relay-node on-chain interaction.** Disputes are between source and
   destination; relays never write to chain.
3. **Minimize on-chain view calls.** Cache locally, exchange verified state directly.
4. **Minimize off-chain communication overhead.** Few round-trips, lightweight encoding.
5. **Decouple payment channels from app channels.** Conditions expose a uniform
   `isFinalized` / `getOutcome` interface; payment logic is independent of app logic.

A sixth, structural principle: **decentralized, peer-controlled versioning** — instead
of admin-controlled proxy upgrades, channel peers cooperatively migrate to new
`CelerLedger` / `PayResolver` versions. This eliminates trusted upgrade controllers and
keeps asset custody (`CelerWallet`) immutable.

[system-overview]: https://agentpay-docs.celer.network/agentpay-architecture/system-overview

---

## Channel state machine

The status of a payment channel inside `CelerLedger` (see
[`LedgerStruct.ChannelStatus`](../src/lib/ledgerlib/LedgerStruct.sol)):

```
                 openChannel
   Uninitialized ─────────────▶ Operable
                                   │   ▲
                  intendSettle     │   │ migrateChannelFrom
                                   ▼   │ (re-activates)
                                Settling
                                   │
                  confirmSettle    │
                  (after window)   ▼
                                Closed

   Operable / Settling ──── migrateChannelFrom ───▶ Migrated
                            (on the OLD ledger)
```

- **Uninitialized** — channel does not yet exist in this `CelerLedger` instance.
- **Operable** — active; deposits, withdrawals, snapshots, off-chain pay forwarding.
- **Settling** — `intendSettle` opened a challenge window; counterparty can submit
  newer simplex states.
- **Closed** — terminal; balances paid out, channel finalized.
- **Migrated** — terminal *on the old ledger*; the channel continues life on a new
  `CelerLedger` version. Migration outranks `intendSettle`: peers can migrate even
  while `Settling`, returning the channel to `Operable` on the new ledger.

For the full state-transition rules, see
[channel-operations.md][channel-operations].

[channel-operations]: https://agentpay-docs.celer.network/agentpay-architecture/on-chain-contracts/channel-operations

---

## Contract map (1-line each)

| Contract | Role | Versioned? |
|---|---|---|
| [`CelerWallet`](../src/CelerWallet.sol) | Multi-owner / multi-token asset custodian. One global instance. | No (permanent) |
| [`CelerLedger`](../src/CelerLedger.sol) | Channel state machine + primary user entry point. Operator of `CelerWallet`. | **Yes** |
| [`PayResolver`](../src/PayResolver.sol) | On-chain conditional-pay resolution; writes results to `PayRegistry`. | **Yes** (chosen per-payment) |
| [`PayRegistry`](../src/PayRegistry.sol) | Global `payId → (amount, deadline)` map; immutable, public reference. | No (permanent) |
| [`VirtContractResolver`](../src/VirtContractResolver.sol) | On-demand deployment of virtual contracts during disputes. | No (permanent) |
| [`RouterRegistry`](../src/RouterRegistry.sol) | Optional registry for relay-router self-advertisement. | No |

For per-contract APIs (constructor args, external functions, events, storage), see
[`contracts.md`](contracts.md).

---

## Key invariants (worth flagging in any change)

These come straight from the architecture docs. Tests should encode them; PRs should
not violate them.

- A simplex state is valid only if **co-signed by both peers** and has the highest
  `seq_num`.
- `payID = keccak256(payHash, setterAddress)` — binds a payment result to its
  designated resolver. `payHash = keccak256(serializedConditionalPay)`.
- During the challenge window of `resolvePayment*`, a result may be **raised** but
  never lowered. This protects relay nodes from collusive source/dest pairs.
- Migration outranks `intendSettle`. Cooperative migration always wins over a unilateral
  settle in flight.
- `CelerWallet` has exactly one **operator** (a `CelerLedger` instance). Operatorship
  transfer is the migration pivot; only the current operator (or all owners
  cooperatively, via `voteForOperator`) can transfer it.

---

## Where to read more

| Topic | Source |
|---|---|
| Design principles | [system-overview.md][system-overview] |
| Core data structures (protobuf) | [core-data-structures.md][data-structures] |
| Per-contract responsibilities & relationships | [contracts-architecture.md][contracts-arch] |
| Channel operations (open / deposit / withdraw / settle) | [channel-operations.md][channel-operations] |
| Decentralized versioning (migration) | [decentralized-versioning.md][versioning] |
| App contracts and condition interface | [app-contracts-and-protocols.md][app-protocol] |

[data-structures]: https://agentpay-docs.celer.network/agentpay-architecture/on-chain-contracts/core-data-structures
[contracts-arch]: https://agentpay-docs.celer.network/agentpay-architecture/on-chain-contracts/contracts-architecture
[app-protocol]: https://agentpay-docs.celer.network/agentpay-architecture/app-contracts-and-protocols

---

**See also:** [`contracts.md`](contracts.md) · [`README.md`](../README.md)

# Threat model

What this network defends against, what it does not, and which weaknesses are
accepted rather than unnoticed.

Written against the system as built. Where a control exists, it says how it is
verified. Where one does not, it says so.

---

## Assets

| Asset | Why it matters |
|---|---|
| Validator keys | Produce blocks. Four of them; losing two halts the chain. |
| Root CA private key | Mints any identity in the consortium. |
| Organisation intermediate keys | Mint any identity within one member's namespace. |
| Controller client certificate | Changes who may connect to the network. |
| Member governance accounts | Vote on membership and the validator set. |
| Letter of credit terms | Commercial content: amounts, goods, pricing. |
| Encryption private keys | Read historical terms sealed to that party. |
| Chain state | The authoritative record of every credit's lifecycle. |

## Actors

**Honest member.** Runs a validator and an application, votes, issues credits.

**Curious member.** Honest in protocol terms, interested in another member's
commercial terms. The logistics operator is the canonical case: a legitimate
party to a credit with no business reading its pricing.

**Malicious member.** Controls one organisation entirely: its node, its keys,
its CA, its votes. **This is the primary adversary.** A consortium of
competitors must assume one of them is hostile.

**Consortium operator.** Runs the RPC nodes, the controller, the observability
stack, and holds the root CA in this deployment. More privileged than any
member and a single point of several kinds of failure.

**Network attacker.** Positioned on the path between nodes, without credentials.

**Departed member.** Removed by vote, still holding keys and certificates.

---

## What is defended, and how it is verified

### One member cannot impersonate another

All four organisation CAs chain to one root, so without further restriction any
member could mint a certificate asserting another member's identity.

**Control.** X.509 name constraints on every intermediate, marked critical,
limiting each to its own DNS subtree and directory name. The truststore
contains the root **only**: a trust anchor's own extensions are taken as given,
so putting the intermediates there would disable their constraints while every
test still passed.

**Verified.** `test/pki/name-constraints.sh` offline; `test/smoke/tls.sh`
probe 4 against the live network, minting an impersonating certificate from the
real importer bank CA and confirming the handshake is refused.

### An operator cannot change the validator set

**Control.** QBFT reads validators from `ValidatorSetView`. After the
transition, `qbft_proposeValidatorVote` returns `Method not enabled`.

**Verified.** Executed on local; the RPC refusal is the proof.

### Governance cannot halt the chain

A majority could vote the validator set below quorum.

**Control.** `MemberRegistry` refuses any write leaving fewer than three active
validators, and the floor lives in the registry rather than the Governor so a
replaced or buggy Governor cannot bypass it.

**Verified.** On staging: a second removal passed its vote and reverted at
execution with `ValidatorFloorBreached(2, 3)` while blocks continued.

### A member cannot filibuster its own removal

**Control.** The threshold excludes the subject, so removal needs two of the
remaining three rather than three of four.

**Verified.** `test_subjectCannotVoteOnItsOwnRemoval`.

### A suspended member cannot act on live credits

**Control.** Roles resolve through the registry on every call rather than being
stored on the credit, so a governance decision takes effect immediately with
nothing to synchronise.

**Verified.** `test_suspendedMemberLosesAccessToLiveCredits`.

### The carrier cannot read commercial terms

**Control.** Terms never touch the chain. Only a keccak256 commitment and a
non-secret locator do. Terms are sealed with CMS envelope encryption to the two
banks' encryption certificates.

**Verified.** `test/privacy/terms.sh`: the logistics operator is an active
member, a named party, holds a valid certificate under the consortium root, and
cannot decrypt. A further probe confirms holding another party's *certificate*
is useless without its key.

### A credit's terms cannot change after issuance

**Control.** `LetterOfCredit` is immutable with no proxy. A bug is fixed by
deploying a new factory; existing credits run to completion under the code they
were created with.

**Rationale.** An upgradeable credit is one whose terms can change after the
beneficiary has already shipped, which is weaker than the paper process. ADR
0007.

---

## Accepted weaknesses

Each is a decision with a reason, not an oversight.

### Peer traffic is unencrypted

Besu 26.8.1 has no peer-to-peer TLS. Peers are mutually *authenticated* by the
devp2p handshake and pinned by the static node list, so an attacker cannot join
or impersonate a node. But anyone on the network path can read block and
transaction contents in flight.

Letter of credit terms are not exposed, because they are never on chain. What
leaks is the existence and lifecycle of credits, and any future contract that
does put data on chain.

**Mitigation**, not implemented: a service mesh with sidecar mTLS, WireGuard,
or IPsec between hosts. This is the modern answer regardless of client support
and survives the client removing features. ADR 0005.

### Seven processes can write the permissions file

Besu proves at startup that it can write the permissions file, because
`perm_add*` persists allowlist changes back to it, so it cannot be mounted
read-only. The controller is the only *intended* writer by convention.

**Consequence.** A member with admin RPC access to its own node can widen that
node's allowlist and have Besu persist it. The next reconcile overwrites it, so
the registry wins within ten seconds, but there is a window.

**Mitigation**, not implemented: remove `ADMIN` and `PERM` from the RPC API
list on nodes that do not need them.

### Infrastructure accounts are privileged outside governance

The deployer and the operator's service accounts are allowlisted from static
configuration, not by vote. Without them, account permissioning would lock out
the only account able to deploy.

**Consequence.** The consortium operator holds transacting access that no vote
granted and no vote can remove.

### The permissioning layer has a propagation delay

The controller fails open. A member removed by vote may still connect until the
next reconcile, or indefinitely if the controller is down.

**Why.** Failing closed would let one service halt a consortium whose point is
that no single party can.

**Compensating control.** PKI revocation is immediate and independent: revoke
an intermediate and that member cannot complete a TLS handshake whatever any
allowlist says. Two paths, one slow and automatic, one immediate and manual,
and the fast one has no single point of failure.

**Detection.** The controller heartbeat, alerted in m7, because a service that
fails open fails invisibly.

### Validator removal and allowlist removal are not atomic

Seconds apart, with nothing coordinating them. A member removed by vote stops
validating at the next block and stops being allowed to connect within a
reconcile interval.

### Sealed terms have no forward secrecy

An attacker obtaining a recipient's encryption private key can read every
credit ever sealed to it. Forward secrecy needs interactive key agreement,
which does not fit documents sealed once and read later. Tessera had the same
property.

### Existence of credits is not concealed

Anyone reading the chain learns that a credit exists between these parties,
with this expiry, and how many shipment milestones it has. Only commercial
content is hidden. Concealing relationships needs a different system.

### Nothing enforces who terms were sealed to

The contract commits to the terms, not the recipient list. A bank could seal
terms to a party who should not have them and the chain would not know. The
counterparty verifying its own copy detects wrong terms, not over-distribution.

### The consortium operator is over-privileged

In this deployment the operator holds the root CA, runs both RPC nodes, holds
the controller certificate, and runs observability. A compromised operator can
mint any identity, change who may connect, and see all traffic.

**What a real deployment changes.** Each member generates its own intermediate
key and submits a CSR; the root is held offline with M-of-N control and a key
ceremony; each organisation runs its own RPC node and its own cluster. The
scripts already separate CSR creation from signing, so the first of those is
mechanical. The rest is organisational.

### No consensus observability

Besu 26.8.1 exposes no validator count and no round change counter. Round
changes are the *leading* indicator of a stall, so the absence means alerting
fires after a stall rather than before. `make smoke` covers validator set
agreement on demand; continuous coverage needs an exporter doing `eth_call`
against the validator view.

---

## Residual risks, ranked

1. **Two validator keys lost or compromised.** Chain halts; recovery needs
   coordinated action across four organisations.
2. **Root CA compromised.** Total failure. Every identity is forgeable.
3. **Consortium operator compromised.** Root CA, controller certificate, both
   RPC nodes and all observability at once.
4. **Member intermediate compromised.** Bounded to that member's namespace by
   name constraints. This bounding is the single most valuable control in the
   system.
5. **Network attacker on the peer path.** Reads chain traffic; cannot join,
   impersonate or forge.
6. **Departed member with retained keys.** Blocked at both the PKI and
   permissioning layers; the PKI block is immediate.

## What would change the model

On-chain value. Today a credit commits to an off-chain settlement, so a
contract bug requires a conversation rather than stranding funds. The moment
value moves on chain, the immutability decision in ADR 0007 needs revisiting
and this model needs rewriting around theft rather than disclosure.

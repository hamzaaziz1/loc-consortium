# ADR 0003: Two-tier PKI with per-organisation intermediates and name constraints

- Status: Accepted
- Date: 2026-09-22

## Context

Every node in the consortium needs a cryptographic identity: for devp2p TLS
between nodes, and for mutual TLS on the RPC endpoints where a client must prove
who it is before it can submit a transaction. Those identities come from a
private certificate authority, since there is no public CA that can vouch for
"validator 2 of this consortium".

Three constraints shape the hierarchy.

1. **Members are competitors.** The consortium operator should not be the only
   party able to mint identities for other members' infrastructure.
2. **Member removal must be a bounded operation.** When governance votes a member
   out, their ability to authenticate must end at a known point, without an
   inventory hunt for individual certificates.
3. **The PKI must line up with the on-chain governance model from m4**, so that
   removing a member is one event expressed at two layers rather than two
   loosely related procedures.

## Options considered

### Option A: single flat CA

One self-signed root issues leaf certificates directly to all nodes and clients.

Simplest to build, and wrong on constraint 1: whoever holds the root key issues
every identity in the network, so all members depend on that party. It is also
wrong operationally, because the root key is then in routine use rather than
kept offline, which is the opposite of how a root key should be treated.

Removing a member under A means revoking each of their leaf certificates
individually, which fails constraint 2 the moment the inventory is wrong.

### Option B: root CA, one intermediate per organisation

A self-signed root signs four intermediate CAs, one each for the importer bank,
exporter bank, logistics operator and consortium operator. Each member's
intermediate signs that member's own node and client certificates.

The root key is used only when onboarding a new member, so it can live offline.
Each member controls issuance for its own infrastructure. Removing a member is a
single revocation of their intermediate, which invalidates everything beneath it
at once.

### Option C: root, single shared intermediate, leaves

Keeps the root offline, which is the one real advantage over A, but the shared
intermediate reproduces A's ownership problem one level down without buying the
per-member isolation of B.

## Decision

**Option B**, with X.509 name constraints applied to every intermediate.

### The attack Option B introduces

Every node trusts the root, and therefore transitively trusts all four
intermediates. Without further restriction, a compromised member's intermediate
can issue a certificate asserting another member's identity, and the receiving
node will validate it successfully against the root. One compromised member can
impersonate any other. This is a real weakness of naive two-tier PKI and it is
strictly worse than Option A, where no such delegation exists.

### The mitigation

When the root signs each intermediate, it stamps a `nameConstraints` extension
permitting that intermediate to issue only names within its own subtree, and
excluding everything else. The importer bank's CA cannot produce a certificate
for an exporter bank name that will pass validation, because path validation
rejects it at the intermediate, not at the leaf.

Besu runs on the JVM, and Java's CertPath validation enforces name constraints,
so this is an enforced control rather than documentation. This is verified by a
negative test in m3: the importer bank's intermediate is used to issue a
certificate for an exporter bank name, and the handshake must fail.

### Naming scheme

Leaf names are structured so the constraint has something to bind to:

```
<role>-<index>.<organisation>.loc.consortium

validator-1.importer-bank.loc.consortium
validator-1.exporter-bank.loc.consortium
validator-1.logistics.loc.consortium
validator-1.operator.loc.consortium
rpc-1.operator.loc.consortium
rpc-2.operator.loc.consortium
```

The organisation label sits in the middle of the name so that each intermediate's
permitted subtree is exactly `.<organisation>.loc.consortium`. Role is encoded in
the leftmost label so that a certificate carries its function as well as its
owner, which is what the certificate-to-role map in
`docs/architecture/` documents and what RPC authorisation reads.

`.consortium` is used rather than a real TLD because these names are resolved
within the network only and must never be confusable with a public DNS name.

## Consequences

**What this makes easy.** Member offboarding is one revocation. Each member owns
its own issuance. The blast radius of a compromised member CA is bounded to that
member's own namespace by an enforced control. The PKI layer and the governance
layer describe the same membership set, so an m4 removal vote and a certificate
revocation are two expressions of one event.

**Accepted costs.** Four intermediates instead of one CA means more key material
to generate, distribute and track, and the generation tooling is meaningfully
more complex than a flat CA would be. Name constraints are easy to get subtly
wrong — an overly broad permitted subtree silently restores the impersonation
path — which is why the negative test exists rather than a comment claiming the
constraint works.

The root key must be kept offline to get the benefit of this structure. In this
repository the root key is generated locally for demonstration and its handling
is documented rather than genuinely air-gapped; ADR on key management records
what a production deployment would change.

**Deferred to a later ADR.** Certificate validity periods, how revocation
information is distributed (CRL or OCSP) and how quickly revocation propagates,
and the custody model for member intermediate keys. Those are separable
decisions and are made once the hierarchy is in place.

## Revisit if

A member requires certificates issued by its own existing corporate CA rather
than an intermediate under this root, which is the realistic enterprise
complication. That turns the question into cross-certification or a trust store
carrying multiple roots, and changes this design substantially.

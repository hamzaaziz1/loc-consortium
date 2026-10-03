# Certificate to role map

Which certificate represents which party, what it is used for, and what it does
and does not authorise.

## The rule this document exists to make explicit

**A certificate asserts identity. It does not grant permission.**

Mutual TLS answers "who is connecting". It does not answer "may they do this".
Authorisation comes from the on-chain membership registry built in m4 and from
the role checks inside the LoC contracts in m5. A valid certificate gets you a
TLS session and nothing more.

Keeping these separate matters operationally. Revoking a certificate is slow and
unreliable to propagate; removing a member from the registry is a transaction
with deterministic timing. If permission rode on the certificate, every
authorisation change would become a PKI operation.

## How identity is encoded

Every end-entity certificate uses the same shape:

```
subject:  C=GB, O=<organisation>, OU=<role>, CN=<name>.<org slug>.loc.consortium
SAN:      DNS:<name>.<org slug>.loc.consortium
```

The organisation sits in the middle DNS label, which is what each
organisation's name constraints bind to. The role lives in the subject OU and
in the leftmost label, so a certificate carries its function as well as its
owner. Nothing reads the OU for an access decision today; it exists so that
operators and logs can tell at a glance what a connecting party is.

## The certificates

### Validators

| Certificate | Organisation | Used for |
|---|---|---|
| `validator-1.importer-bank.loc.consortium` | Importer Bank | QBFT block production, devp2p |
| `validator-1.exporter-bank.loc.consortium` | Exporter Bank | QBFT block production, devp2p |
| `validator-1.logistics.loc.consortium` | Logistics Operator | QBFT block production, devp2p |
| `validator-1.operator.loc.consortium` | Consortium Operator | QBFT block production, devp2p |

Issued as `node` certificates: server and client authentication both, because
devp2p peers dial each other and a validator is simultaneously the initiator of
some connections and the recipient of others.

Being a validator is **not** conferred by this certificate. The validator set is
read from the QBFT validator contract (ADR 0002). A node holding a validator
certificate that is not in the contract's set participates in the network as an
ordinary peer. The certificate and the validator set are deliberately separate
mechanisms, and a membership vote changes the second, not the first.

### RPC nodes

| Certificate | Organisation | Used for |
|---|---|---|
| `rpc-1.operator.loc.consortium` | Consortium Operator | JSON-RPC endpoint, devp2p |
| `rpc-2.operator.loc.consortium` | Consortium Operator | JSON-RPC endpoint, devp2p |

Both are owned by the consortium operator rather than split between members.
Application traffic therefore never reaches a block producer, which keeps client
load off consensus. Members do not depend on the operator for access, because
each member authenticates with a client certificate its own CA issued; the
operator runs the endpoint but never holds a member's key.

### Operator services

| Certificate | Organisation | Used for |
|---|---|---|
| `loc-api.operator.loc.consortium` | Consortium Operator | LoC API to RPC |
| `controller.operator.loc.consortium` | Consortium Operator | Permissioning controller to RPC admin |

Issued as `client` certificates: client authentication only, no server
authentication. If one of these keys leaks it cannot be used to stand up a
convincing endpoint, only to connect out.

The controller certificate is the most sensitive end-entity certificate in the
network. It is what the m4 permissioning controller uses to apply allowlist
changes over the admin RPC, so possession of it is possession of the ability to
change who may connect. That it is a client certificate limits the blast radius;
it does not eliminate it, and the threat model in m9 treats this key as a
primary target.

### Member application clients

| Certificate | Organisation | Used for |
|---|---|---|
| `client-1.importer-bank.loc.consortium` | Importer Bank | Bank application to RPC |
| `client-1.exporter-bank.loc.consortium` | Exporter Bank | Bank application to RPC |
| `client-1.logistics.loc.consortium` | Logistics Operator | Logistics application to RPC |

Each is issued by that member's own intermediate CA. The operator who runs the
RPC endpoint never sees these private keys and cannot mint a replacement, which
is the practical consequence of the per-organisation hierarchy in ADR 0003.

## What an RPC endpoint learns from a client certificate

After a successful mutual TLS handshake the endpoint knows, with cryptographic
assurance:

- which organisation the connecting party belongs to, from the subject O and
  from which intermediate signed the chain, with those two cross-checked by the
  name constraints
- which named client it is, from the CN
- what kind of party it claims to be, from the OU

It does not know whether that party may create a letter of credit, release a
payment, or vote on membership. Those are contract-level decisions keyed to the
on-chain address, and the mapping from certificate identity to on-chain address
is maintained by the registry, not by the PKI.

# ADR 0005: RPC mutual TLS, and the absence of transport security between nodes

- Status: Accepted
- Date: 2026-10-20

## Context

ADR 0003 built a two-tier PKI whose central control is name constraints: each
organisation's intermediate may issue only within its own namespace, so a
compromised member CA cannot mint a usable identity for another member. At that
point the control was demonstrated with `openssl verify`.

m3 is where the certificates get used, and where that control either becomes
real or quietly stops existing. Three decisions turned out to have a
non-obvious correct answer, and one capability turned out not to exist.

## Decisions

### 1. Client authentication via truststore, not `--rpc-http-tls-ca-clients-enabled`

Besu offers three ways to authenticate RPC clients: a file of accepted
certificate fingerprints, a flag meaning "accept any client whose certificate
chains to a CA this JVM already trusts", and an explicit truststore. The client
rejects any attempt to combine the truststore with either of the others; they
are mutually exclusive and it says so at startup.

**Chosen: the truststore.**

`ca-clients-enabled` resolves against the JVM's default trust store, which is
the public web PKI. Our root is not in it, so every legitimate consortium
client would be rejected — and far worse, a certificate issued by any public CA
in the world would be accepted. For a network whose entire access model is "the
four members and nobody else", that is precisely inverted.

The fingerprint file was rejected for a different reason: it authenticates
specific certificates rather than an issuing authority, so every certificate
rotation becomes a change to every node's configuration, and the name
constraints play no part in the decision at all.

### 2. The truststore contains the root only

A certificate used as a trust anchor has its own extensions taken as given
rather than checked, because path validation *starts* at the anchor.

Putting the four organisation intermediates in the truststore would therefore
mean their `nameConstraints` were never evaluated. Every member could
impersonate every other, the network would accept it, and — this is the part
worth dwelling on — `test/pki/name-constraints.sh` would still pass, because it
validates against a root-only trust store and would never notice.

Root only means validation walks client leaf, then issuing intermediate, then
root, evaluating constraints on the way. Clients present their own chain, which
is why `gen-leaves.sh` writes a `.chain.pem` for every certificate: the server
holds only the root, so the intermediate has to arrive from the client for a
path to exist.

`test/smoke/tls.sh` probe 4 is the live proof. It mints a certificate from the
real importer bank CA naming an exporter bank client, confirms the CA signs it
— a compromised CA would — and confirms the network refuses it at the
handshake.

### 3. The truststore is built with `keytool`, not `openssl`

A certificate in a Java truststore must be marked as a *trusted certificate
entry*, a Java-specific attribute inside the PKCS12 bag.
`openssl pkcs12 -export -nokeys` does not write it. The result is a
structurally valid PKCS12 that Java loads without complaint and treats as
containing zero trust anchors.

Nothing reports this. The node starts cleanly, the TLS listener comes up, the
log is silent, and every mutual TLS handshake fails with the server requesting
a client certificate while advertising no acceptable CAs.

The diagnostic that finds it is `openssl s_client`, whose "acceptable client
certificate CA names" line shows what the server actually trusts rather than
what you believe you gave it. An empty list there is conclusive.

`keytool` comes from the pinned Besu image rather than a separate JDK, so the
tool writing the store is the same JDK that reads it. Given the bug was exactly
a writer/reader mismatch, the coupling is worth it. `gen-keystores.sh` asserts
the anchor count afterwards, because a silent failure mode deserves an explicit
check.

### 4. There is no transport security between nodes, and this is stated rather than worked around

Besu 26.8.1 has no peer-to-peer TLS. It existed as an early-access feature,
`--Xp2p-tls-enabled`, with its own documentation page. It is absent from both
the stable and unstable option lists in this build.

This is part of a pattern rather than an isolated gap. Four enterprise features
have left this client between 24.x and 26.x:

| Feature | Status |
|---|---|
| Onchain (smart contract) permissioning | Removed in the 25.6.0 line |
| Tessera privacy groups | Removed in the 25.6.0 line |
| Peer-to-peer TLS | Early access, absent from 26.8.1 |
| PKI-backed QBFT | Announced for removal |

Besu is refocusing on being a mainnet Ethereum client. Consortium features that
sit above the protocol are being pushed out of the client, which is a
defensible decision on their part and the organising fact of this entire
repository: the work is rebuilding what the client dropped, at the layers where
it now belongs.

**What this costs us.** devp2p traffic between nodes is not encrypted. Peers are
mutually authenticated — the devp2p handshake proves possession of the node
private key, and the static node list pins which public keys are acceptable —
so an attacker cannot join or impersonate a node. But anyone positioned on the
network path can read block and transaction contents in flight.

**What production does instead.** Transport confidentiality between nodes
becomes an infrastructure concern: a service mesh with sidecar mTLS, WireGuard,
or IPsec between hosts. That is the modern answer regardless of client support,
it survives the client removing features, and it is demonstrable in the m8
Kubernetes work in a way a client flag would not be.

## Consequences

Every RPC endpoint in the network requires mutual TLS, including the
validators'. There is no plaintext RPC anywhere.

The PKI is now load-bearing at runtime rather than only at rest. A botched
certificate regeneration takes the network's RPC offline, which is why
`gen-keystores.sh` verifies its own output and why certificate expiry
monitoring is a named requirement for m7 rather than an afterthought.

Clients must present a chain rather than a bare certificate, use HTTP/1.1
because Besu's JSON-RPC is not an HTTP/2 service, and connect by certificate
name rather than by IP. The smoke test encodes all three.

Regenerating keystores mints a fresh password and requires restarting every
node. Acceptable in development, unacceptable as a rotation procedure, so the
m9 runbook needs a certificate rotation path that does not regenerate the tree.

**Not addressed here.** Besu logs nothing at INFO when it rejects every RPC
client. A node can be refusing all traffic while looking perfectly healthy in
its logs and in `docker compose ps`. That is an observability gap, and m7 owns
it.

## Revisit if

Peer-to-peer TLS returns to the client, or the consortium's threat model starts
to include an attacker on the network path between nodes, at which point the
service mesh question becomes urgent rather than theoretical.

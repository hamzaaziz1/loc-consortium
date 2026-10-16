# Developer guide

How to get this network running, what generates what, and the failures that
cost us a session each so they only cost you a lookup.

For *why* anything is built the way it is, read `docs/adr/`. This file is the
*how*.

Current state: milestones m0 to m3 complete, m4 contracts written and tested
but not yet deployed to the chain.

## Prerequisites

| Tool | Version used | Notes |
|---|---|---|
| Docker + Compose v2 | 29.x / 2.40 | Compose v2 syntax, `docker compose` not `docker-compose` |
| Foundry | 1.7.1+ | `forge`, `cast` |
| OpenSSL | 3.x | 3.0 and 3.5 both verified |
| jq | 1.7+ | used by the generators and the smoke test |
| Node | 20+ | not needed until the controller lands |
| Memory | ~6 GB free | six JVMs at 512 MB plus overhead |

Work on the Linux filesystem, not under `/mnt/c`. Bind mounts across the
Windows boundary are slow enough that the stack feels broken, and it is where
CRLF endings creep back in.

## Bootstrap, from a fresh clone

Order matters. Each step consumes what the previous one produced.

```bash
make pki              # root CA, 4 org intermediates, 12 certs, keystores
make network-keys     # QBFT genesis + devp2p node keys  (needs docker)
make network-config   # static-nodes.json + compose addressing override
make up               # six nodes
make smoke            # 21 assertions that the network is actually healthy
```

Then, to confirm the security properties rather than just liveness:

```bash
make pki-test         # name constraints, offline, against openssl
make tls-test         # the same constraints enforced by the live network
cd contracts && forge test
```

Tear down with `make down` (removes volumes) and `make pki-clean` /
`make network-clean` to destroy generated material.

Reconcile the target list against `make help`, which is generated from the
Makefile and is authoritative.

## What is committed and what is generated

Nothing cryptographic is committed. Everything under these paths is generated
and gitignored:

```
network/pki/out/                      CA tree, certificates, keystores
network/keys/                         devp2p node keys
network/genesis/genesis.json          derived from the validator keys
network/genesis/manifest.json         node -> address/pubkey mapping
network/config/static-nodes.json      peer list
network/compose/compose.addressing.yml  IPs and host ports
```

The CI `pki` job rebuilds the whole CA tree from nothing on every push, which
also proves the PKI is reproducible from the repository rather than from one
laptop's leftovers. It then greps the git index for anything resembling a
private key and fails if it finds one.

## Single sources of truth

Three files are authoritative, and most of the tooling exists to stop the same
fact being written down twice.

**`network/pki/openssl/orgs.conf`** — consortium membership. Adding a fifth
organisation is a line here plus a rerun of the PKI scripts.

**`network/pki/openssl/nodes.conf`** — every end-entity certificate. The PKI
issues from it *and* `tools/gen-network.sh` reads it to decide which nodes
exist, so a node without a certificate, or a certificate without a node, is
impossible rather than merely unlikely.

**`network/config/addressing.conf`** — IP, RPC port and metrics port per node.
Read by the static-nodes generator, by the compose override it emits, and by
the smoke test. The one time addressing lived in two places, they disagreed
and a node silently failed to peer.

## Generators

| Script | Produces | Needs |
|---|---|---|
| `network/pki/gen-root.sh` | root CA + issuance database | openssl |
| `network/pki/gen-intermediates.sh` | one CA per org, name-constrained | openssl |
| `network/pki/gen-leaves.sh` | end-entity certs from `nodes.conf` | openssl |
| `network/pki/gen-keystores.sh` | PKCS12 keystores + truststore | openssl, **docker** |
| `tools/gen-network.sh` | genesis, node keys, manifest | **docker**, jq |
| `tools/gen-static-nodes.sh` | peer list + compose addressing | jq |

All are idempotent and skip existing output. `FORCE=1` regenerates, and always
deletes before writing, because key material is written read-only and cannot be
overwritten in place.

Regenerating the PKI mints a new keystore password, so every node must be
restarted afterwards. Fine in development; the m9 runbook owes a rotation
procedure that does not regenerate the tree.

## Tests

| Suite | Command | What it proves |
|---|---|---|
| Contracts | `cd contracts && forge test` | governance rules and the validator floor |
| PKI | `make pki-test` | name constraints, offline, 7 assertions |
| Network | `make smoke` | the live network is healthy, 21 assertions |
| TLS | `make tls-test` | the live network rejects what it should, 7 assertions |

The smoke test checks liveness properties that `docker compose ps` cannot: that
every node agrees on the validator set, that peers actually formed a mesh, that
the chain is advancing, and that `PUSH0` executes. Containers can be up while
all of those are false.

The TLS test opens with a *positive* control. Without it, a network that is
simply down passes every negative assertion.

## Failures we have already had

Each of these cost real time. The symptom rarely resembles the cause.

**Besu rejects `--static-nodes-file` entries with hostnames.** An enode URL
must carry an IP. devp2p identifies a peer by public key and treats the address
as a route; name resolution is outside the protocol. Symptom: `Illegal static
enode supplied` and the node refuses to start.

**An openssl-built truststore contains zero trust anchors.** Java needs
certificates marked as *trusted certificate entries*, an attribute
`openssl pkcs12 -export -nokeys` does not write. Symptom: nothing. The node
starts, the TLS listener comes up, the log is silent, and every mutual TLS
handshake fails. Diagnose with:

```bash
openssl s_client -connect 127.0.0.1:8546 </dev/null 2>&1 | grep -A3 "Acceptable client"
```

An empty CA names list is conclusive. `gen-keystores.sh` uses `keytool` from
the Besu image and asserts the anchor count afterwards.

**Besu logs nothing at INFO when it rejects every RPC client.** A node can be
refusing all traffic and look perfectly healthy. Restart it with
`--logging=DEBUG` to make it talk. Observability for this is m7's problem.

**`--rpc-http-tls-truststore-file` and `--rpc-http-tls-ca-clients-enabled` are
mutually exclusive.** Besu says so at startup. Use the truststore;
`ca-clients-enabled` resolves against the JVM's default trust store, which is
the public web PKI, so it would reject every consortium client and accept
anything signed by a public CA.

**Clients must use HTTP/1.1.** Besu's JSON-RPC is not an HTTP/2 service. curl
negotiates h2 over TLS by default, the handshake succeeds, and the request then
fails with a TLS internal error. Pass `--http1.1`.

**Clients must present a chain, not a bare certificate.** The server trusts
only the root, so the issuing intermediate has to arrive from the client for a
validation path to exist. Use the `.chain.pem` files.

**Anything the Besu container writes to a bind mount is root-owned.** Pass
`--user "$(id -u):$(id -g)"`. The generators do; ad hoc `docker run` commands
need it too or you will be reaching for sudo to delete your own files.

**`operator generate-blockchain-config` refuses an existing output directory.**
Mount the parent and let Besu create the leaf.

**`openssl ca` refuses to reissue for a subject it has already issued for**,
which blocks renewal and key rotation. The setting is not read from the config
at signing time; it lives in `index.txt.attr` beside the database, written by
openssl on first signature. It has to exist *before* the first signing.

**openssl parses the whole config file on every invocation**, including
sections it will not use, so one unset `$ENV::` variable anywhere fails the
command with a line number and nothing else.

**CRLF.** `make check-eol` runs in CI. A CRLF in a PEM file or a Besu config
surfaces as a TLS handshake failure or a config parse error, never as "you have
a CRLF".

## Conventions

Decisions go in `docs/adr/`, numbered in order of acceptance, never edited after
acceptance. An ADR with no consequences section is not a decision.

The running commentary, including wrong turns, goes in `docs/build-log.md`.

Comments in the generators explain *why*, because the scripts encode a dozen
non-obvious constraints that look arbitrary without them.

Contracts are pinned to solc 0.8.28 and `evm_version = "shanghai"`. The chain
activates Shanghai at genesis via `shanghaiTime`. These must agree: a compiler
ahead of the chain emits opcodes the EVM rejects at call time, with the chain
otherwise running perfectly. The smoke test asserts `PUSH0` executes for
exactly this reason.

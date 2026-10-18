# Developer guide

How to get this network running, what generates what, and the failures that
cost a session each so they only cost you a lookup.

For *why* anything is built the way it is, read `docs/adr/`. This file is the
*how*.

Current state: m0 to m3 complete, m4 contracts deployed to the local chain and
governance handed over. The QBFT transition to contract validator selection is
not yet applied.

## Prerequisites

| Tool | Version used | Notes |
|---|---|---|
| Docker + Compose v2 | 29.x / 2.40 | `docker compose`, not `docker-compose` |
| Foundry | 1.7.1+ | `forge`, `cast` |
| OpenSSL | 3.x | 3.0 and 3.5 both verified |
| jq | 1.7+ | used by the generators and the smoke test |
| Memory | ~5 GB free per stack | six JVMs at 512 MB plus overhead |

Work on the Linux filesystem, not under `/mnt/c`. Bind mounts across the
Windows boundary are slow enough that the stack feels broken, and it is where
CRLF endings creep back in.

**One host-level step.** Certificate names must resolve for `cast` and
`forge script`, which have no `--resolve` equivalent:

```bash
echo "127.0.0.1 rpc-1.operator.loc.consortium rpc-2.operator.loc.consortium" | sudo tee -a /etc/hosts
```

A developer-machine convenience; nothing in the repository depends on it.

## Environments

Two stacks share this repository.

| | local | staging |
|---|---|---|
| Purpose | the working consortium, holds real chain state | rehearsal for risky operations |
| Chain ID | 7753 | 7754 |
| Subnet | 172.28.0.0/16 | 172.29.0.0/16 |
| RPC ports | 8545, 8546, 8551-8554 | 8645, 8646, 8651-8654 |
| Proxy port | 8600 | 8700 |
| Compose project | `loc-local` | `loc-staging` |

Select with `LOC_ENV`, which defaults to `local`:

```bash
make up                      # local
LOC_ENV=staging make up      # staging
make help                    # prints which environment you are pointed at
```

Staging exists because the m9 runbook is a deliverable, and a runbook nobody
has executed is fiction. Procedures like recovering a stalled QBFT round can
only be written by deliberately stalling one, which cannot happen on the
network holding demo state.

**Staging is rebuilt, not preserved.** `LOC_ENV=staging make down` destroys its
volumes and the generators recreate it in about ninety seconds. Every rehearsal
therefore starts from a known state rather than from whatever the last one left
behind.

**What differs:** chain material, addressing, compose project, chain ID.
**What is shared:** the PKI. Node names are identical in both because the roles
are identical, so a second certificate tree would be work without insight.

The chain IDs differ deliberately. Matching IDs would mean a transaction aimed
at the wrong RPC port is *accepted* rather than rejected, which defeats the
point of separating the stacks.

## Bootstrap, from a fresh clone

Order matters; each step consumes the previous one's output.

```bash
make pki                 # root CA, 4 org intermediates, 13 certs, keystores
make network-keys        # QBFT genesis + devp2p node keys  (needs docker)
make network-config      # static-nodes.json + compose override
make up                  # six nodes
make smoke               # 21 assertions that the network is actually healthy
```

Then the security properties, rather than just liveness:

```bash
make pki-test            # name constraints, offline, against openssl
make tls-test            # the same constraints enforced by the live network
make verify              # smoke + tls-test together
cd contracts && forge test
```

## Deploying the governance contracts

```bash
make proxy-up            # the operator tooling TLS proxy
make deploy-config       # joins validator addresses, enodes and member accounts

cd contracts
forge script script/Deploy.s.sol:Deploy \
  --rpc-url http://127.0.0.1:8600 \
  --private-key "$(cat ../network/keys/local/deployer/key.priv)" \
  --broadcast --legacy --gas-price 0
```

Three things in that command are not obvious.

**The RPC URL is the proxy, not a node.** Foundry cannot present a client
certificate: `cast` offers only `-k`, which disables *server* verification and
still sends no client certificate, so the handshake fails with
`CertificateRequired`. Operator tooling therefore runs behind a local
TLS-terminating proxy holding the operator's `deployer` identity. This is how
operators run tooling against mutually authenticated endpoints in practice, not
a workaround. See ADR 0005.

**`--legacy --gas-price 0`.** `zeroBaseFee` makes gas free at the chain level;
it does not make clients *ask* for free gas. Without this, the upfront cost
check `gasLimit × maxFeePerGas` fails against a zero-balance account.

**`fs_permissions` in `foundry.toml`.** The deploy script reads the founding
consortium from a generated file outside `contracts/`. Foundry denies
filesystem access by default, which is the right default; the grant is
read-only and scoped to one directory.

Record deployed addresses in `network/config/<env>/deployed.md`. `broadcast/`
has them but is gitignored.

## What is committed and what is generated

Nothing cryptographic is committed. Generated and gitignored:

```
network/pki/out/                        CA tree, certificates, keystores
network/keys/<env>/                     devp2p node keys, member and deployer keys
network/genesis/<env>/genesis.json      derived from the validator keys
network/genesis/<env>/manifest.json     node -> address/pubkey mapping
network/config/<env>/static-nodes.json  peer list
network/config/<env>/deploy.json        founding consortium, joined
network/compose/compose.<env>.yml       IPs and host ports
```

Committed inputs, by contrast: `network/genesis/config/<env>.json` (the genesis
generator input) and `network/config/<env>/addressing.conf`.

The CI `pki` job rebuilds the whole CA tree from nothing on every push, which
proves the PKI is reproducible from the repository rather than from one
laptop's leftovers, then greps the git index for private key material and fails
if it finds any.

## Single sources of truth

Most of the tooling exists to stop one fact being written down twice.

| File | Authoritative for |
|---|---|
| `network/pki/openssl/orgs.conf` | which organisations exist |
| `network/pki/openssl/nodes.conf` | every end-entity certificate, and which nodes exist |
| `network/config/<env>/addressing.conf` | IP, RPC port, metrics port per node |
| `network/genesis/config/<env>.json` | chain ID, forks, QBFT timings |

`nodes.conf` is read by the PKI *and* by `gen-network.sh`, so a node without a
certificate, or a certificate without a node, is impossible rather than merely
unlikely. `addressing.conf` is read by the generator, by the compose override
it emits, and by the smoke test. The one time addressing lived in two places,
they disagreed and a node silently failed to peer.

## Generators

| Script | Produces | Needs |
|---|---|---|
| `network/pki/gen-root.sh` | root CA + issuance database | openssl |
| `network/pki/gen-intermediates.sh` | one CA per org, name-constrained | openssl |
| `network/pki/gen-leaves.sh` | end-entity certs from `nodes.conf` | openssl |
| `network/pki/gen-keystores.sh` | PKCS12 keystores + truststore | openssl, **docker** |
| `tools/gen-network.sh` | genesis, node keys, manifest | **docker**, jq |
| `tools/gen-static-nodes.sh` | peer list + compose override | jq |
| `tools/gen-deploy-config.sh` | `deploy.json`, member accounts | jq, **cast** |

All are idempotent and skip existing output. `FORCE=1` regenerates and always
deletes before writing, because key material is written read-only and cannot be
overwritten in place.

Regenerating the PKI mints a new keystore password, so every node must restart
afterwards. Fine in development; the m9 runbook owes a rotation procedure that
does not regenerate the tree.

## Tests

| Suite | Command | Proves |
|---|---|---|
| Contracts | `cd contracts && forge test` | governance rules and the validator floor |
| PKI | `make pki-test` | name constraints, offline, 7 assertions |
| Network | `make smoke` | the live network is healthy, 21 assertions |
| TLS | `make tls-test` | the live network rejects what it should, 7 assertions |

The smoke test checks what `docker compose ps` cannot: that every node agrees
on the validator set, that peers formed a mesh, that the chain is advancing,
and that `PUSH0` executes.

The TLS test opens with a *positive* control, because a network that is simply
down passes every negative assertion.

**Neither proves you are on the right chain.** See the first entry below.

## Failures we have already had

The symptom rarely resembles the cause.

**Renaming a compose project orphans its volumes, silently.** Containers start
against empty data directories, the chain begins at genesis, and all 21 smoke
assertions pass, because a brand new chain is a perfectly healthy chain. The
governance deployment was gone and nothing said so. What caught it was asking
whether a specific contract had code:

```bash
cast call <registry> "governor()(address)" --rpc-url http://127.0.0.1:8600
```

Liveness tests cannot distinguish *working* from *working on the wrong data*.
After any change to volumes, project names or environments, assert something
about identity, not health. Old volumes survive under the old project name and
can be copied across with `docker run --rm -v old:/from -v new:/to alpine sh -c 'cd /from && cp -a . /to/'`.

**Foundry cannot do mutual TLS.** `-k` disables server verification only. Use
the proxy; see the deployment section above.

**`zeroBaseFee` does not make clients ask for free gas.** `--legacy
--gas-price 0`, or `Upfront cost exceeds account balance` from a chain where
gas is free.

**Besu rejects `--static-nodes-file` entries with hostnames.** An enode URL must
carry an IP. devp2p identifies a peer by public key and treats the address as a
route; name resolution is outside the protocol. Symptom: `Illegal static enode
supplied`, and the node refuses to start.

**An openssl-built truststore contains zero trust anchors.** Java needs
certificates marked as *trusted certificate entries*, an attribute
`openssl pkcs12 -export -nokeys` does not write. Symptom: nothing. The node
starts, the listener comes up, the log is silent, every handshake fails.
Diagnose with:

```bash
openssl s_client -connect 127.0.0.1:8546 </dev/null 2>&1 | grep -A3 "Acceptable client"
```

An empty CA names list is conclusive. `gen-keystores.sh` uses `keytool` from
the Besu image and asserts the anchor count afterwards.

**Besu logs nothing at INFO when it rejects every RPC client.** A node can be
refusing all traffic and look healthy. Restart with `--logging=DEBUG` to make
it talk. Observability for this is m7's problem.

**`--rpc-http-tls-truststore-file` and `--rpc-http-tls-ca-clients-enabled` are
mutually exclusive.** Use the truststore: `ca-clients-enabled` resolves against
the JVM's default trust store, which is the public web PKI, so it would reject
every consortium client and accept anything signed by a public CA.

**Clients must use HTTP/1.1** (`--http1.1`). Besu's JSON-RPC is not an HTTP/2
service; curl negotiates h2 over TLS, the handshake succeeds, and the request
fails with a TLS internal error.

**Clients must present a chain, not a bare certificate.** The server trusts only
the root, so the issuing intermediate must come from the client. Use the
`.chain.pem` files.

**Anything the Besu container writes to a bind mount is root-owned.** Pass
`--user "$(id -u):$(id -g)"`. The generators do.

**`operator generate-blockchain-config` refuses an existing output directory.**
Mount the parent and let Besu create the leaf.

**`openssl ca` refuses to reissue for a subject it has already issued for**,
which blocks renewal. The setting lives in `index.txt.attr` beside the
database, written by openssl on first signature, so it must exist *before* the
first signing.

**openssl parses the whole config file on every invocation**, including sections
it will not use, so one unset `$ENV::` variable anywhere fails the command with
a line number and nothing else.

**The proxy can hold a stale docker network id** after the stack is recreated,
failing with `network ... not found`. `docker rm -f loc-<env>-rpc-proxy-1` then
`make proxy-up`.

**CRLF.** `make check-eol` runs in CI. A CRLF in a PEM file or a Besu config
surfaces as a TLS handshake failure or a config parse error, never as "you have
a CRLF".

## Conventions

Decisions go in `docs/adr/`, numbered in order of acceptance, never edited after
acceptance. An ADR with no consequences section is not a decision.

The running commentary, wrong turns included, goes in `docs/build-log.md`.

Comments in the generators explain *why*, because the scripts encode a dozen
non-obvious constraints that look arbitrary without them.

Contracts are pinned to solc 0.8.28 with `evm_version = "shanghai"`, and the
chain activates Shanghai at genesis via `shanghaiTime`. These must agree: a
compiler ahead of the chain emits opcodes the EVM rejects at call time while
the chain runs perfectly otherwise. The smoke test asserts `PUSH0` executes for
exactly this reason.

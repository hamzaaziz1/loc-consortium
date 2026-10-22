# Developer guide

How to run this network, what generates what, and the failures that cost a
session each so they only cost you a lookup.

`docs/adr/` is *why*. `docs/build-log.md` is *what happened*. This is *how*.

---

## Where things stand

| Milestone | State |
|---|---|
| m0 repo, CI, EOL hygiene | done |
| m1 PKI, name constraints | done |
| m2 six-node QBFT network | done |
| m3 mutual TLS on every endpoint | done |
| m4 governance, two paths | done |
| m5 letter of credit contracts | done |
| m6 terms privacy | done |
| m7 observability | done |
| m8 Helm and Kubernetes | not started |
| m9 runbook and threat model | not started |

**The network runs on contract validator selection.** Since the genesis
transition at block 17300, every node reads the validator set from
`ValidatorSetView`. Header voting is disabled: `qbft_proposeValidatorVote`
returns `Method not enabled`. The only way to change the validator set is a
governance vote.

**Deployed contracts** are recorded in `network/config/<env>/deployed.md`.
Treat `ValidatorSetView` as permanent: its address is in the genesis, so
changing it means a new transition and a coordinated restart of every node.

**One thing may be in flight.** A `TransferGovernance` vote was raised on local
to move governance to a Governor that supports `SetInfrastructure`. Check with:

```bash
cast call <registry> "governor()(address)" --rpc-url http://127.0.0.1:8600
```

If it still returns the old Governor, the vote is pending or expired; see
Governance operations below.

---

## Prerequisites

| Tool | Version used |
|---|---|
| Docker + Compose v2 | 29.x / 2.40 |
| Foundry | 1.7.1+ |
| OpenSSL | 3.x |
| jq | 1.7+ |
| Node | 20+ (controller) |
| Memory | ~5 GB per stack, ~7 GB with observability |

Work on the Linux filesystem, not under `/mnt/c`.

**One host-level step**, because `cast` and `forge script` have no `--resolve`:

```bash
echo "127.0.0.1 rpc-1.operator.loc.consortium rpc-2.operator.loc.consortium" | sudo tee -a /etc/hosts
```

---

## Environments

| | local | staging |
|---|---|---|
| Purpose | real chain state | rehearsal for risky operations |
| Chain ID | 7753 | 7754 |
| Subnet | 172.28.0.0/16 | 172.29.0.0/16 |
| RPC ports | 8545, 8546, 8551-8554 | 8645, 8646, 8651-8654 |
| Proxy | 8600 | 8700 |
| Prometheus / Grafana | 9090 / 3000 | 9190 / 3100 |
| Compose project | `loc-local` | `loc-staging` |

```bash
make up                      # local
LOC_ENV=staging make up      # staging
make help                    # shows which environment you are pointed at
```

Staging is **rebuilt, not preserved**: `LOC_ENV=staging make down` destroys it
and the generators recreate it in about ninety seconds, so every rehearsal
starts from a known state. Chain IDs differ deliberately, so a transaction
aimed at the wrong port is rejected rather than accepted.

The PKI is shared between environments. Chain material, addressing, compose
project and chain ID are not.

---

## Bootstrap, from a fresh clone

```bash
make pki                 # CA tree, certificates, keystores
make network-keys        # QBFT genesis + node keys          (docker)
make network-config      # static nodes + compose override
./tools/gen-permissions.sh   # initial allowlist, BEFORE nodes start
make up                  # six nodes
make smoke               # 22 assertions
```

`gen-permissions.sh` must run before `make up`. Besu refuses to start when
permissioning is enabled and the file is missing.

Then deploy and bring up the operator services:

```bash
make proxy-up
make deploy-config
cd contracts && forge script script/Deploy.s.sol:Deploy \
  --rpc-url http://127.0.0.1:8600 \
  --private-key "$(cat ../network/keys/local/deployer/key.priv)" \
  --broadcast --legacy --gas-price 0
cd ..

export REGISTRY_ADDRESS=<MemberRegistry from the output>
make controller-up
make observability-up
```

---

## The ops profile

`make up` is six Besu nodes. Everything else is opt-in, so the base stack stays
inside the memory budget.

| Service | Purpose |
|---|---|
| `rpc-proxy` | terminates TLS for Foundry, which cannot present a client certificate |
| `permissioning-controller` | reconciles allowlists against the registry |
| `prometheus` | scrapes nodes, controller, certificate expiry |
| `grafana` | the consortium dashboard, anonymous admin on loopback |
| `cert-metrics` | serves the certificate expiry textfile |

---

## Deploying contracts

Three things in the deploy command are not obvious.

**The RPC URL is the proxy, not a node.** Foundry cannot present a client
certificate: `cast -k` disables *server* verification and still sends none, so
the handshake fails with `CertificateRequired`. ADR 0005.

**`--legacy --gas-price 0`.** `zeroBaseFee` makes gas free at the chain level;
it does not make clients ask for free gas.

**`fs_permissions` in `foundry.toml`** grants read access to
`../network/config` so the script can read the founding consortium.

For an environment whose registry already exists, use
`DeployGovernorUpgrade.s.sol` instead: it deploys the replaceable parts and
**stops**, printing the proposals to raise. It cannot hand over governance,
because only a vote can.

---

## Governance operations

Proposal kinds are an enum, passed over RPC as an integer. **Count carefully**:

| Kind | Value | Payload |
|---|---|---|
| AddMember | 1 | `(string,address,bool,address[],string[])` |
| SetStatus | 2 | `(uint8)` |
| SetValidator | 3 | `(bool)` |
| AddAccount | 4 | `(address)` |
| RemoveAccount | 5 | `(address)` |
| AddEnode | 6 | `(string)` |
| RemoveEnode | 7 | `(uint256)` |
| TransferGovernance | 8 | `(address)` |
| SetInfrastructure | 9 | `(bytes32,address)` |

An out-of-range kind reverts with **no reason string**, so the only symptom is
`Execution reverted, data: "0x"`.

A full cycle, with the subject as 32 zero bytes when there is no member
subject:

```bash
G=<governor>; RPC=http://127.0.0.1:8600
ZERO=0x0000000000000000000000000000000000000000000000000000000000000000
cast send $G "propose(uint8,bytes32,bytes)" 3 $(cast keccak "logistics") \
  $(cast abi-encode "f(bool)" false) \
  --private-key $KEY --rpc-url $RPC --legacy --gas-price 0
ID=$(cast call $G "proposalCount()(uint256)" --rpc-url $RPC)
cast send $G "vote(uint256)" $ID --private-key $OTHER_KEY --rpc-url $RPC --legacy --gas-price 0
cast call $G "executionWindowOf(uint256)(uint64,uint64)" $ID --rpc-url $RPC
cast send $G "execute(uint256)" $ID --private-key $KEY --rpc-url $RPC --legacy --gas-price 0
```

Thresholds: a majority of active members, **excluding the subject**. With four
members, removing one needs two of the remaining three; anything with no
subject needs three of four.

Reductions in standing wait `EXECUTION_DELAY` blocks after passing. Local runs
600 blocks (~20 minutes); staging can deploy with short timings via
`GOV_VOTING_PERIOD`, `GOV_EXECUTION_DELAY`, `GOV_EXECUTION_WINDOW`.

The registry refuses any write leaving fewer than three active validators, so a
second removal passes its vote and then reverts with
`ValidatorFloorBreached(2, 3)`.

---

## Letter of credit operations

```bash
FACTORY=<factory> bash tools/loc-demo.sh     # full lifecycle, one command
bash tools/terms-seal.sh terms.json importer-bank exporter-bank
bash tools/terms-open.sh sealed.cms importer-bank <credit-address>
```

**No commercial terms are on chain.** The credit stores `TERMS_HASH`, the
keccak256 of canonical JSON, and `TERMS_LOCATOR`. Expiry is the one term held
on chain, because it must be enforceable and the carrier needs it.

Terms are sealed with CMS envelope encryption to `terms.<org>` certificates,
which carry `keyUsage: keyAgreement`. The client certificates carry
`digitalSignature` only and must not be used for key agreement.

Two things that will bite if changed:

**`jq -Sc` canonicalisation** is what makes the commitment reproducible between
parties. Without it, two parties with identical terms compute different hashes.

**`openssl cms -binary`** is mandatory. Without it OpenSSL canonicalises line
endings and the decrypted bytes differ from the input, failing verification far
from the cause.

---

## Observability

```bash
make cert-metrics        # refresh certificate expiry (run on a timer in anger)
make observability-up
```

Ten alert rules, each citing the decision that asked for it. Two things worth
knowing:

**Besu 26.8.1 exposes no consensus metrics.** No validator count, no round
changes. Round changes are the *leading* indicator of a stall, so that gap
matters; it is recorded under a `NOT MONITORED` heading at the end of
`alerts.yml` and covered for now by `make smoke`.

**Verify metric names against a running target before writing alerts.**
Prometheus loads rules referencing nonexistent metrics without complaint and
they never fire, so the monitoring looks complete and covers nothing:

```bash
curl -s http://127.0.0.1:9551/metrics | grep -oE '^besu_[a-z_]+' | sort -u
```

When a scrape fails, ask Prometheus why rather than theorising:

```bash
curl -s http://127.0.0.1:9090/api/v1/targets | jq -r '.data.activeTargets[] | "\(.labels.job) \(.health) \(.lastError)"'
```

---

## Tests

| Suite | Command | Asserts |
|---|---|---|
| Contracts | `cd contracts && forge test` | 63 tests: governance, floor, LoC lifecycle |
| Controller | `cd services/permissioning-controller && npm test` | 12: reconciliation logic |
| PKI | `make pki-test` | 7: name constraints, offline |
| Network | `make smoke` | 22: the live network is healthy |
| TLS | `make tls-test` | 7: the live network rejects what it should |
| Permissioning | `make perm-test` | 5: allowlists enforce membership |
| Privacy | `make privacy-test` | 9: sealed terms unreadable by non-recipients |

**None of the live suites prove you are on the right chain.** See the first
failure below.

---

## Failures we have already had

The symptom rarely resembles the cause.

**Renaming a compose project orphans its volumes, silently.** Containers start
against empty data, the chain begins at genesis, and all 22 smoke assertions
pass, because a new chain is a healthy chain. The deployment was gone and
nothing said so. Liveness cannot distinguish *working* from *working on the
wrong data*. After any change to volumes, projects or environments, assert
identity:

```bash
cast call <registry> "governor()(address)" --rpc-url http://127.0.0.1:8600
```

Old volumes survive under the old project name:
`docker run --rm -v old:/from -v new:/to alpine sh -c 'cd /from && cp -a . /to/'`

**`make up` and `make restart` do different things, and you often need both.**
`restart` picks up changed file *contents* (a genesis edit). `up` picks up
changed service *definitions* (a command or mount change). A genesis edit
followed by `make up` silently does nothing; a compose edit followed by
`make restart` silently keeps the old command. Use `make restart` after any
genesis change and verify:

```bash
docker exec loc-local-validator-importer-1 sh -c 'grep -c <transition-block> /genesis/genesis.json'
```

**Container users do not share your uid.** This has bitten three times: the
keystore password, the permissions file, and the certificate metrics textfile.
A correctly restrictive permission breaks a reader with a legitimate need.
Development files that containers must read are world readable, and the comment
in each script says what production changes.

**`ERROR_ALLOWLIST_PERSIST_FAIL` means Besu cannot *write* the permissions
file.** It proves at startup that it can, because `perm_add*` persists back to
it. So the file cannot be mounted read-only into nodes, and the controller is
the only intended writer by convention rather than constraint.

**An atomic rename is impossible through a bind-mounted *file*.** The mount is
the inode, not the name, so replacing it leaves every node reading the old one.
The controller writes in place, which is safe only because Besu's reload is
itself atomic and fails safe.

**Enum ordinals over RPC.** An out-of-range proposal kind reverts with no
reason string. Count from the table above rather than from memory.

**Foundry cannot do mutual TLS.** `-k` disables server verification only.

**`zeroBaseFee` does not make clients ask for free gas.** `--legacy
--gas-price 0`, or `Upfront cost exceeds account balance` on a chain where gas
is free.

**Besu rejects `--static-nodes-file` entries with hostnames.** An enode URL
must carry an IP: devp2p identifies peers by public key and treats the address
as a route.

**An openssl-built truststore contains zero trust anchors.** Java needs
certificates marked as trusted certificate entries, which
`openssl pkcs12 -export -nokeys` does not write. No error anywhere; every
handshake fails. Diagnose with:

```bash
openssl s_client -connect 127.0.0.1:8546 </dev/null 2>&1 | grep -A3 "Acceptable client"
```

An empty CA names list is conclusive. `gen-keystores.sh` uses `keytool` and
asserts the anchor count.

**Besu logs nothing at INFO when it rejects every RPC client.** Restart with
`--logging=DEBUG` to make it talk.

**`--rpc-http-tls-truststore-file` and `--rpc-http-tls-ca-clients-enabled` are
mutually exclusive.** Use the truststore: `ca-clients-enabled` resolves against
the JVM default trust store, which is the public web PKI.

**Clients must use `--http1.1`** and must present a `.chain.pem`, not a bare
certificate.

**Prometheus 3.x refuses unknown content types.** nginx serves `.prom` as
`application/octet-stream` and the scrape fails while the file is perfectly
readable. `default_type "text/plain; version=0.0.4"`.

**Nothing in this stack waits for its dependencies.** The proxy starts before
the node it fronts; the smoke test ran before nodes were ready; a genesis
change needs an explicit restart. The smoke test now polls for sixty seconds;
the others are runbook ordering steps.

**`operator generate-blockchain-config` refuses an existing output directory.**
Mount the parent and let Besu create the leaf.

**`openssl ca` refuses to reissue for a subject it has already issued for.**
The setting lives in `index.txt.attr`, written by openssl on first signature,
so it must exist *before* the first signing.

**openssl parses the whole config on every invocation**, so one unset `$ENV::`
anywhere fails the command with a line number and nothing else.

**CRLF.** `make check-eol` runs in CI. It surfaces as a TLS handshake failure
or a config parse error, never as "you have a CRLF".

---

## Single sources of truth

| File | Authoritative for |
|---|---|
| `network/pki/openssl/orgs.conf` | which organisations exist |
| `network/pki/openssl/nodes.conf` | every certificate, and which nodes exist |
| `network/config/<env>/addressing.conf` | IP, RPC port, metrics port per node |
| `network/genesis/config/<env>.json` | chain ID, forks, QBFT timings |

`nodes.conf` is read by the PKI *and* by `gen-network.sh`, so a node without a
certificate is impossible. `addressing.conf` is read by the generator, the
compose override it emits, and the smoke test.

## Generated, never committed

```
network/pki/out/                        CA tree, certificates, keystores
network/keys/<env>/                     node, member and deployer keys
network/genesis/<env>/                  genesis and manifest
network/config/<env>/static-nodes.json  peer list
network/config/<env>/deploy.json        founding consortium
network/config/<env>/permissions.toml   allowlists (controller writes this)
network/config/<env>/terms/             sealed and plaintext credit terms
network/compose/compose.<env>.yml       IPs and host ports
observability/textfile/                 certificate expiry metrics
```

CI rebuilds the whole CA tree from nothing on every push, then greps the git
index for private key material and fails if it finds any.

## Conventions

ADRs are numbered in order of acceptance and never edited after acceptance. An
ADR with no consequences section is not a decision.

Contracts pin solc 0.8.28 and `evm_version = "shanghai"`; the chain activates
Shanghai at genesis via `shanghaiTime`. These must agree, and `make smoke`
asserts `PUSH0` executes for exactly that reason.

Credits are immutable by design (ADR 0007). The factory is replaceable and
which factory is the consortium's is recorded in `InfrastructureRegistry`.

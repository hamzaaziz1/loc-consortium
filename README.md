# loc-consortium

A permissioned Hyperledger Besu consortium for the letter of credit lifecycle
in trade finance, between an importer bank, an exporter bank and a shipping
operator.

Four validators under QBFT, membership governed on chain, mutual TLS on every
endpoint with enforced X.509 name constraints, and commercial terms that never
touch the chain. Deployable with Docker Compose or Helm.

---

## The thing that shapes this repository

Besu has shed four enterprise features between 24.x and 26.x:

| Feature | Status in 26.8.1 |
|---|---|
| Onchain (smart contract) permissioning | removed in the 25.6.0 line |
| Tessera privacy groups | removed in the 25.6.0 line |
| Peer-to-peer TLS | early access, now absent |
| PKI-backed QBFT | announced for removal |

Besu is refocusing on being a mainnet Ethereum client, and consortium features
above the protocol are leaving it. That is a defensible decision on their part
and it is the organising fact here: **this project rebuilds what the client
dropped, at the layers where it now belongs**, and documents why each piece
sits where it does.

One hook survived: QBFT contract validator selection. That asymmetry produces
the central design.

## Two governance paths, because of what the client supports

**Validator set changes are enforced by consensus.** Every node reads
`getValidators()` from a contract. After the genesis transition,
`qbft_proposeValidatorVote` returns `Method not enabled`: an operator with full
RPC access to a validator cannot vote anyone in or out. The only route is a
proposal, a majority excluding the subject, and a delay.

**Node and account allowlist changes are enforced by a reconciling
controller**, because that hook was removed. The registry is still the
authority; only the enforcement point moved off chain.

Demonstrated on a live network: a two-of-three vote removed a validator and the
set followed while blocks continued. A second removal passed its vote and
reverted at execution with `ValidatorFloorBreached(2, 3)`, because the registry
refuses to drop below quorum. **Governance can decide something the registry
will not do.**

## What is demonstrated, not just configured

| Claim | Evidence |
|---|---|
| One member cannot impersonate another | A certificate minted by the real importer bank CA naming an exporter bank client is refused at the TLS handshake. `test/smoke/tls.sh` probe 4. |
| Governance cannot halt the chain | A second validator removal passes its vote and reverts at execution. Live on staging. |
| An operator cannot change the validator set | `qbft_proposeValidatorVote` → `Method not enabled`. |
| The carrier cannot read commercial terms | An active member, named party to the credit, holding a valid certificate under the consortium root, cannot decrypt. `test/privacy/terms.sh`. |
| A suspended member loses live credits immediately | Roles resolve through the registry on every call. `test_suspendedMemberLosesAccessToLiveCredits`. |
| The PKI is reproducible from the repository | CI rebuilds the entire CA tree from nothing on every push, then fails if any private key is tracked by git. |

## Test suites

| Suite | Count | Covers |
|---|---|---|
| Contracts (Foundry) | 63 | governance rules, the validator floor, the LoC lifecycle |
| Controller (Node) | 16 | allowlist reconciliation, the static node invariant |
| PKI | 7 | name constraints, offline |
| Network smoke | 22 | consensus agreement, peering, chain progress, EVM opcodes |
| TLS | 7 | what the live endpoints reject |
| Permissioning | 5 | allowlists match the registry and the loaded state |
| Privacy | 9 | sealed terms unreadable by non-recipients |

## Architecture

```
                   governance (on chain)
   Governor ──────────────┐
      │ propose/vote       │ setInfrastructure
      ▼                    ▼
   MemberRegistry ──► InfrastructureRegistry ──► LetterOfCreditFactory
      │  │                                            │
      │  └── ValidatorSetView ◄── QBFT reads this     ├─► LetterOfCredit
      │          (address fixed in genesis)           └─► LetterOfCredit
      │
      └── permissioning controller (off chain)
              └─► permissions.toml ──► six Besu nodes
```

The registry and the validator view are permanent: the view's address is fixed
in the genesis `transitions` block, so changing it means a coordinated restart
of every node. The Governor is replaceable, by vote. That split is why the
validator floor lives in the registry rather than the Governor.

## Letter of credit terms are never on chain

The contract stores a keccak256 commitment and a non-secret locator. Amount,
goods, pricing and documentary requirements are sealed off chain with CMS
envelope encryption to the two banks' encryption certificates.

Envelope rather than direct encryption, because certificates rotate annually
and a credit outlives a rotation: only the wrapped keys need rewrapping, not
the terms, and the commitment never changes.

That is what lets the carrier record shipment milestones against a credit whose
commercial content it cannot read, without private state.

## Quick start

```bash
make pki                      # CA tree, certificates, keystores
make network-keys             # QBFT genesis and node keys
make network-config           # static nodes and compose override
./tools/gen-permissions.sh    # initial allowlist, before nodes start
make up                       # six nodes
make verify                   # smoke + TLS suites
```

Then deploy governance and run a full credit lifecycle:

```bash
make proxy-up && make deploy-config
cd contracts && forge script script/Deploy.s.sol:Deploy \
  --rpc-url http://127.0.0.1:8600 --private-key "$(cat ../network/keys/local/deployer/key.priv)" \
  --broadcast --legacy --gas-price 0
cd .. && FACTORY=<address> bash tools/loc-demo.sh
```

On Kubernetes:

```bash
bash tools/kind-cluster.sh && bash tools/k8s-prepare.sh
helm upgrade --install loc deploy/helm/besu-consortium -n loc-consortium \
  -f deploy/helm/besu-consortium/values-kind.yaml \
  -f deploy/helm/besu-consortium/values-nodes.yaml
```

`docs/DEVELOPER.md` is the full guide, including eighteen failures already
encountered and how each presents.

## Decisions

| ADR | Decision |
|---|---|
| [0001](docs/adr/0001-record-architecture-decisions.md) | Record architecture decisions |
| [0002](docs/adr/0002-qbft-over-ibft2-and-clique.md) | QBFT over IBFT 2.0 and Clique |
| [0003](docs/adr/0003-pki-topology-and-name-constraints.md) | Two-tier PKI with per-organisation intermediates and name constraints |
| [0004](docs/adr/0004-certificate-lifetimes-revocation-and-key-custody.md) | Certificate lifetimes, revocation and key custody |
| [0005](docs/adr/0005-rpc-mutual-tls-design.md) | RPC mutual TLS, and the absence of transport security between nodes |
| [0006](docs/adr/0006-two-governance-paths.md) | Two governance paths, and why they differ |
| [0007](docs/adr/0007-no-contract-upgradeability.md) | Letters of credit are not upgradeable |
| [0008](docs/adr/0008-terms-privacy.md) | Terms are sealed off chain |
| [0009](docs/adr/0009-enode-addressing.md) | Peers are reached by IP address, not by name |

Every ADR carries a consequences section. An ADR with no costs is not a
decision.

## Known weaknesses

Named rather than hidden, with reasoning in
[`docs/threat-model.md`](docs/threat-model.md):

peer traffic between nodes is unencrypted, because the client has no p2p TLS;
seven processes can write the permissions file, because Besu requires it
writable; the operator's deployer account is privileged outside governance;
the permissioning layer has a propagation delay and fails open; sealed terms
have no forward secrecy; and in this deployment the consortium operator holds
the root CA, both RPC nodes and the controller certificate at once.

## Repository layout

```
contracts/      Foundry: governance and letter of credit contracts
network/        PKI, genesis, addressing, Compose stack
services/       permissioning controller
deploy/helm/    Helm chart and Kubernetes notes
observability/  Prometheus, Grafana, alert rules
test/           PKI, smoke, TLS, permissioning and privacy suites
tools/          generators and operational scripts
docs/           ADRs, developer guide, runbook, threat model, build log
```

## Licence

Apache-2.0.

# loc-consortium

A permissioned Hyperledger Besu consortium network for the letter of credit (LoC)
lifecycle in trade finance, between an importer bank, an exporter bank, and a
shipping/logistics party.

This is an infrastructure and governance project first, and a smart contract
project second. The interesting parts are the consensus choice, the two
governance paths, the PKI, and the privacy model.

## Design in one paragraph

Six Besu nodes run QBFT: four validators (one per consortium member plus a
consortium operator) and two non-validator RPC nodes. Membership is governed
on chain. Validator set changes execute through the QBFT validator smart
contract hook, which the client still supports. Node and account allowlist
changes execute through a reconciling controller service, because Besu removed
the onchain permissioning contract hook in the 25.6.0 line. Every node talks
TLS from a private CA, and RPC endpoints require mutual TLS. LoC terms are
never written to shared state; only per-party encrypted payloads and their
hash commitments are, so the logistics party can verify shipment milestones
without reading commercial terms.

See `docs/adr/` for why each of those choices was made.

## Status

| Milestone | Scope | State |
|---|---|---|
| m0 | Repo skeleton, EOL hygiene, ADR 0001-0002, CI bootstrap | in progress |
| m1 | Private CA, intermediate per org, node and RPC certs, cert-to-role map | todo |
| m2 | 4 validator + 2 RPC QBFT network on Docker Compose | todo |
| m3 | devp2p TLS, RPC mutual TLS, rejection test | todo |
| m4 | MemberRegistry, Governor, permissioning-controller | todo |
| m5 | LoC state machine, RBAC bound to registry, Foundry tests | todo |
| m6 | Commitment-based privacy layer, non-member read test | todo |
| m7 | Prometheus, Grafana, QBFT alerting | todo |
| m8 | Helm chart, kind deploy, EKS/AKS deltas | todo |
| m9 | Runbook, threat model, demo script | todo |

## Layout

```
docs/          ADRs, architecture notes, runbook, threat model
network/       PKI, genesis, per-node config, Compose stack
contracts/     Foundry project: governance and LoC contracts
services/      permissioning-controller, loc-api
deploy/        Helm chart and environment values
observability/ Prometheus config, Grafana dashboards, alert rules
test/          Network smoke test and privacy tests
tools/         Key generation, genesis assembly, helper scripts
```

## Requirements

Docker with Compose v2, Foundry, OpenSSL 3.x, jq, Node 20+, and roughly 6 GB of
free memory. Every Besu JVM is heap-capped so the full stack fits on a laptop.

## Licence

TBD

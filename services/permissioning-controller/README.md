# Permissioning controller

Reconciles each node's permissions file against the on-chain `MemberRegistry`.

## Why it exists

Besu removed its onchain permissioning hook in the 25.6.0 line but kept
file-based local permissioning and the `PERM` API. The registry is still the
authority on membership; only the enforcement point moved off chain.

Validator set changes need none of this, because the QBFT validator contract
hook survived. One repository, two governance paths, differing because of what
the client supports rather than by preference. See ADR 0006.

## How it works

Reconciliation, not deltas. Every pass reads the whole registry, computes what
the allowlists should be, and writes that. Events are a trigger, never the
data.

Delta application drifts: miss one event and the allowlist is permanently wrong
with nothing to detect it. Reconciliation is idempotent, so a controller that
missed an hour catches up by doing exactly what it always does.

The file is written to a temporary path and renamed, which is atomic, so a node
reloading concurrently never reads a half-written file. A malformed file is
rejected wholesale by `perm_reloadPermissionsFromFile` and the node keeps its
previous allowlist, so a bad write fails safe.

## Failure behaviour

Fails open. If the controller dies the allowlists freeze and the network keeps
running with a stale membership view.

The alternative, nodes refusing connections they cannot verify against a
current registry, would make this a single point of failure for a consortium
whose point is that no single party can halt it.

What makes that defensible: PKI revocation is an immediate independent path
that does not involve this service. Revoke an organisation's intermediate and
it cannot complete a TLS handshake whatever any allowlist says.

The cost is a propagation delay, so the delay is measured. Every pass writes
`heartbeat.json` with the block it last reconciled. A heartbeat falling behind
is alertable in m7 and an incident in the m9 runbook.

## Configuration

| Variable | Required | Meaning |
|---|---|---|
| `REGISTRY_ADDRESS` | yes | the `MemberRegistry` |
| `NODE_URLS` | yes | comma separated `https://<node>:<port>` |
| `INFRASTRUCTURE_ENODES` | no | nodes belonging to no member, allowlisted from static config |
| `PERMISSIONS_FILE` | no | default `/perm/permissions.toml` |
| `HEARTBEAT_FILE` | no | default `/perm/heartbeat.json` |
| `TLS_CA`, `TLS_CERT`, `TLS_KEY` | no | the operator's `controller` identity |
| `INTERVAL_MS` | no | default 10000 |

`TLS_CERT` must be the certificate **chain**: the nodes trust only the root, so
the issuing intermediate has to come from this side.

The `controller` certificate is the most sensitive end-entity certificate in the
network, because possession of it is possession of the ability to change who
may connect. It carries `clientAuth` only, so a leak cannot stand up a
convincing endpoint.

## Tests

`npm test` covers the reconciliation logic without a chain. The live behaviour,
that a removed member actually loses access, is `test/smoke/permissioning.sh`
at the repository root.

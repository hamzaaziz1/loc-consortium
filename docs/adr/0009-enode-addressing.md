# ADR 0009: Peers are reached by IP address, not by name

- Status: Accepted
- Date: 2026-10-26

## Context

Deferred from m2, where the decision was made under pressure, and written now
because m8 proved what it costs.

Besu's static node list rejects enode URLs containing hostnames. The node
refuses to start with `Illegal static enode supplied`.

This was not obvious. Every other layer of this network is addressed by name:
TLS certificates assert `validator-1.importer-bank.loc.consortium`, the proxy
verifies that name, and the smoke test resolves it. The instinct was to use the
same names for peers.

**That instinct is wrong, and the reason is not a Besu limitation.** devp2p
identifies a peer by its public key. The address in an enode URL is a route to
it, nothing more: the handshake proves possession of the private key matching
the public key in the URL, and an attacker who redirected the address would
still fail the handshake. Name resolution is therefore outside the protocol by
design.

Trying to put names there was importing a TLS-layer habit into a peer-to-peer
layer where identity works differently.

## Decision

Enode addresses are IP addresses, resolved as late as the deployment model
allows.

**Docker Compose:** fixed addresses on an explicit subnet, defined once in
`network/config/<env>/addressing.conf` and emitted into both the static node
list and the Compose override by one generator, so an address is written down
exactly once.

**Kubernetes:** a StatefulSet per node behind a headless service gives each pod
a stable DNS name, and an init container resolves those names to addresses at
startup, writing the peer list inside the pod where the addresses exist.

Certificate names remain names. They are doing real work at the TLS layer and
nothing at the peer layer, which is the distinction this ADR exists to record.

## Consequences

### What this forced in Kubernetes

Three things that only appeared by running it.

`publishNotReadyAddresses: true` on the headless service. Readiness depends on
peering and peering depends on resolution, so if DNS waited for readiness the
network could never form. Peer-to-peer workloads differ from ordinary services
precisely here.

The init container retries for two minutes, because on a cold start a peer's
pod may not exist yet and a missing entry means that node can never be dialled.
Waiting beats writing a list that is quietly incomplete.

**The node allowlist is the same problem.** On Compose the allowlist and the
peer list come from different places and both hold fixed addresses. In
Kubernetes neither address exists until scheduling, so the allowlist cannot be
prepared ahead of time either: a file written in advance describes a network
that does not exist, and Besu refuses to start when a static node is missing
from its allowlist. The init container therefore builds both from the same
resolution.

That is a genuine architectural difference between the two deployment models
rather than a porting detail, and it is the most interesting thing m8 produced.

### Costs

A node that changes address needs every other node's static list regenerated
and every node restarted. On Compose that is a renumber; in Kubernetes it
happens automatically on reschedule, which is the better property.

Adding a member therefore has a step that does not follow from governance: the
new node must appear in the static list before existing nodes will dial it. The
allowlist permits; the static list dials. They are different things, and the
runbook says so.

### What was rejected

**Bootnode discovery** avoids the problem by not using static nodes. Rejected
in m2 and still rejected: in a consortium every peer is known in advance, so
discovery buys nothing and a bootnode becomes a single point of failure for
node joins.

**EIP-1459 DNS discovery**, which Besu does support, is a different mechanism
entirely: it fetches a peer list published as DNS TXT records for public
networks. It does not make the static node parser resolve hostnames.

**Fixed pod IPs** via a CNI that supports them ties the chart to one cluster
configuration and is not portable.

## Revisit if

Besu's static node parser gains hostname support, which would simplify the
Kubernetes path considerably but would not change the reasoning: the address
would still be a route rather than an identity.

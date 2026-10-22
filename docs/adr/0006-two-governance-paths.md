# ADR 0006: Two governance paths, and why they differ

- Status: Accepted
- Date: 2026-10-22

## Context

Membership in this consortium controls four things: which addresses may
transact, which nodes may connect, which members validate, and which
certificate namespace they own. ADR 0003 made the last of those a single
revocation at the PKI layer. This ADR covers the first three.

The original specification assumed Besu's smart-contract permissioning: a
contract that nodes consult to decide who may connect. That hook was removed in
the 25.6.0 line, along with Tessera privacy, and peer-to-peer TLS is absent
from 26.8.1 as well. Besu is refocusing on being a mainnet Ethereum client, and
consortium features above the protocol are leaving it.

**One hook survived: QBFT contract validator selection.** A contract
implementing `getValidators()` can determine the validator set, and the client
still supports it in 26.x.

That asymmetry, one hook kept and one removed, is what shapes everything here.
It is not a design preference.

## Decision

### Validator set changes are enforced by consensus

QBFT reads the validator set from `ValidatorSetView`, a stateless contract
whose only function returns the active validators from the registry. Its
address is fixed in the genesis `transitions` block.

A governance vote therefore changes who produces blocks as a direct
consequence. There is no operator in the loop and no way for an operator to
diverge from the vote. After the transition, Besu disables the header-voting
RPC entirely: `qbft_proposeValidatorVote` returns `Method not enabled`. An
operator with full RPC access to a validator cannot vote anyone in or out.

Verified on the live network: a two-of-three vote removed a validator and the
set followed, while blocks continued. A second removal passed its vote and then
reverted at execution with `ValidatorFloorBreached(2, 3)`, because the registry
refuses to drop below three active validators. Governance can decide something
the registry will not do, and the chain keeps its quorum.

### Node and account allowlist changes are enforced by a reconciling controller

Besu kept file-based local permissioning and the `PERM` API. So the registry
remains the authority on membership and a service enforces it: it reads the
registry over mutual TLS, computes the allowlists, writes each node's
permissions file, and calls `perm_reloadPermissionsFromFile`.

**Reconciliation, not deltas.** Every pass reads the whole registry and writes
what the file should contain. Events trigger a pass; they are never the data.

Delta application drifts. Miss one event and the allowlist is permanently wrong
with nothing to detect it. Reconciliation is idempotent, so a controller that
was down for an hour catches up by doing exactly what it always does, and a node
that restarts reads correct state from its file without needing a replay.

### The controller fails open

If the controller dies, the allowlists freeze and the network runs on a stale
membership view. A member voted out an hour ago can still connect.

The alternative, nodes refusing connections they cannot verify against a
current registry, would make this service a single point of failure for a
consortium whose entire point is that no single party can halt it. That is a
worse failure than staleness.

What makes it defensible rather than lazy: **PKI revocation is an immediate,
independent path that does not involve the controller at all.** Revoke an
organisation's intermediate and it cannot complete a TLS handshake whatever any
allowlist says. Two paths, one slow and automatic, one immediate and manual,
and the fast one has no single point of failure.

The cost is a propagation delay, so the delay is measured rather than assumed.
Every pass writes a heartbeat with the block it last reconciled. A heartbeat
falling behind is alertable in m7 and an incident in the m9 runbook, because a
service that fails open fails invisibly and the heartbeat is the only way to
notice.

### The authorisation boundary is the registry, not the allowlist

The permissions file is an enforcement point with a propagation delay. It is
not where authorisation is decided. The same separation as ADR 0003's rule that
a certificate asserts identity rather than granting permission.

## Consequences

### What this makes easy

Membership is one vote and one audit trail, whichever layer enforces it.
Validator governance cannot be bypassed by an operator at all. Allowlist
governance converges automatically from any state, including after an outage.

### Accepted weaknesses, stated rather than buried

**Seven processes have write access to one file.** Besu opens the permissions
config read-write and proves at startup that it can write it, because the
`perm_add*` RPC methods persist allowlist changes back to the file. Mounting it
read-only makes every node refuse to boot with
`ERROR_ALLOWLIST_PERSIST_FAIL`. So the controller is the only *intended* writer
by convention, not by constraint: anyone with admin RPC on a node can widen
that node's allowlist and have Besu persist it. The next reconcile overwrites
it, so the registry wins eventually, but there is a window.

The available mitigation is removing `ADMIN` and `PERM` from the RPC API list
on nodes that do not need them, which is m9 hardening work rather than
something this ADR resolves.

**Infrastructure accounts are a standing privilege granted outside
governance.** With account permissioning enabled, only allowlisted accounts can
transact, and the deployer is not a member. Without a static allowlist entry,
no account could deploy anything. The operator's RPC nodes are allowlisted the
same way, so that application access survives membership changes. These entries
come from configuration rather than from a vote, which is a real gap and is
named in the threat model.

**Validator removal and allowlist removal are not simultaneous.** A member
removed by vote stops validating at the next block and stops being allowed to
connect within a reconcile interval. Those are seconds apart, not atomic, and
nothing coordinates them.

**Transitions are Besu-specific.** Using them to reach contract validator
selection forecloses the mixed-client QBFT option that ADR 0002 listed among
QBFT's advantages. Interoperability was explicitly not a requirement, so this
is an amendment rather than a reversal, but ADR 0002 should be read with it.

## Revisit if

A client regains onchain permissioning, which would collapse the two paths into
one. Or if the consortium grows past the point where `getValidators()`
iterating members is acceptable: linear is fine at four and would need
rethinking at forty, and that function is called by every node on every block.

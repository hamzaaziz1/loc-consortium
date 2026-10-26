# Runbook

Procedures for operating the consortium.

Every entry here has been executed against a running network, on `staging` or
`local`, unless it says otherwise. A procedure nobody has run is a guess, and
the ones that are guesses say so.

| Procedure | When |
|---|---|
| [Daily checks](daily-checks.md) | routine |
| [Diagnosing a network that looks healthy](false-health.md) | first, always |
| [Recovering a stalled QBFT round](qbft-stall.md) | no blocks |
| [Adding a member](add-member.md) | governance decision |
| [Removing or suspending a member](remove-member.md) | governance decision |
| [Replacing the Governor](replace-governor.md) | governance upgrade |
| [Moving to contract validator selection](validator-transition.md) | one-off per chain |
| [Rotating certificates](rotate-certificates.md) | annually, or on compromise |
| [Permissioning controller incidents](controller-incident.md) | heartbeat alert |
| [Restoring a node](restore-node.md) | data loss |

## The rule that applies to all of them

**Assert identity, not health.** This network has repeatedly presented as
perfectly healthy while being wrong: a new empty chain passes every liveness
check, because a new chain is a healthy chain. Before concluding that anything
works, check that it is the *right* thing:

```bash
cast call <registry> "governor()(address)" --rpc-url http://127.0.0.1:8600
```

A contract with no code means you are not on the chain you think you are on.

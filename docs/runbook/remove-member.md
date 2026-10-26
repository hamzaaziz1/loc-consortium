# Removing or suspending a member

**Rehearsed** end to end on staging, including the floor refusing a second
removal.

## Decide which

`Suspended` keeps the member's identity and history while removing its
allowlist entries and its ability to validate or act on live letters of
credit. Reversible by vote.

`Removed` is terminal. A returning organisation is added as a new entry, so the
original audit trail is never overwritten.

From the allowlist's point of view they are identical: anything not `Active`
is out.

## If the member validates, drop the flag first

```bash
cast send $GOVERNOR "propose(uint8,bytes32,bytes)" 3 $(cast keccak "logistics") \
  $(cast abi-encode "f(bool)" false) \
  --private-key $KEY --rpc-url $RPC --legacy --gas-price 0
```

Kind `3` is `SetValidator`. Needs a **majority excluding the subject**: with
four members, two of the remaining three. The subject cannot vote on its own
removal, which is what stops a member filibustering its own exit.

**The floor will refuse a removal leaving fewer than three validators.** The
proposal passes its vote and then reverts at execution with
`ValidatorFloorBreached(2, 3)`. That is the registry protecting quorum, not a
fault. Grow the validator set before removing a second member.

## Then the status change

Kind `2` (`SetStatus`), payload `(uint8)`: 2 for Suspended, 3 for Removed.

Reductions in standing wait `EXECUTION_DELAY` blocks after passing: 600 on
local, about twenty minutes. The window exists so the member can see it coming
and the others can notice a hostile proposal passing.

## Immediate removal

Governance is deliberately slow. If a member must be cut off **now**, revoke
its intermediate at the PKI layer: it then cannot complete a TLS handshake,
whatever any allowlist says. That path does not depend on the controller or on
block production.

Follow it with the governance vote. Certificate revocation stops traffic; only
the registry changes the authoritative membership.

## Known gap

Validator removal and allowlist removal are not atomic. A member stops
validating at the next block and stops being allowed to connect within a
reconcile interval. Seconds apart, with nothing coordinating them.

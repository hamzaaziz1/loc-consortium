# ADR 0007: Letters of credit are not upgradeable

- Status: Accepted
- Date: 2026-10-22

## Context

A letter of credit is a legal instrument. Its value to the parties is precisely
that its terms are fixed: the beneficiary ships goods against a promise whose
wording cannot change after it was relied upon, and the issuing bank's
obligation is defined by the credit as issued.

Standard practice for Solidity in 2026 is a proxy, so that bugs can be fixed
without redeploying. Applying that reflexively here would be a mistake, and
this ADR explains why, because "we chose not to use a proxy" invites the
assumption that the author did not know how.

## Options considered

### A transparent or UUPS proxy per credit, or a shared implementation

Bugs become patchable. The implementation behind a live credit can be replaced
and the credit continues with corrected behaviour.

The problem is what it does to the instrument. A credit whose behaviour can
change mid-flight is a credit whose terms can change mid-flight, by whoever
controls the upgrade. The beneficiary's assurance becomes "the code says X, and
the consortium has not yet decided it says Y". That is weaker than the paper
process it replaces, and the weakness falls on the party with the least power:
the beneficiary has already shipped.

Governance control of the upgrade key does not resolve this. A majority vote
could alter the behaviour of a credit a minority is relying on, which is the
same problem with more steps.

### A single contract holding many credits

Rejected for a related reason: every credit shares a fate. A bug fix, a storage
migration or a mistaken upgrade touches all of them at once, including ones in
the middle of their lifecycle.

### One immutable instance per credit, from a replaceable factory

Chosen. Each credit is its own contract with no upgrade path. A bug is fixed by
deploying a new factory and issuing new credits under it; existing credits run
to completion under the code they were created with.

## Decision

`LetterOfCredit` is immutable. `LetterOfCreditFactory` is replaceable, and
which factory is the consortium's is recorded on chain in
`InfrastructureRegistry` and changed by governance vote.

That last part closes a gap that is easy to miss. An application asking whether
an address is a genuine credit calls `factory.isCredit(address)`, which means
nothing unless every party agrees which factory. Without an on-chain answer the
factory address is configuration passed out of band, and a member could deploy
its own factory and issue credits indistinguishable from real ones.

### Why the infrastructure pointer is not in MemberRegistry

The obvious place is a field on the member registry. That is wrong, and the
implementation cost is what revealed it.

QBFT reads the validator set through a view whose registry pointer is immutable
and whose address is fixed in the genesis `transitions` block. Changing
`MemberRegistry` therefore means a new view, a new transition, and a
coordinated restart of every node in the consortium. It cannot practically be
replaced, which means it must stay minimal: anything added to it for
convenience is permanent.

So `InfrastructureRegistry` is separate, and it stores no governor of its own.
Its authority is whoever governs the member registry, read live on every call.
Replacing the Governor therefore carries over automatically, with no second
transfer to remember and nothing that can drift out of step.

## Consequences

### Accepted costs, stated rather than softened

**A bug in a live credit cannot be patched.** It can only be worked around by
agreement between the parties, off chain. This is the real cost and it is not
small. It is also exactly what happens with the paper process, where a defect
in a credit's wording is resolved by amendment with the beneficiary's consent
rather than by the issuing bank rewriting it.

**Correctness has to be front-loaded.** Without an upgrade path, the tests and
the review are the only defence. Twenty-five tests cover the lifecycle, the
role checks and the state machine's refusals, which is a floor rather than a
ceiling; an audit would be the next step for anything carrying real value.

**Deployment cost per credit.** A new contract for each credit costs more gas
than a record in a shared one. On a zero-base-fee consortium chain this is
irrelevant, and saying so is honest rather than evasive: the trade would need
rethinking on a chain where gas is priced.

**Retiring a factory does not retire its credits**, by design. Credits issued
under a superseded factory remain valid and continue to completion. An
application must therefore accept credits from more than one factory address
during a transition, and the infrastructure registry's event log is what makes
the set of legitimate factories reconstructible.

### What this makes easy

A credit's behaviour is fixed at issuance and verifiable from its bytecode.
Instances are independent, so one credit's state cannot affect another's. And
the thing most likely to need changing, the issuance logic, is the thing that
is replaceable.

## Revisit if

A credit ever carries on-chain value rather than a commitment to an off-chain
settlement. The calculus changes when a bug can strand funds rather than
requiring a conversation, and at that point an escape hatch with narrow,
governance-controlled scope becomes worth its cost.

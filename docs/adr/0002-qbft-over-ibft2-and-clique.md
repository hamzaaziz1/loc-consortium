# ADR 0002: QBFT over IBFT 2.0 and Clique

- Status: Accepted
- Date: 2026-09-22

## Context

The consortium has three commercial members (importer bank, exporter bank,
logistics operator) plus a consortium operator. Members are known and
contractually bound, so Sybil resistance is not a requirement. What is required:

1. **Immediate finality.** A letter of credit moving to "documents accepted" or
   "payment released" must not be reversible by a reorg. Settlement finality is
   a legal property here, not a performance tuning knob.
2. **Byzantine tolerance, not just crash tolerance.** Members are competitors.
   The threat model includes a member whose node equivocates, not only one whose
   node is offline.
3. **Validator set governance that can be driven on chain.** Membership changes
   are a governance action with a proposal and a vote, not an SSH session.
4. **A documented recovery path** for the case where validator quorum is lost.

Besu offers Clique, IBFT 2.0 and QBFT for private networks.

## Options considered

### Clique (proof of authority)

Signers take turns producing blocks. Rejected on requirement 1. Clique offers
probabilistic finality only: a network partition lets both sides continue
producing competing chains, which reconcile by fork choice when the partition
heals. A block containing an LoC payment release can be reorged out. Clique also
assumes a majority of honest signers rather than tolerating Byzantine behaviour
explicitly, which fails requirement 2.

Clique is the right answer for a shared dev environment. It is the wrong answer
for anything with a settlement obligation attached.

### IBFT 2.0

A genuine BFT protocol with immediate finality, so it satisfies requirements 1
and 2. Rejected on requirements 3 and 4.

IBFT 2.0 manages its validator set exclusively through block header voting:
validators vote via the `ibft_proposeValidatorVote` RPC and the result is
encoded into the header `extraData`. There is no hook that lets a smart contract
determine the validator set. That would force the governance design into a shape
where the on-chain Governor contract is advisory and an operator manually
mirrors its outcome into RPC calls, which is exactly the trust gap this project
exists to close.

IBFT 2.0 also has a weaker round change story. Its round change handling is
known to admit liveness edge cases that QBFT's justification-carrying round
change messages were designed to address.

### QBFT

BFT with immediate finality, and the current recommended BFT consensus for new
Besu private networks. It satisfies all four requirements.

Decisive factor: QBFT supports two validator selection modes, `blockheader` and
`contract`. In contract mode the validator set is read from a smart contract
that implements `getValidators() external view returns (address[] memory)`.
This hook survived the 25.6.0 removals that took out onchain permissioning, and
remains in the client in the 26.x line.

That means validator set governance can be genuinely on chain: a proposal and a
vote in the Governor contract changes the validator set as a direct consequence
of the vote, with no operator in the loop and no way for an operator to diverge
from the vote.

QBFT is also the BFT algorithm shared with GoQuorum, so a member running
GoQuorum could join the same network. Not a requirement today, but in trade
finance the counterparty rarely runs the stack you picked.

## Decision

QBFT, in `contract` validator selection mode, with a validator contract governed
by the Governor introduced in m4.

Network sizing: 4 validators, giving `n = 3f + 1` with `f = 1`. One member's
validator can be Byzantine or offline and the network continues with finality
intact. Two non-validator RPC nodes serve application traffic so that client
load never touches block production.

Genesis parameters: `blockperiodseconds: 2`, `requesttimeoutseconds: 4`,
`epochlength: 30000`.

Bootstrap order: the network starts in `blockheader` mode because the validator
contract cannot exist before genesis. Once the Governor and validator contract
are deployed, a `transitions` entry moves the chain to `contract` mode at a
chosen block.

## Consequences

**Accepted costs.**

Four validators tolerate exactly one faulty validator. Losing two halts the
chain. That is the correct trade for a four-member consortium, but it means
validator availability is a contractual obligation on members, and the runbook
must treat a second validator failure as a declared incident rather than a
routine event.

Contract validator mode adds a failure mode that block header mode does not
have: if the validator contract returns a bad set, or quorum is lost such that
no transaction can be mined to vote validators back in, the chain stalls and
cannot fix itself on chain. Besu documents the escape hatch, and the runbook
implements it: add a `transitions` entry switching to `blockheader` mode at an
upcoming block with a hand-specified validator set sufficient to make progress,
restart nodes, deploy or repair the contract, then transition back to
`contract` mode. This requires coordinated action by node operators and is the
main reason the m9 runbook exists.

Contract validator mode has historically interacted badly with some fork
configurations, so the genesis fork settings are pinned and any fork change is
validated against a throwaway network before it reaches the consortium chain.

**What this makes easy.**

Validator governance and membership governance share one contract surface and
one audit trail. Finality means the LoC state machine never needs reorg-aware
logic. QBFT metrics expose round changes directly, which makes "is consensus
healthy" a Grafana panel rather than a log grep.

## Revisit if

A fifth commercial member joins, which changes the fault tolerance arithmetic
and is worth re-sizing around (`n = 7` tolerates two faults). Or if a member
requires a client Besu cannot interoperate with.

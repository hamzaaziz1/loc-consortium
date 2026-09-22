# ADR 0001: Record architecture decisions

- Status: Accepted
- Date: 2026-09-22

## Context

This network makes several choices that are not obvious from the code and that
a reviewer, auditor or operator will question: the consensus algorithm, the
split between on-chain and off-chain governance, the certificate hierarchy, and
the privacy model. Several of these exist because features were removed from the
client, which is invisible from the repository alone.

Undocumented decisions get re-litigated, or worse, silently reversed by someone
who assumes the current shape was accidental.

## Decision

Use Architecture Decision Records in the format described by Michael Nygard.
One decision per file, numbered sequentially, immutable once accepted.
Superseding ADRs reference the ADR they replace.

Every ADR must state what the decision costs. An ADR with no consequences
section is not a decision, it is an advertisement.

## Consequences

Decisions carry their reasoning with the code, so a reviewer can evaluate
judgement rather than just output. The cost is discipline: a decision made in
chat and never written down is effectively undocumented.

## Revisit if

Never. If this process is wrong, that is itself an ADR.

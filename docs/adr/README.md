# Architecture Decision Records

Each ADR records one decision, the context that forced it, and what it costs.
An ADR is never edited after acceptance. If a decision changes, write a new ADR
and mark the old one superseded.

ADRs are numbered in the order they are accepted, not grouped by subject.

| ADR | Decision | Status |
|---|---|---|
| [0001](0001-record-architecture-decisions.md) | Record architecture decisions | Accepted |
| [0002](0002-qbft-over-ibft2-and-clique.md) | QBFT over IBFT 2.0 and Clique | Accepted |
| [0003](0003-pki-topology-and-name-constraints.md) | Two-tier PKI with per-organisation intermediates and name constraints | Accepted |
| [0004](0004-certificate-lifetimes-revocation-and-key-custody.md) | Certificate lifetimes, revocation distribution and key custody | Accepted |

Expected next, in roughly this order:

- on-chain governance replacing the removed permissioning hooks (m4)
- contract upgradeability (m5)
- privacy via per-party encryption and hash commitments (m6)

# ADR 0004: Certificate lifetimes, revocation distribution and key custody

- Status: Accepted
- Date: 2026-10-03

## Context

ADR 0003 settled the shape of the PKI and deliberately deferred three
operational questions. The hierarchy now exists, so they have to be answered.

1. How long does each kind of certificate live?
2. How does a party learn that a certificate has been revoked?
3. Who holds which private key, and what happens when one is lost?

These are not independent. Short lifetimes substitute for revocation, and both
depend on whether renewal is automated. Getting the combination wrong produces
either an outage or a control that only appears to work.

## Decision

### Lifetimes

| Certificate | Validity | Reasoning |
|---|---|---|
| Root CA | 10 years | Rotating it means re-establishing trust on every node in the consortium. Tolerable only because the key is used rarely and kept offline. |
| Organisation intermediate | 5 years | Half the root's life, so every intermediate is replaced at least once before the root expires and the rotation procedure gets exercised rather than theorised. |
| Node certificate | 365 days | Annual rotation is frequent enough to keep the runbook honest and rare enough to survive manual renewal. |
| Client certificate | 365 days | Same, for now. See below. |

The principle: **certificate lifetime should be inversely proportional to how
automated renewal is.** Ninety-day client certificates are better security and
would be irresponsible here, because renewal in this repository is a human
running a script. A short-lived certificate with no automated renewal is an
outage with a scheduled start date.

Client certificates are the ones to shorten first once renewal is automated,
because they are the most numerous, the most widely distributed, and the least
disruptive to replace.

### Revocation

Each CA publishes a certificate revocation list, regenerated whenever something
is revoked and at least every 30 days so a stale list is detectable. The
`crl_extensions` and `default_crl_days` settings for this are already in both
CA configs.

**Revocation is a secondary control in this design, and member removal does not
depend on it.** This is the substantive decision in this ADR.

The reasoning: CRL checking is off by default in the JVM path validation that
Besu relies on, CRL propagation timing is not something the consortium
controls, and a peer that does not check will happily accept a revoked
certificate. A control whose enforcement cannot be verified is not a control
you build member removal on.

So removal is enforced at the permissioning layer instead. A governance vote
removes the member from the on-chain registry, the m4 controller applies that
to every node's allowlist, and the removed node is disconnected regardless of
what its certificate says. That path has deterministic timing, is observable on
chain, and produces an audit trail. The CRL exists alongside it for parties
that do check and for after-the-fact attestation that a certificate was
withdrawn.

Issued certificates carry no CRL distribution point URI, because there is no
HTTP infrastructure in this deployment to serve one. CRLs are distributed as
files alongside the trust bundle. A production deployment would stand up an
internal distribution endpoint, and that is the first thing to add if any party
in the consortium insists on revocation as a primary control.

### Key custody

| Key | Held by | At rest |
|---|---|---|
| Root CA | Consortium operator, offline | `chmod 400`, outside any node's filesystem |
| Organisation intermediate | Each member | `chmod 400`, on that member's CA host |
| Node key | The node's operator | `chmod 400`, on the node host, never copied |
| Client key | The application owner | `chmod 400`, alongside the application |

**Where this repository diverges from the design, stated plainly.** All keys are
generated on one laptop, because this is a demonstration of a four-member
consortium rather than four actual organisations. In a real deployment each
member generates its own intermediate key and submits a certificate signing
request; the root operator signs the request and never sees a member's private
key. The scripts already separate CSR creation from signing, so splitting
`gen-intermediates.sh` into a member-side and a root-side half is a mechanical
change rather than a redesign.

The root key is likewise generated and stored locally with documented handling
rather than genuinely air-gapped. Production would hold it in an HSM or on an
offline machine, generated in a key ceremony with multiple witnesses, with
M-of-N control over its use. None of that is implemented here and the repository
should not be read as claiming otherwise.

### Loss and compromise

Root key lost: the consortium cannot issue new intermediates. Existing
certificates keep working until they expire, so this is a slow emergency rather
than an outage, resolved by standing up a new root and distributing it.

Root key compromised: total failure. Every certificate in the network is
suspect, because the attacker can mint any identity including CA certificates.
Recovery is a new root and a full reissue.

Intermediate key compromised: bounded to that member's namespace by the name
constraints, which is the entire point of ADR 0003. The attacker can impersonate
that member's nodes and clients and nothing else. Response is to revoke the
intermediate, remove the member at the permissioning layer, reissue under a new
intermediate.

Node or client key compromised: revoke, reissue, and rely on the permissioning
layer if the holder is also being removed.

## Consequences

Annual rotation of eleven certificates is a manual task that someone has to
remember, and the runbook entry for it is load-bearing rather than
decorative. If that task is missed the network stops, with no warning beyond
the expiry dates nobody is watching. Certificate expiry monitoring belongs in
the m7 observability work, and this ADR is the reason.

Declining to make revocation primary means being able to explain why, which is
the point: the alternative is a CRL that nobody verifies is being checked, and a
removal procedure that silently does nothing.

## Revisit if

Renewal becomes automated, in which case client lifetimes should drop
substantially. Or if a member requires revocation as a primary control for
compliance reasons, which means building CRL distribution and verifying that
Besu's path validation actually consults it.

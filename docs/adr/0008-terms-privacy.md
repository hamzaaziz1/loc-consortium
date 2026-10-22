# ADR 0008: Letter of credit terms are sealed off chain

- Status: Accepted
- Date: 2026-10-22

## Context

The original specification asked for Tessera privacy groups, so that credit
terms were visible to the two banks while the logistics operator saw only
shipment milestones. Tessera privacy was removed from Besu in the 25.6.0 line,
so that mechanism does not exist on this client.

What the requirement actually asks for is narrower than a privacy group: the
carrier must be able to act on a credit whose commercial content it cannot
read. That does not need private state. It needs the commercial content never
to be on chain at all.

## Decision

The chain holds a commitment to the terms. The terms are sealed off chain for
the parties entitled to read them.

`LetterOfCredit` stores `TERMS_HASH`, the keccak256 of the canonical terms, and
`TERMS_LOCATOR`, a non-secret reference. Expiry is the one term held on chain,
because it must be enforceable and the carrier legitimately needs it. Amount,
goods, pricing and documentary requirements are not there in any form.

### Envelope encryption, not direct encryption

Terms are encrypted once under a random content key using CMS (RFC 5652), and
that key is wrapped separately for each recipient's encryption certificate
using ECDH.

Encrypting the terms directly to each party's certificate was rejected because
certificates rotate annually (ADR 0004) and a credit outlives a rotation. A
credit issued in month eleven would become unreadable after rotation unless old
private keys were retained, which defeats rotating them.

With an envelope, rotation invalidates only the wrapped keys. Those can be
rewrapped for the new certificates without re-encrypting the terms and without
changing the commitment, so a rewrap is a runbook step rather than a
re-issuance.

### Dedicated encryption certificates

Terms are sealed to `terms.<org>.loc.consortium` certificates carrying
`keyUsage: keyAgreement`, not to the client certificates used for RPC.

The client and node certificates carry `digitalSignature` only, because m1
issued them least-privilege. Using one of those for ECDH key agreement
contradicts what the certificate asserts it is for. OpenSSL permits it; a
strict verifier would not, and it would be a fair finding in review.

Separating them is correct independently of that. A signing key proves who
acted and should never be recoverable by anyone else. An encryption key
protects content, outlives the messages it protected, and may need escrow so a
party can still read its own historical credits. Different lifecycles, and the
certificate should say which key is which.

### The commitment is over canonical plaintext

Two properties follow, and both matter.

CMS encryption is randomised, so the same terms seal to different bytes every
time. A commitment over ciphertext could not prove that two parties hold the
same terms, which is the only thing the commitment is for.

And the plaintext must be canonical. `jq -Sc` sorts keys and strips
whitespace, so two parties who wrote identical terms with different formatting
compute the same commitment. Without canonicalisation the verification is
theatre: it passes only when both parties happen to hold byte-identical files.

A related trap, found by testing rather than reasoning: OpenSSL's CMS treats
input as text and canonicalises line endings unless given `-binary`. Without
it the decrypted bytes differ from the input and the commitment fails to match,
with the symptom appearing at verification time, far from its cause.

## Consequences

### What this makes possible

The carrier records milestones against a credit it cannot read, which is the
requirement, achieved without private state. The test demonstrates the
strongest form of the claim: the logistics operator is an active member, a
named party to the credit, and holds a valid encryption certificate issued
under the consortium root, and still cannot decrypt the terms.

Availability is also better than a privacy group. Sealed terms are a file: any
party can hold its own copy, back it up and restore it without coordinating
with anyone. Tessera made availability a property of the transaction manager
mesh.

### Accepted costs

**Distribution is out of scope.** This covers sealing and verification. How a
sealed file reaches a counterparty is deliberately unspecified, because any
transport works: the file is useless without a recipient's private key.

**Losing an encryption key means losing readable history.** A party that loses
its encryption private key can no longer read credits sealed to it, and nobody
else can restore that. Escrow for encryption keys is the standard answer and is
a custody decision rather than a cryptographic one. Named here, not solved.

**No forward secrecy.** An attacker who later obtains a recipient's private key
can read every credit ever sealed to it. Forward secrecy needs interactive key
agreement, which does not fit documents sealed once and read later by whoever
holds the key. Tessera had the same property.

**The locator is not secret and existence leaks.** Anyone reading the chain
learns that a credit exists between these parties, with this expiry, and how
many shipment milestones it has. Only the commercial content is hidden.
Concealing the relationship would need something much stronger and is not what
was asked for.

**Nothing enforces who was sealed to.** The contract commits to the terms, not
to the recipient list. A bank could seal terms to a party who should not have
them and the chain would not know. The counterparty verifying its own copy
against the commitment detects wrong terms, not over-distribution.

## Revisit if

Concealing the existence of credits becomes a requirement, which makes this a
different system. Or if a regulator requires selective disclosure to a third
party: envelope encryption supports that naturally by adding a recipient at
seal time, but the governance of who may be added is not addressed here.

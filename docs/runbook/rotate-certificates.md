# Rotating certificates

**Partially rehearsed.** Regeneration is exercised constantly. Rotation
*without* regenerating the tree is not implemented, and that gap is the point
of this page.

## What forces rotation

End-entity certificates live 365 days, intermediates 5 years, the root 10
(ADR 0004). Eleven certificates rotate annually by hand.

The failure mode is unforgiving: when a node certificate expires its RPC
endpoint stops accepting clients, and Besu logs nothing when it rejects every
client. The outage has no symptom in the logs.

## Monitoring

```bash
make cert-metrics        # refresh the textfile
```

Alerts at 30 days (warning) and 7 (critical). Run the refresh on a timer; a
stale textfile means expiry monitoring has silently stopped, which is what
`CertificateMetricsStale` catches.

## The procedure today

```bash
./network/pki/gen-leaves.sh      # issues only what is missing
./network/pki/gen-keystores.sh   # regenerates ALL keystores, new password
make restart
```

**This is heavier than rotation should be.** `gen-keystores.sh` mints a new
password and rewrites every keystore, so every node restarts even if one
certificate was due. For a four-member consortium that is a coordinated
maintenance window to replace one certificate.

The right shape is per-node rotation: reissue one leaf, rebuild one keystore
against the existing password, restart one node. The password being global is
what prevents it, and fixing that is the outstanding work here.

## Rotating an encryption certificate

Encryption certificates (`terms.<org>`) need more care, because sealed letter
of credit terms were wrapped to the old key.

Envelope encryption means the terms do not need re-encrypting: only the wrapped
content keys do. A rewrap adds the new certificate as a recipient without
changing the plaintext or the on-chain commitment.

**That rewrap tool does not exist yet.** Until it does, retain old encryption
private keys or historical credits become unreadable. ADR 0008 names this.

## On compromise

Do not wait for expiry. Revoke the affected certificate, and if an
organisation's intermediate is compromised revoke that: name constraints
confine the damage to that member's namespace, which is the whole point of
ADR 0003.

Revocation at the PKI layer is immediate and does not depend on the controller
or on block production. Follow it with a governance vote to remove the member,
because the registry is the authoritative membership record.

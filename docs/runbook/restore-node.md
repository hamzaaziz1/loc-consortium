# Restoring a node

**Not rehearsed as a deliberate exercise**, though the Kubernetes work
destroyed and recreated every volume several times, which is the same path.

## A node that has lost its data

With four validators and `f = 1`, one node down is survivable. The chain
continues; do not rush.

```bash
docker compose -p loc-local ... up -d <service>
```

An empty data directory re-syncs from peers. Nothing needs restoring from
backup, because the chain is the backup: every other node holds the same
history.

What does **not** come from peers is the node's identity. `network/keys/<env>/`
holds the private key that determines the node's enode. Lose it and the node
has a new identity, which means a new enode, which means every other node's
static list and the allowlist are wrong.

**So the thing to back up is `network/keys/`, not the chain data.**

## A node whose identity key is lost

Treat it as a new node:

1. Generate a key, derive the public key, update `addressing.conf` if needed
2. Regenerate `static-nodes.json` and restart every node
3. If it was a validator, its address changed: the registry entry needs
   updating by governance vote, and until then the chain is a validator short

Step 3 is the expensive one. **With four validators, losing one validator key
permanently puts the consortium at the floor**, and a second loss halts the
chain. The runbook position is that validator keys are the most important
material in the network after the root CA.

## Restoring the whole network

If every node is gone but the PKI and keys survive, the chain is gone too and
a new one starts from genesis. The deployed contracts do not come back.

This is the scenario that makes `network/keys/` and `network/pki/out/` the
critical backup set, and it is also why `deployed.md` records contract
addresses: without it, nothing identifies which contracts a restored chain
should have.

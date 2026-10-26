# Moving to contract validator selection

**Rehearsed on staging, then executed on local.** Both are documented here
because the staging run found two things the local run then avoided.

This moves the chain from header-based validator voting to reading the
validator set from `ValidatorSetView`. Afterwards
`qbft_proposeValidatorVote` returns `Method not enabled`: an operator with full
RPC access can no longer change the validator set at all.

## Before starting

The contract must already be deployed and returning the correct set:

```bash
cast call $VALIDATOR_VIEW "getValidators()(address[])" --rpc-url $RPC
```

These four addresses must match the genesis `extraData`. If they do not, stop.
A wrong set at the transition block halts the chain, and a bad contract address
stops nodes from starting at all rather than merely stalling them.

## Apply the transition

Pick a block roughly 150 ahead, about five minutes:

```bash
jq '.config.transitions.qbft += [{
  "block": <height + 150>,
  "validatorselectionmode": "contract",
  "validatorcontractaddress": "0x<view>"
}]' network/genesis/local/genesis.json > /tmp/g.json && mv /tmp/g.json network/genesis/local/genesis.json
```

`+=` appends. Transitions accumulate, and the genesis becomes the record of
every consensus change the network has made.

## Restart, and verify the nodes actually have it

```bash
make restart
docker exec loc-local-validator-importer-1 sh -c 'grep -c <block> /genesis/genesis.json'
```

**`make up` is not sufficient.** Compose does not restart a container when only
the contents of a bind-mounted file change. On staging this produced a
transition that appeared to work, because the chain kept running, while the
nodes were still on the old configuration. The grep is the check that catches
it.

## Watch through the boundary

```bash
for i in $(seq 1 25); do
  echo "$(date +%T) $(cast block-number --rpc-url $RPC)"
  sleep 10
done
```

The height must pass the transition block without pausing. If it stops, go to
[qbft-stall](qbft-stall.md).

## Verify the mechanism changed

```bash
cast rpc qbft_proposeValidatorVote 0x<any-validator> true --rpc-url $RPC
```

`Method not enabled` is the proof. The chain continuing is not: the contract
returns the same set the headers did, so both would look identical.

## On a fresh chain

**Do not start a new chain from a genesis that already contains a transition.**
Besu expects empty validators in the header from the transition block onward,
while the genesis `extraData` embeds them, and block 1 fails validation with
`Validators in extra data expected to be empty`.

`tools/k8s-prepare.sh` strips transitions for exactly this reason. A fresh
deployment starts in header-voting mode and transitions afterwards.

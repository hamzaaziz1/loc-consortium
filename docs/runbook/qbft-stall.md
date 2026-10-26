# Recovering a stalled QBFT round

**Severity: critical.** No blocks are being produced. Nothing can be written to
the chain, including the governance transaction that would fix a governance
problem.

**Not rehearsed.** The escape hatch below is documented by Besu and the
transition mechanism it relies on has been exercised twice on this network, but
a deliberate stall has not been induced. Treat the timings as estimates.

## Confirm it is a stall and not one isolated node

```bash
for p in 8551 8552 8553 8554 8545 8546; do
  echo -n "$p: "
  curl -s --http1.1 --resolve ... https://...:$p -d '{"jsonrpc":"2.0","id":1,"method":"eth_blockNumber","params":[]}' | jq -r .result
done
```

All nodes stuck at the same height is a stall. One node behind is an isolated
node: check its peer count and the allowlist before doing anything drastic.

## Cause 1: fewer than three active validators

The registry refuses writes that would drop below three, so this should be
impossible. If it has happened, the chain is reading a validator contract other
than the one governance controls.

## Cause 2: the validator contract is unreachable or wrong

With `validatorselectionmode: contract`, every node calls `getValidators()` on
every block. If that reverts or returns a set with no quorum, block production
stops and **cannot be fixed on chain**, because fixing it needs a transaction
and nobody is mining.

## The escape hatch

Add a transition back to `blockheader` mode with a hand-specified validator
set, at a block a few minutes ahead.

```bash
jq '.config.transitions.qbft += [{
  "block": <current height + 150>,
  "validatorselectionmode": "blockheader",
  "validators": ["0x...", "0x...", "0x...", "0x..."]
}]' network/genesis/local/genesis.json > /tmp/g.json && mv /tmp/g.json network/genesis/local/genesis.json

make restart
```

**Every organisation must apply the same edit and restart.** A node that does
not is on a different consensus rule from the transition block onward and will
reject blocks the others accept. This is the step that makes a stall an
incident requiring coordination across four organisations rather than an
operator task.

Note that the transition back to contract mode is a less-travelled path in
Besu than the forward one, with known historical issues around selecting the
validator provider. Expect the recovery to need more care than the original
transition did.

## Afterwards

The chain is now in header-voting mode. Repair the validator contract, then
transition forward again following
[validator-transition](validator-transition.md). The genesis accumulates both
entries, which is correct: it becomes the record of every consensus change the
network has made.

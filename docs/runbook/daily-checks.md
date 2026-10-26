# Daily checks

```bash
export LOC_ENV=local
make smoke        # 22 assertions: liveness, consensus agreement, EVM
make tls-test     # 7: the endpoints reject what they should
make perm-test    # 5: allowlists match the registry and the loaded state
```

Then the identity check, which none of the above performs:

```bash
cast call <registry> "governor()(address)" --rpc-url http://127.0.0.1:8600
cast call <validator-view> "getValidators()(address[])" --rpc-url http://127.0.0.1:8600
```

The validator set must match the registry's active validators. If it does not,
either the chain is reading a different contract than you expect, or the
genesis transition points somewhere unexpected.

## What the dashboards should show

Chain head age near zero. Five peers per node. Controller reconcile age under
the alert threshold. Soonest certificate expiry comfortably above 30 days.
Refused node connections at zero.

A non-zero refusal count is either a removed member still trying, which is the
system working, or a legitimate node that has fallen off the allowlist, which
is not. Compare against the registry before concluding.

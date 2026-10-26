# Permissioning controller incidents

**Rehearsed.** The outage described below happened.

The controller fails open by design (ADR 0006): if it dies, allowlists freeze
and the network keeps running on a stale membership view. That is deliberate,
because the alternative makes one service able to halt a consortium. The cost
is that a dead controller is invisible from the network's behaviour.

## `PermissioningControllerStale`

The heartbeat has not advanced for two minutes. Membership decided by
governance is no longer reaching the nodes.

```bash
docker logs --tail 20 loc-local-permissioning-controller-1
cat network/config/local/controller/heartbeat.json
```

The reconcile timestamp deliberately does **not** advance on a failed pass, so
a controller that is running but failing every pass alerts the same as one that
is dead. Both are equally useless.

Common causes: it cannot reach any node (check the mutual TLS material), the
registry address is wrong or the contract has no code, or it is refusing to
write because the allowlist would exclude a static node.

**While it is down, a member removed by vote may still be able to connect.** If
that member is being removed for cause, revoke its certificate rather than
waiting.

## `PermissioningReloadFailing`

Some nodes rejected the reload and are enforcing an older allowlist. Besu
rejects a malformed file wholesale, so their previous allowlist is intact
rather than absent. The next reconcile retries, because the file still differs
from what those nodes hold.

## A controller fighting your corrections

The incident worth knowing about. A controller with stale configuration
overwrites a hand-corrected permissions file within ten seconds, so the error
names a file that is already correct by the time you read it.

**Symptom:** nodes refuse to start citing enodes missing from the allowlist;
you fix the file; they refuse again.

**Detection:** `docker ps` showing a controller uptime that predates your
change.

**Order of operations:** stop the controller, fix the file, restart the nodes,
then restart the controller with correct configuration. In that order.

The controller now refuses to write an allowlist missing any node in
`static-nodes.json`, and reads infrastructure enodes from that file rather than
an environment variable, which prevents the specific case. The general shape,
a running reconciler fighting a human, recurs.

## Known weakness

Seven processes have write access to the permissions file. Besu proves at
startup that it can write it, because `perm_add*` persists back to it, so it
cannot be mounted read-only. The controller is the only *intended* writer by
convention rather than constraint: anyone with admin RPC on a node can widen
that node's allowlist until the next reconcile overwrites it.

Mitigation is removing `ADMIN` and `PERM` from the RPC API list on nodes that
do not need them. Not yet done.

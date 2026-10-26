# Diagnosing a network that looks healthy

Read this before any other procedure. Several real incidents on this network
presented as a perfectly healthy system.

## A brand new chain passes every liveness check

Renaming a Compose project orphans its volumes. The containers start against
empty data directories, the chain begins at genesis, blocks flow, peers
connect, and all 22 smoke assertions pass. The governance deployment is gone
and nothing reports it.

**Detection.** Ask whether a known contract has code:

```bash
cast call <registry> "governor()(address)" --rpc-url http://127.0.0.1:8600
```

`does not have any code` means you are on a different chain.

**Recovery.** The old volumes still exist under the previous project name:

```bash
docker volume ls | grep -E "compose_|loc-local"
docker run --rm -v <old>:/from -v <new>:/to alpine sh -c 'cd /from && cp -a . /to/'
```

## A node refusing every client logs nothing

Besu logs nothing at INFO when it rejects every RPC client. The node looks
healthy in `docker compose ps` and in its own log while serving nobody.

**Detection.** Ask the server what it trusts:

```bash
openssl s_client -connect 127.0.0.1:8546 </dev/null 2>&1 | grep -A3 "Acceptable client"
```

An empty CA names list means the truststore loaded zero trust anchors.

**Recovery.** Rebuild the truststore with `keytool`, not `openssl`. See
[rotate-certificates](rotate-certificates.md).

## A correction that undoes itself

The permissioning controller reconciles every ten seconds. A controller holding
stale configuration will overwrite a hand-corrected permissions file faster
than you can restart the nodes, so the error names a file that is already
correct by the time you read it.

**Detection.** Check how long the controller has been running against when the
configuration last changed:

```bash
docker ps --format '{{.Names}} {{.Status}}' | grep controller
```

An uptime that predates your change means it is running on old configuration.

**Recovery.** Stop the controller first, then fix the file, then restart nodes,
then restart the controller with the correct environment. The controller now
refuses to write an allowlist missing a static node, which prevents the
specific case that caused this, but the general shape recurs.

## `make up` did nothing

`make up` picks up changed service *definitions*. `make restart` picks up
changed file *contents*. A genesis or permissions edit followed by `make up`
silently does nothing; a compose edit followed by `make restart` silently keeps
the old command. Changes to both need both.

**Verification after any genesis change:**

```bash
docker exec loc-local-validator-importer-1 sh -c 'grep -c <transition-block> /genesis/genesis.json'
```

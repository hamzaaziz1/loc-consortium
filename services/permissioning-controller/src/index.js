'use strict';

const fs = require('fs');
const path = require('path');
const { RpcClient } = require('./rpc');
const { Registry } = require('./registry');
const { desiredAllowlists, renderToml, changed, missingStaticNodes } = require('./reconcile');
const { Metrics } = require('./metrics');

/**
 * Permissioning controller.
 *
 * Besu removed its onchain permissioning hook in the 25.6.0 line, but kept
 * file-based local permissioning and the PERM API. So the registry remains the
 * authority on membership and this service is the enforcement point: it reads
 * the registry, writes each node's allowlist file, and reloads it in place.
 *
 * Validator set changes need none of this, because the QBFT validator contract
 * hook survived. That asymmetry is the whole architecture and it is a
 * consequence of what the client supports, not a preference. See ADR 0006.
 *
 * FAILS OPEN, DELIBERATELY. If this process dies the allowlists stay as they
 * are and the network keeps running with a stale membership view. The
 * alternative, nodes refusing connections they cannot verify against a current
 * registry, would make this service a single point of failure for a consortium
 * whose entire point is that no single party can halt it.
 *
 * What makes that defensible rather than lazy: removing a member at the PKI
 * layer is immediate and does not involve this service at all. Revoke the
 * organisation intermediate and they cannot complete a TLS handshake whatever
 * any allowlist says. Two independent paths, one slow and automatic, one
 * immediate and manual, and the fast one has no single point of failure.
 *
 * The cost is a propagation delay, so the delay is measured: every reconcile
 * writes a heartbeat with the block it last reconciled, and a heartbeat
 * falling behind is an alertable condition in m7 and an incident in the m9
 * runbook.
 */

const CONFIG = {
  registry: req('REGISTRY_ADDRESS'),
  permissionsFile: process.env.PERMISSIONS_FILE || '/perm/permissions.toml',
  heartbeatFile: process.env.HEARTBEAT_FILE || '/perm/heartbeat.json',
  caFile: process.env.TLS_CA || '/certs/root.pem',
  certFile: process.env.TLS_CERT || '/certs/client.chain.pem',
  keyFile: process.env.TLS_KEY || '/certs/client.key.pem',
  // Comma separated https URLs, one per node. Every node gets the same
  // allowlist: node permissioning is each node deciding who it will talk to,
  // and in a consortium they should all reach the same answer.
  nodes: req('NODE_URLS').split(',').map((s) => s.trim()).filter(Boolean),
  staticNodesFile: process.env.STATIC_NODES_FILE || '/config/static-nodes.json',
  intervalMs: Number(process.env.INTERVAL_MS || 10000),
};

function req(name) {
  const v = process.env[name];
  if (!v) {
    console.error(`missing required environment variable ${name}`);
    process.exit(1);
  }
  return v;
}

const metrics = new Metrics();
const METRICS_PORT = Number(process.env.METRICS_PORT || 9600);

function log(...args) {
  console.log(new Date().toISOString(), ...args);
}

const clients = CONFIG.nodes.map(
  (url) =>
    new RpcClient({
      url,
      caFile: CONFIG.caFile,
      certFile: CONFIG.certFile,
      keyFile: CONFIG.keyFile,
    }),
);

/** Reads the registry from whichever node answers first. */
async function readMembership() {
  let lastError;
  for (const client of clients) {
    try {
      const registry = new Registry(client, CONFIG.registry);
      const members = await registry.members();
      const block = Number(await client.call('eth_blockNumber'));
      return { members, block, via: client.url.hostname };
    } catch (e) {
      lastError = e;
    }
  }
  throw lastError || new Error('no node answered');
}

async function reconcileOnce() {
  const { members, block, via } = await readMembership();

  // Nodes belonging to no member: the consortium operator's RPC nodes exist to
  // serve applications and must stay reachable regardless of membership
  // changes, so they are allowlisted from static config rather than from the
  // registry.
  //
  // Read from static-nodes.json by default rather than from an environment
  // variable. That file is already the authoritative list of every node in the
  // network and is generated from addressing.conf. An environment variable
  // that silently defaults to empty, and whose emptiness locks nodes out of
  // their own network on the next restart, is the wrong shape for this input.
  // INFRASTRUCTURE_ENODES remains as an override.
  const staticNodes = readStaticNodes();
  const infrastructureEnodes = process.env.INFRASTRUCTURE_ENODES
    ? process.env.INFRASTRUCTURE_ENODES.split(',').map((s) => s.trim()).filter(Boolean)
    : staticNodes;

  const infrastructureAccounts = (process.env.INFRASTRUCTURE_ACCOUNTS || '')
    .split(',')
    .map((s) => s.trim())
    .filter(Boolean);

  const desired = desiredAllowlists(members, { infrastructureEnodes, infrastructureAccounts });

  // The invariant. An allowlist excluding a configured static node stops that
  // node from starting, so the controller treats it as a bug in its own output
  // rather than something to apply. Refusing leaves the previous allowlist in
  // place, which is the fail-open behaviour this service is built around.
  const missing = missingStaticNodes(desired, staticNodes);
  if (missing.length > 0) {
    throw new Error(
      `refusing to write an allowlist missing ${missing.length} static node(s): ` +
        `${missing.map((e) => e.split('@')[1] || e).join(', ')}. ` +
        'Check INFRASTRUCTURE_ENODES and the registry; the previous allowlist is unchanged.',
    );
  }
  const next = renderToml(desired, { block, registry: CONFIG.registry });

  let previous = '';
  try {
    previous = fs.readFileSync(CONFIG.permissionsFile, 'utf8');
  } catch {
    // No file yet. gen-permissions.sh should have written one before the nodes
    // started, so this is unusual, but writing one is the right recovery.
  }

  const active = members.filter((m) => m.status === 1).length;

  if (!changed(previous, next)) {
    writeHeartbeat({ block, via, changed: false, members: members.length, active });
    metrics.recordSuccess({
      block,
      members: members.length,
      active,
      nodes: desired.nodes.length,
      accounts: desired.accounts.length,
      changed: false,
    });
    return { applied: false, block, desired };
  }

  // Written in place rather than via a temporary file and rename. The file
  // itself is bind-mounted, so replacing the inode would leave every node
  // reading the old one: the mount is the inode, not the name. A torn read is
  // microseconds wide, and Besu rejects a malformed file wholesale while
  // keeping its previous allowlist, so the worst case is one rejected reload
  // that the next pass fixes.
  fs.writeFileSync(CONFIG.permissionsFile, next);

  log(`allowlists changed at block ${block}: ${desired.nodes.length} nodes, ${desired.accounts.length} accounts`);

  const results = await Promise.allSettled(
    clients.map((c) => c.call('perm_reloadPermissionsFromFile')),
  );
  results.forEach((r, i) => {
    const host = clients[i].url.hostname;
    if (r.status === 'fulfilled') {
      log(`  reloaded ${host}`);
    } else {
      // A node that fails to reload keeps its previous allowlist, which is the
      // fail-open behaviour. It is logged rather than retried here; the next
      // reconcile will try again because the file still differs from what that
      // node holds.
      log(`  FAILED  ${host}: ${r.reason.message}`);
    }
  });

  const failed = results.filter((r) => r.status === 'rejected').length;
  writeHeartbeat({ block, via, changed: true, members: members.length, active, failedReloads: failed });
  metrics.recordSuccess({
    block,
    members: members.length,
    active,
    failedReloads: failed,
    nodes: desired.nodes.length,
    accounts: desired.accounts.length,
    changed: true,
  });
  return { applied: true, block, desired };
}

/**
 * Every node the network is configured to connect to. Read fresh each pass so
 * a regenerated static node list is picked up without restarting.
 */
function readStaticNodes() {
  try {
    const raw = fs.readFileSync(CONFIG.staticNodesFile, 'utf8');
    const parsed = JSON.parse(raw);
    return Array.isArray(parsed) ? parsed : [];
  } catch {
    // Absent or unreadable. Returning empty means the guard below cannot fire,
    // so this is logged rather than silently tolerated.
    log(`warning: could not read ${CONFIG.staticNodesFile}; static node protection is inactive`);
    return [];
  }
}

function writeHeartbeat(extra) {
  const payload = { at: new Date().toISOString(), ...extra };
  try {
    fs.mkdirSync(path.dirname(CONFIG.heartbeatFile), { recursive: true });
    fs.writeFileSync(CONFIG.heartbeatFile, JSON.stringify(payload, null, 2));
  } catch (e) {
    log(`heartbeat write failed: ${e.message}`);
  }
}

async function main() {
  log(`controller starting`);
  log(`  registry ${CONFIG.registry}`);
  log(`  nodes    ${CONFIG.nodes.length}`);
  log(`  file     ${CONFIG.permissionsFile}`);
  log(`  metrics  :${METRICS_PORT}/metrics`);

  // Served before the first reconcile, so a controller that cannot reach any
  // node is still scrapeable. Its stale reconcile timestamp is precisely the
  // thing Prometheus needs to see.
  metrics.serve(METRICS_PORT);

  for (;;) {
    try {
      await reconcileOnce();
    } catch (e) {
      // Reconciliation is idempotent, so a failed pass costs nothing but time.
      // The heartbeat stops advancing, which is what makes the staleness
      // visible rather than silent.
      metrics.recordFailure();
      log(`reconcile failed: ${e.message}`);
    }
    await new Promise((r) => setTimeout(r, CONFIG.intervalMs));
  }
}

main();

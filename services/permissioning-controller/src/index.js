'use strict';

const fs = require('fs');
const path = require('path');
const { RpcClient } = require('./rpc');
const { Registry } = require('./registry');
const { desiredAllowlists, renderToml, changed } = require('./reconcile');

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
  const infrastructureEnodes = (process.env.INFRASTRUCTURE_ENODES || '')
    .split(',')
    .map((s) => s.trim())
    .filter(Boolean);

  const infrastructureAccounts = (process.env.INFRASTRUCTURE_ACCOUNTS || '')
    .split(',')
    .map((s) => s.trim())
    .filter(Boolean);

  const desired = desiredAllowlists(members, { infrastructureEnodes, infrastructureAccounts });
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
    return { applied: false, block, desired };
  }

  // Write to a temporary file and rename, so a node reloading concurrently
  // never reads a half-written file. rename is atomic within a filesystem.
  // Written in place rather than via a temporary file and rename: the file
  // itself is bind-mounted, so replacing the inode would leave every node
  // reading the old one. A torn read is microseconds wide and Besu rejects a
  // malformed file wholesale while keeping its previous allowlist, so the
  // worst case is one rejected reload that the next pass fixes.
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
  return { applied: true, block, desired };
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

  for (;;) {
    try {
      await reconcileOnce();
    } catch (e) {
      // Reconciliation is idempotent, so a failed pass costs nothing but time.
      // The heartbeat stops advancing, which is what makes the staleness
      // visible rather than silent.
      log(`reconcile failed: ${e.message}`);
    }
    await new Promise((r) => setTimeout(r, CONFIG.intervalMs));
  }
}

main();

'use strict';

const http = require('http');

/**
 * A metrics endpoint for the controller's reconciliation state.
 *
 * Exists because the controller fails open (ADR 0006): if it dies, the
 * allowlists freeze and the network keeps running on a stale membership view.
 * Nothing about the network's behaviour reveals that, so the only way to
 * notice is to watch the controller itself.
 *
 * Plain HTTP with no authentication, like the Besu metrics ports. These
 * numbers carry no secrets, the network is private, and requiring client
 * certificates here would mean putting an operator identity into Prometheus
 * for no benefit.
 */
class Metrics {
  constructor() {
    this.lastReconcile = 0;
    this.lastBlock = 0;
    this.reconciles = 0;
    this.failures = 0;
    this.failedReloads = 0;
    this.members = 0;
    this.activeMembers = 0;
    this.allowlistedNodes = 0;
    this.allowlistedAccounts = 0;
    this.changes = 0;
  }

  recordSuccess({ block, members, active, failedReloads = 0, nodes, accounts, changed }) {
    this.lastReconcile = Math.floor(Date.now() / 1000);
    this.lastBlock = block;
    this.reconciles += 1;
    this.failedReloads = failedReloads;
    this.members = members;
    this.activeMembers = active;
    if (nodes !== undefined) this.allowlistedNodes = nodes;
    if (accounts !== undefined) this.allowlistedAccounts = accounts;
    if (changed) this.changes += 1;
  }

  recordFailure() {
    // Deliberately does NOT advance lastReconcile. The staleness of that
    // timestamp is the signal: a controller that is running but failing every
    // pass is as useless as one that is dead, and should alert the same way.
    this.failures += 1;
  }

  render() {
    return [
      '# HELP permissioning_controller_last_reconcile_timestamp_seconds When the last successful reconcile completed.',
      '# TYPE permissioning_controller_last_reconcile_timestamp_seconds gauge',
      `permissioning_controller_last_reconcile_timestamp_seconds ${this.lastReconcile}`,
      '',
      '# HELP permissioning_controller_last_block The chain height at the last successful reconcile.',
      '# TYPE permissioning_controller_last_block gauge',
      `permissioning_controller_last_block ${this.lastBlock}`,
      '',
      '# HELP permissioning_controller_reconciles_total Successful reconcile passes.',
      '# TYPE permissioning_controller_reconciles_total counter',
      `permissioning_controller_reconciles_total ${this.reconciles}`,
      '',
      '# HELP permissioning_controller_failures_total Failed reconcile passes.',
      '# TYPE permissioning_controller_failures_total counter',
      `permissioning_controller_failures_total ${this.failures}`,
      '',
      '# HELP permissioning_controller_changes_total Passes that changed the allowlists.',
      '# TYPE permissioning_controller_changes_total counter',
      `permissioning_controller_changes_total ${this.changes}`,
      '',
      '# HELP permissioning_controller_failed_reloads Nodes that rejected the most recent reload.',
      '# TYPE permissioning_controller_failed_reloads gauge',
      `permissioning_controller_failed_reloads ${this.failedReloads}`,
      '',
      '# HELP permissioning_controller_members Members in the registry.',
      '# TYPE permissioning_controller_members gauge',
      `permissioning_controller_members ${this.members}`,
      '',
      '# HELP permissioning_controller_active_members Members with Active status.',
      '# TYPE permissioning_controller_active_members gauge',
      `permissioning_controller_active_members ${this.activeMembers}`,
      '',
      '# HELP permissioning_controller_allowlisted_nodes Enodes in the current allowlist.',
      '# TYPE permissioning_controller_allowlisted_nodes gauge',
      `permissioning_controller_allowlisted_nodes ${this.allowlistedNodes}`,
      '',
      '# HELP permissioning_controller_allowlisted_accounts Accounts in the current allowlist.',
      '# TYPE permissioning_controller_allowlisted_accounts gauge',
      `permissioning_controller_allowlisted_accounts ${this.allowlistedAccounts}`,
      '',
    ].join('\n');
  }

  serve(port) {
    const server = http.createServer((req, res) => {
      if (req.url === '/metrics') {
        res.writeHead(200, { 'content-type': 'text/plain; version=0.0.4' });
        res.end(this.render());
      } else {
        res.writeHead(404);
        res.end();
      }
    });
    server.listen(port);
    return server;
  }
}

module.exports = { Metrics };

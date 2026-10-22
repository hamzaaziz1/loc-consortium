'use strict';

const fs = require('fs');
const https = require('https');
const { URL } = require('url');

/**
 * JSON-RPC over mutual TLS.
 *
 * Every RPC endpoint in this network requires a client certificate (ADR 0005),
 * which is why operator tooling that cannot present one runs behind a proxy.
 * Node can present one natively, so the controller talks to the nodes
 * directly and needs no proxy.
 *
 * It presents the operator's `controller` identity, which is the most
 * sensitive end-entity certificate in the network: possession of it is
 * possession of the ability to change who may connect. It is a client
 * certificate with clientAuth only, so a leak cannot be used to stand up a
 * convincing endpoint, and the threat model in m9 treats this key as a primary
 * target.
 */
class RpcClient {
  /**
   * @param {object} opts
   * @param {string} opts.url            https://<node name>:<port>
   * @param {string} opts.caFile         consortium root certificate
   * @param {string} opts.certFile       client certificate CHAIN, not the bare cert
   * @param {string} opts.keyFile
   */
  constructor({ url, caFile, certFile, keyFile }) {
    this.url = new URL(url);
    this.agent = new https.Agent({
      ca: fs.readFileSync(caFile),
      // The chain, not the bare certificate: the node trusts only the root, so
      // the issuing intermediate has to arrive from this side for a validation
      // path to exist.
      cert: fs.readFileSync(certFile),
      key: fs.readFileSync(keyFile),
      // Verify the node's own certificate and its name. A client that skips
      // this authenticates itself to whatever answers the address.
      rejectUnauthorized: true,
      servername: this.url.hostname,
      keepAlive: true,
    });
    this.nextId = 1;
  }

  call(method, params = []) {
    const body = JSON.stringify({
      jsonrpc: '2.0',
      id: this.nextId++,
      method,
      params,
    });

    return new Promise((resolve, reject) => {
      const req = https.request(
        {
          agent: this.agent,
          hostname: this.url.hostname,
          port: this.url.port,
          path: '/',
          method: 'POST',
          headers: {
            'content-type': 'application/json',
            'content-length': Buffer.byteLength(body),
          },
          timeout: 10000,
        },
        (res) => {
          let data = '';
          res.on('data', (c) => (data += c));
          res.on('end', () => {
            let parsed;
            try {
              parsed = JSON.parse(data);
            } catch (e) {
              return reject(new Error(`${method}: invalid JSON (${res.statusCode})`));
            }
            if (parsed.error) {
              return reject(new Error(`${method}: ${parsed.error.message}`));
            }
            resolve(parsed.result);
          });
        },
      );
      req.on('timeout', () => req.destroy(new Error(`${method}: timed out`)));
      req.on('error', reject);
      req.write(body);
      req.end();
    });
  }

  ethCall(to, data) {
    return this.call('eth_call', [{ to, data }, 'latest']);
  }
}

module.exports = { RpcClient };

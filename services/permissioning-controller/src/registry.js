'use strict';

const { Interface } = require('ethers');

/**
 * Reads membership from the on-chain MemberRegistry.
 *
 * Only view functions. The controller never writes to the chain: governance
 * decides membership, the controller enforces it. A controller that could
 * write would be a second route to change membership without a vote, which is
 * the thing this whole design exists to prevent.
 */
const ABI = [
  'function memberIds() view returns (bytes32[])',
  'function member(bytes32) view returns (tuple(bytes32 id,string name,uint8 status,bool isValidator,address validatorAddress,uint64 joinedAt,uint64 statusChangedAt))',
  'function accountsOf(bytes32) view returns (address[])',
  'function enodesOf(bytes32) view returns (string[])',
  'function governor() view returns (address)',
];

class Registry {
  constructor(rpc, address) {
    this.rpc = rpc;
    this.address = address;
    this.iface = new Interface(ABI);
  }

  async #read(fn, args = []) {
    const data = this.iface.encodeFunctionData(fn, args);
    const raw = await this.rpc.ethCall(this.address, data);
    return this.iface.decodeFunctionResult(fn, raw);
  }

  async governor() {
    const [g] = await this.#read('governor');
    return g;
  }

  /** Every member with its accounts and enodes, as the registry sees it now. */
  async members() {
    const [ids] = await this.#read('memberIds');
    const out = [];
    for (const id of ids) {
      const [m] = await this.#read('member', [id]);
      const [accounts] = await this.#read('accountsOf', [id]);
      const [enodes] = await this.#read('enodesOf', [id]);
      out.push({
        id,
        name: m.name,
        status: Number(m.status),
        isValidator: m.isValidator,
        accounts: [...accounts],
        enodes: [...enodes],
      });
    }
    return out;
  }
}

module.exports = { Registry };

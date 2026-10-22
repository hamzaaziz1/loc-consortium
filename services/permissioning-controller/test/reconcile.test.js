'use strict';

const assert = require('assert');
const { desiredAllowlists, renderToml, changed, normaliseEnode } = require('../src/reconcile');

let passed = 0;
function test(name, fn) {
  fn();
  passed++;
  console.log(`  PASS  ${name}`);
}

const ACTIVE = 1, SUSPENDED = 2, REMOVED = 3;

const members = [
  { id: '0x1', status: ACTIVE, enodes: ['enode://AA@1.1.1.1:30303'], accounts: ['0xAbC'] },
  { id: '0x2', status: ACTIVE, enodes: ['enode://bb@2.2.2.2:30303'], accounts: ['0xdef'] },
  { id: '0x3', status: ACTIVE, enodes: ['enode://cc@3.3.3.3:30303'], accounts: ['0x111'] },
];

test('active members are allowed', () => {
  const d = desiredAllowlists(members);
  assert.strictEqual(d.nodes.length, 3);
  assert.strictEqual(d.accounts.length, 3);
});

test('a suspended member loses both node and account access', () => {
  const m = structuredClone(members);
  m[0].status = SUSPENDED;
  const d = desiredAllowlists(m);
  assert.ok(!d.nodes.some((n) => n.includes('1.1.1.1')));
  assert.ok(!d.accounts.includes('0xabc'));
});

test('removed is treated the same as suspended', () => {
  const a = structuredClone(members); a[0].status = SUSPENDED;
  const b = structuredClone(members); b[0].status = REMOVED;
  assert.deepStrictEqual(desiredAllowlists(a), desiredAllowlists(b));
});

test('infrastructure nodes survive membership changes', () => {
  const m = structuredClone(members).map((x) => ({ ...x, status: REMOVED }));
  const d = desiredAllowlists(m, { infrastructureEnodes: ['enode://zz@9.9.9.9:30303'] });
  assert.deepStrictEqual(d.nodes, ['enode://zz@9.9.9.9:30303']);
  assert.deepStrictEqual(d.accounts, []);
});

test('enode public keys are lowercased, addresses are not reformatted beyond case', () => {
  assert.strictEqual(normaliseEnode('enode://AbC@1.2.3.4:30303'), 'enode://abc@1.2.3.4:30303');
  assert.strictEqual(normaliseEnode('  enode://AB@h:1  '), 'enode://ab@h:1');
});

test('output is deterministic regardless of member order', () => {
  const shuffled = [members[2], members[0], members[1]];
  assert.deepStrictEqual(desiredAllowlists(shuffled), desiredAllowlists(members));
});

test('reconciliation is idempotent: same state renders as unchanged', () => {
  const d = desiredAllowlists(members);
  assert.strictEqual(changed(renderToml(d, { block: 1 }), renderToml(d, { block: 9999 })), false);
});

test('a real allowlist change is detected', () => {
  const before = renderToml(desiredAllowlists(members), { block: 1 });
  const m = structuredClone(members); m[0].status = REMOVED;
  const after = renderToml(desiredAllowlists(m), { block: 2 });
  assert.strictEqual(changed(before, after), true);
});

test('duplicate enodes across members collapse', () => {
  const m = structuredClone(members);
  m[1].enodes = m[0].enodes;
  assert.strictEqual(desiredAllowlists(m).nodes.length, 2);
});

test('an empty consortium yields empty allowlists rather than throwing', () => {
  const d = desiredAllowlists([]);
  assert.deepStrictEqual(d, { nodes: [], accounts: [] });
});

test('infrastructure accounts survive membership changes', () => {
  const m = structuredClone(members).map((x) => ({ ...x, status: REMOVED }));
  const d = desiredAllowlists(m, { infrastructureAccounts: ['0xDEAD'] });
  assert.deepStrictEqual(d.accounts, ['0xdead']);
});

test('infrastructure enodes are normalised like member enodes', () => {
  const d = desiredAllowlists([], { infrastructureEnodes: ['enode://ZZ@9.9.9.9:30303'] });
  assert.deepStrictEqual(d.nodes, ['enode://zz@9.9.9.9:30303']);
});

console.log(`\n${passed} passed`);

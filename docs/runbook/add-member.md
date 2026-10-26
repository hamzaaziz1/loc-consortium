# Adding a member

Four layers have to agree: PKI, registry, allowlist, and if the member will
validate, the validator set. Three of those follow automatically; one does not.

**Rehearsed** on staging through the governance cycle. The PKI half is
exercised every time the consortium is regenerated.

## 1. Issue the member's certificates

Add the organisation to `network/pki/openssl/orgs.conf` and its nodes to
`nodes.conf`, then:

```bash
./network/pki/gen-intermediates.sh     # new org CA, name-constrained
./network/pki/gen-leaves.sh            # node, client and encryption certs
./network/pki/gen-keystores.sh         # regenerates ALL keystores
```

**The keystore step mints a new password**, so every existing node must
restart. That is a real cost of the current design and the reason
[rotate-certificates](rotate-certificates.md) is owed a procedure that does
not regenerate the tree.

In a real consortium the new member generates its own intermediate key and
submits a CSR; the root operator signs it and never sees the private key. The
scripts already separate CSR creation from signing, so splitting them is
mechanical.

## 2. Propose the member on chain

Kind `1` (`AddMember`). Payload is
`(string name, address validatorAddress, bool isValidator, address[] accounts, string[] enodes)`.

```bash
cast send $GOVERNOR "propose(uint8,bytes32,bytes)" 1 $(cast keccak "new-bank") \
  "$(cast abi-encode 'f(string,address,bool,address[],string[])' \
      "New Bank" 0x<validator> true "[0x<account>]" "[enode://...]")" \
  --private-key $PROPOSER_KEY --rpc-url $RPC --legacy --gas-price 0
```

Additions need a **majority of all active members**, because there is no
existing subject to exclude. With four members that is three votes.

Additions execute immediately once passed: adding a member cannot break
quorum, so there is no delay.

## 3. The allowlist follows automatically

The permissioning controller reconciles within one interval. Confirm:

```bash
make perm-test
```

## 4. Add the node to the static list and restart

This is the step that does **not** follow automatically, and it is a real gap.

A new member's node must appear in `addressing.conf` and therefore in
`static-nodes.json`, which is generated configuration rather than chain state:

```bash
./tools/gen-static-nodes.sh
make restart
```

Until every existing node restarts with the new peer list, they will accept
connections from the new node but never dial it. The allowlist permits; the
static list dials. They are different things.

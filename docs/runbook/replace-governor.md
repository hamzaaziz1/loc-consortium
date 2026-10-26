# Replacing the Governor

**Rehearsed** on staging; partially executed on local, where the proposal
expired before execution, which is itself the expiry design working.

The registry and the validator view are permanent: the view's address is fixed
in the genesis, so changing it means a coordinated restart of every node. The
Governor is the replaceable part, and this is how.

## 1. Deploy the new Governor

```bash
REGISTRY_ADDRESS=0x... forge script \
  script/DeployGovernorUpgrade.s.sol:DeployGovernorUpgrade \
  --rpc-url http://127.0.0.1:8600 --private-key $DEPLOYER_KEY \
  --broadcast --legacy --gas-price 0
```

The script deploys and **stops**. It cannot hand over governance: only the
current Governor can, and only by vote. A deploy script able to swap the
governance contract unilaterally would defeat the design.

## 2. Vote the transfer

Kind `8` (`TransferGovernance`), payload `(address)`, subject 32 zero bytes.
Needs a majority of all active members.

It waits out the execution delay, because handing control of membership to a
different contract is the most consequential act available.

## 3. Execute inside the window

```bash
cast call $OLD_GOVERNOR "executionWindowOf(uint256)(uint64,uint64)" $ID --rpc-url $RPC
```

Two numbers: executable from, expires at. **Miss the window and the proposal is
dead** and must be reproposed. This has happened once on local: a 600 block
delay plus an operator not returning for days.

For a planned upgrade, propose when someone will be available to execute.

## 4. Verify the handover

```bash
cast call $REGISTRY "governor()(address)" --rpc-url $RPC
```

The old Governor can no longer write. A proposal it had already carried will
revert at execution with `NotGovernor`.

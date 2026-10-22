// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.28;

import { Script } from "forge-std/Script.sol";
import { console } from "forge-std/console.sol";
import { MemberRegistry } from "../src/governance/MemberRegistry.sol";
import { InfrastructureRegistry } from "../src/governance/InfrastructureRegistry.sol";
import { Governor } from "../src/governance/Governor.sol";
import { LetterOfCreditFactory } from "../src/loc/LetterOfCreditFactory.sol";

/// @title DeployGovernorUpgrade
/// @notice Adds the infrastructure registry, a new Governor and the letter of
///         credit factory to an environment whose MemberRegistry already
///         exists.
///
/// @dev Exists because the registry cannot practically be replaced. QBFT reads
///      the validator set through a view whose registry pointer is immutable
///      and whose address is fixed in the genesis, so a new registry means a
///      new transition and a coordinated restart of every node. The registry is
///      therefore kept and only the replaceable parts are redeployed.
///
///      This script deploys and stops. It CANNOT hand governance to the new
///      Governor: the existing Governor holds that authority and only a vote
///      can move it. The script prints the proposal to raise, which is the
///      correct shape — a deployer able to swap the governance contract
///      unilaterally would defeat the entire design.
///
///      Run (from contracts/):
///        REGISTRY_ADDRESS=0x... forge script \
///          script/DeployGovernorUpgrade.s.sol:DeployGovernorUpgrade \
///          --rpc-url http://127.0.0.1:8600 --private-key $KEY \
///          --broadcast --legacy --gas-price 0
contract DeployGovernorUpgrade is Script {
    bytes32 public constant LOC_FACTORY_KEY = keccak256("loc-factory");

    function run() external {
        address registryAddress = vm.envAddress("REGISTRY_ADDRESS");
        MemberRegistry registry = MemberRegistry(registryAddress);

        address currentGovernor = registry.governor();
        require(currentGovernor != address(0), "no registry at that address");

        uint64 voting = uint64(vm.envOr("GOV_VOTING_PERIOD", uint256(3600)));
        uint64 delay = uint64(vm.envOr("GOV_EXECUTION_DELAY", uint256(600)));
        uint64 window = uint64(vm.envOr("GOV_EXECUTION_WINDOW", uint256(7200)));

        vm.startBroadcast();

        InfrastructureRegistry infrastructure = new InfrastructureRegistry(registryAddress);
        Governor governor =
            new Governor(registryAddress, address(infrastructure), voting, delay, window);
        LetterOfCreditFactory factory = new LetterOfCreditFactory(registryAddress);

        vm.stopBroadcast();

        console.log("InfrastructureRegistry", address(infrastructure));
        console.log("Governor (new)        ", address(governor));
        console.log("LetterOfCreditFactory ", address(factory));
        console.log("Governor (current)    ", currentGovernor);
        console.log("");
        console.log("Nothing is live yet. Two votes are required, in this order.");
        console.log("");
        console.log("1. On the CURRENT governor, TransferGovernance (kind 8):");
        console.log("   payload:");
        console.logBytes(abi.encode(address(governor)));
        console.log("");
        console.log("2. On the NEW governor once it holds governance,");
        console.log("   SetInfrastructure (kind 9), key loc-factory:");
        console.logBytes(abi.encode(LOC_FACTORY_KEY, address(factory)));
        console.log("");
        console.log("Until vote 1 executes the new Governor can do nothing, and");
        console.log("until vote 2 executes nothing records which factory is the");
        console.log("consortium's. Credits issued before vote 2 are valid but");
        console.log("not discoverable through the infrastructure registry.");
    }
}

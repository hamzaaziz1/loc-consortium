// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.28;

import { Script } from "forge-std/Script.sol";
import { console } from "forge-std/console.sol";
import { stdJson } from "forge-std/StdJson.sol";
import { MemberRegistry } from "../src/governance/MemberRegistry.sol";
import { ValidatorSetView } from "../src/governance/ValidatorSetView.sol";
import { Governor } from "../src/governance/Governor.sol";
import { IMemberRegistry } from "../src/interfaces/IMemberRegistry.sol";

/// @title Deploy
/// @notice Deploys governance and seeds the founding consortium.
///
/// @dev The sequence matters, and the awkward part is the bootstrap: the
///      founding members cannot be added by vote, because there is no
///      electorate until the first member exists. So the deployer holds
///      governance briefly, seeds the founding four, and hands over.
///
///      THE DEPLOYER MUST END UP WITH NOTHING. The final transfer is the
///      whole point of the script, and `verify()` asserts it afterwards
///      rather than trusting that it happened.
///
///      Run (from contracts/):
///        forge script script/Deploy.s.sol:Deploy \
///          --rpc-url http://127.0.0.1:8600 \
///          --private-key $DEPLOYER_KEY \
///          --broadcast --legacy --gas-price 0
///
///      The RPC URL is the local terminating proxy, not a node: Foundry
///      cannot present a client certificate and every endpoint requires one.
///      See ADR 0005.
contract Deploy is Script {
    using stdJson for string;

    /// @dev Governance timings, in blocks. At two-second blocks the defaults
    ///      are roughly two hours of voting, twenty minutes of delay before a
    ///      reduction in standing executes, and a four hour execution window.
    ///      Defensible for a consortium; tedious for a rehearsal, where a
    ///      twenty minute wait makes a full governance cycle impractical to
    ///      exercise.
    ///
    ///      Overridable so staging can run the same code on short timings.
    ///      Environment rather than a constant, so there is no second contract
    ///      and no "test build" that differs from what is deployed.
    function _timings() internal view returns (uint64 voting, uint64 delay, uint64 window) {
        voting = uint64(vm.envOr("GOV_VOTING_PERIOD", uint256(3600)));
        delay = uint64(vm.envOr("GOV_EXECUTION_DELAY", uint256(600)));
        window = uint64(vm.envOr("GOV_EXECUTION_WINDOW", uint256(7200)));
    }

    struct Founding {
        string slug;
        string name;
        address validator;
        address account;
        string enode;
    }

    function run() external {
        Founding[] memory members = _readConfig();
        require(members.length >= 3, "a consortium needs at least three validators");

        vm.startBroadcast();

        MemberRegistry registry = new MemberRegistry(msg.sender);
        ValidatorSetView validatorView = new ValidatorSetView(address(registry));
        (uint64 voting, uint64 delay, uint64 window) = _timings();
        Governor governor = new Governor(address(registry), voting, delay, window);

        for (uint256 i = 0; i < members.length; ++i) {
            address[] memory accounts = new address[](1);
            accounts[0] = members[i].account;
            string[] memory enodes = new string[](1);
            enodes[0] = members[i].enode;

            registry.addMember(
                keccak256(bytes(members[i].slug)),
                members[i].name,
                members[i].validator,
                true,
                accounts,
                enodes
            );
        }

        // Closes the permissive window that exists only because a network
        // necessarily passes through one and two validators on its way to
        // four. After this the validator floor is unconditional.
        registry.endFoundingPhase();

        // The handover. From here the deployer cannot write to the registry
        // and every change must pass a vote.
        registry.transferGovernance(address(governor));

        vm.stopBroadcast();

        console.log("MemberRegistry   ", address(registry));
        console.log("ValidatorSetView ", address(validatorView));
        console.log("Governor         ", address(governor));
        console.log("  voting period  ", voting);
        console.log("  execution delay", delay);
        console.log("  execution window", window);
        console.log("");
        console.log("Put this address in the genesis transitions block:");
        console.log("  validatorcontractaddress =", address(validatorView));

        _verify(registry, validatorView, governor, members);
    }

    /// @dev The config path comes from the environment rather than being
    ///      hardcoded. A script that always reads the same file can be
    ///      pointed at the wrong chain while loading the right config, which
    ///      is a quiet way to seed one consortium with another's members.
    ///      Requiring LOC_ENV means the chain and the config are chosen by the
    ///      same variable.
    function _readConfig() internal view returns (Founding[] memory out) {
        string memory env = vm.envOr("LOC_ENV", string("local"));
        string memory path = string.concat("../network/config/", env, "/deploy.json");
        console.log("config:", path);
        string memory json = vm.readFile(path);
        uint256 n = json.readUint(".count");
        out = new Founding[](n);
        for (uint256 i = 0; i < n; ++i) {
            string memory base = string.concat(".members[", vm.toString(i), "]");
            out[i] = Founding({
                slug: json.readString(string.concat(base, ".slug")),
                name: json.readString(string.concat(base, ".name")),
                validator: json.readAddress(string.concat(base, ".validator")),
                account: json.readAddress(string.concat(base, ".account")),
                enode: json.readString(string.concat(base, ".enode"))
            });
        }
    }

    /// @dev Asserted rather than assumed. A deployment that silently left the
    ///      deployer in control would look identical to a correct one.
    function _verify(
        MemberRegistry registry,
        ValidatorSetView validatorView,
        Governor governor,
        Founding[] memory members
    ) internal view {
        require(registry.governor() == address(governor), "governance was not handed over");
        require(registry.founded(), "founding phase is still open");
        require(
            validatorView.getValidators().length == members.length,
            "validator view disagrees with the seeded set"
        );
        require(
            registry.activeMemberCount() == members.length, "not every member was seeded active"
        );
        for (uint256 i = 0; i < members.length; ++i) {
            require(
                registry.isAccountAllowed(members[i].account),
                "a member account is not on the allowlist"
            );
        }
        console.log("verified: governance handed over, deployer holds nothing");
    }
}

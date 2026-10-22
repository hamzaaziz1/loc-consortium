// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.28;

import { Script } from "forge-std/Script.sol";
import { console } from "forge-std/console.sol";
import { stdJson } from "forge-std/StdJson.sol";
import { MemberRegistry } from "../src/governance/MemberRegistry.sol";
import { ValidatorSetView } from "../src/governance/ValidatorSetView.sol";
import { InfrastructureRegistry } from "../src/governance/InfrastructureRegistry.sol";
import { Governor } from "../src/governance/Governor.sol";
import { LetterOfCreditFactory } from "../src/loc/LetterOfCreditFactory.sol";

/// @title Deploy
/// @notice Deploys the full stack and seeds the founding consortium.
///
/// @dev For a fresh environment. To add the newer contracts to an environment
///      that already has a MemberRegistry fixed in its genesis transition, use
///      DeployGovernorUpgrade instead: redeploying the registry would mean a
///      new ValidatorSetView, a new genesis transition and a coordinated
///      restart of every node.
///
///      The awkward part is the bootstrap. Founding members cannot be added by
///      vote because there is no electorate until the first member exists, and
///      the factory pointer cannot be set by vote for the same reason. So the
///      deployer holds governance briefly, seeds both, and hands over.
///
///      THE DEPLOYER MUST END UP WITH NOTHING, which `_verify` asserts rather
///      than assumes: a deployment that silently left the deployer in control
///      would look identical to a correct one.
///
///      Run (from contracts/):
///        LOC_ENV=local forge script script/Deploy.s.sol:Deploy \
///          --rpc-url http://127.0.0.1:8600 --private-key $KEY \
///          --broadcast --legacy --gas-price 0
contract Deploy is Script {
    using stdJson for string;

    /// @notice Well-known key for the consortium's letter of credit factory.
    bytes32 public constant LOC_FACTORY_KEY = keccak256("loc-factory");

    struct Founding {
        string slug;
        string name;
        address validator;
        address account;
        string enode;
    }

    function _timings() internal view returns (uint64 voting, uint64 delay, uint64 window) {
        voting = uint64(vm.envOr("GOV_VOTING_PERIOD", uint256(3600)));
        delay = uint64(vm.envOr("GOV_EXECUTION_DELAY", uint256(600)));
        window = uint64(vm.envOr("GOV_EXECUTION_WINDOW", uint256(7200)));
    }

    function run() external {
        Founding[] memory members = _readConfig();
        require(members.length >= 3, "a consortium needs at least three validators");

        vm.startBroadcast();

        MemberRegistry registry = new MemberRegistry(msg.sender);
        ValidatorSetView validatorView = new ValidatorSetView(address(registry));
        InfrastructureRegistry infrastructure = new InfrastructureRegistry(address(registry));

        (uint64 voting, uint64 delay, uint64 window) = _timings();
        Governor governor =
            new Governor(address(registry), address(infrastructure), voting, delay, window);

        LetterOfCreditFactory factory = new LetterOfCreditFactory(address(registry));

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

        registry.endFoundingPhase();

        // Seeded before the handover for the same reason the members are: there
        // is no electorate yet. Afterwards this is a governance vote.
        infrastructure.set(LOC_FACTORY_KEY, address(factory));

        registry.transferGovernance(address(governor));

        vm.stopBroadcast();

        console.log("MemberRegistry        ", address(registry));
        console.log("ValidatorSetView      ", address(validatorView));
        console.log("InfrastructureRegistry", address(infrastructure));
        console.log("Governor              ", address(governor));
        console.log("LetterOfCreditFactory ", address(factory));
        console.log("");
        console.log("Put this address in the genesis transitions block:");
        console.log("  validatorcontractaddress =", address(validatorView));

        _verify(registry, validatorView, infrastructure, governor, factory, members);
    }

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

    function _verify(
        MemberRegistry registry,
        ValidatorSetView validatorView,
        InfrastructureRegistry infrastructure,
        Governor governor,
        LetterOfCreditFactory factory,
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
        require(
            infrastructure.get(LOC_FACTORY_KEY) == address(factory),
            "the factory pointer was not recorded"
        );
        require(address(factory.REGISTRY()) == address(registry), "factory points elsewhere");
        for (uint256 i = 0; i < members.length; ++i) {
            require(
                registry.isAccountAllowed(members[i].account),
                "a member account is not on the allowlist"
            );
        }
        console.log("verified: governance handed over, deployer holds nothing");
    }
}

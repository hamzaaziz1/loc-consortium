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

    /// @dev Blocks. At two-second blocks: ~2h voting, ~20m delay, ~4h window.
    ///      Short enough to demonstrate, long enough to be defensible. A real
    ///      consortium would measure the voting period in days.
    uint64 internal constant VOTING_PERIOD = 3600;
    uint64 internal constant EXECUTION_DELAY = 600;
    uint64 internal constant EXECUTION_WINDOW = 7200;

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
        Governor governor =
            new Governor(address(registry), VOTING_PERIOD, EXECUTION_DELAY, EXECUTION_WINDOW);

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
        console.log("");
        console.log("Put this address in the genesis transitions block:");
        console.log("  validatorcontractaddress =", address(validatorView));

        _verify(registry, validatorView, governor, members);
    }

    function _readConfig() internal view returns (Founding[] memory out) {
        string memory json = vm.readFile("../network/config/deploy.json");
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

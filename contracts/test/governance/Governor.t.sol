// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.28;

import { Test } from "forge-std/Test.sol";
import { MemberRegistry } from "../../src/governance/MemberRegistry.sol";
import { Governor } from "../../src/governance/Governor.sol";
import { IMemberRegistry } from "../../src/interfaces/IMemberRegistry.sol";
import { InfrastructureRegistry } from "../../src/governance/InfrastructureRegistry.sol";

contract GovernorTest is Test {
    MemberRegistry internal registry;
    InfrastructureRegistry internal infrastructure;
    Governor internal governor;

    address internal deployer = address(0xA0);

    bytes32 internal constant IMPORTER = keccak256("importer-bank");
    bytes32 internal constant EXPORTER = keccak256("exporter-bank");
    bytes32 internal constant LOGISTICS = keccak256("logistics");
    bytes32 internal constant OPERATOR = keccak256("operator");
    bytes32 internal constant NEWBANK = keccak256("new-bank");

    address internal aImporter = address(0x101);
    address internal aExporter = address(0x102);
    address internal aLogistics = address(0x103);
    address internal aOperator = address(0x104);

    uint64 internal constant VOTING_PERIOD = 100;
    uint64 internal constant EXECUTION_DELAY = 20;
    uint64 internal constant EXECUTION_WINDOW = 200;

    function setUp() public {
        registry = new MemberRegistry(deployer);
        infrastructure = new InfrastructureRegistry(address(registry));
        governor = new Governor(
            address(registry),
            address(infrastructure),
            VOTING_PERIOD,
            EXECUTION_DELAY,
            EXECUTION_WINDOW
        );

        _seed(IMPORTER, "Importer Bank", address(0x11), aImporter);
        _seed(EXPORTER, "Exporter Bank", address(0x12), aExporter);
        _seed(LOGISTICS, "Logistics", address(0x13), aLogistics);
        _seed(OPERATOR, "Operator", address(0x14), aOperator);

        vm.startPrank(deployer);
        registry.endFoundingPhase();
        // Seeding is done by the deployer because there is no electorate
        // before the first member exists. Governance moves to the Governor
        // once the founding set is in place, and the deployer keeps nothing.
        registry.transferGovernance(address(governor));
        vm.stopPrank();

        vm.roll(block.number + 1);
    }

    function _seed(bytes32 id, string memory name, address validatorAddr, address account)
        internal
    {
        address[] memory accounts = new address[](1);
        accounts[0] = account;
        string[] memory enodes = new string[](1);
        enodes[0] = "enode://aa@172.28.0.11:30303";
        vm.prank(deployer);
        registry.addMember(id, name, validatorAddr, true, accounts, enodes);
    }

    function _proposeStatus(address from, bytes32 subject, IMemberRegistry.Status s)
        internal
        returns (uint256 id)
    {
        vm.prank(from);
        id = governor.propose(Governor.Kind.SetStatus, subject, abi.encode(s));
    }

    // --- the deployer keeps nothing -----------------------------------------

    function test_deployerCannotWriteAfterHandover() public {
        vm.prank(deployer);
        vm.expectRevert(abi.encodeWithSelector(IMemberRegistry.NotGovernor.selector, deployer));
        registry.setValidator(IMPORTER, false);
    }

    // --- the subject cannot block its own removal ---------------------------

    /// @dev The rule that justifies excluding the subject. With four members
    ///      and a plain majority of all, the subject votes against and turns
    ///      three against one into a tie.
    function test_subjectCannotVoteOnItsOwnRemoval() public {
        uint256 id = _proposeStatus(aExporter, IMPORTER, IMemberRegistry.Status.Removed);

        vm.prank(aImporter);
        vm.expectRevert(abi.encodeWithSelector(Governor.SubjectCannotVote.selector, id, IMPORTER));
        governor.vote(id);
    }

    function test_removalNeedsTwoOfTheRemainingThree() public {
        assertEq(governor.votesRequired(IMPORTER), 2, "3 eligible, majority is 2");

        uint256 id = _proposeStatus(aExporter, IMPORTER, IMemberRegistry.Status.Removed);
        assertEq(governor.proposal(id).passedAt, 0, "one vote is not a majority");

        vm.prank(aLogistics);
        governor.vote(id);
        assertGt(governor.proposal(id).passedAt, 0, "two of three carries");
    }

    function test_additionNeedsMajorityOfAll() public view {
        assertEq(governor.votesRequired(bytes32(0)), 3, "4 eligible, majority is 3");
    }

    // --- the delay ------------------------------------------------------------

    function test_removalWaitsBeforeExecuting() public {
        uint256 id = _proposeStatus(aExporter, IMPORTER, IMemberRegistry.Status.Removed);
        vm.prank(aLogistics);
        governor.vote(id);

        (uint64 from,) = governor.executionWindowOf(id);
        assertEq(from, governor.proposal(id).passedAt + EXECUTION_DELAY);

        vm.expectRevert(abi.encodeWithSelector(Governor.TooEarly.selector, id, from));
        governor.execute(id);

        vm.roll(from);
        governor.execute(id);
        assertEq(uint8(registry.member(IMPORTER).status), uint8(IMemberRegistry.Status.Removed));
    }

    function test_additionExecutesImmediately() public {
        address[] memory accounts = new address[](1);
        accounts[0] = address(0x999);
        string[] memory enodes = new string[](0);
        bytes memory payload = abi.encode("New Bank", address(0x15), false, accounts, enodes);

        vm.prank(aImporter);
        uint256 id = governor.propose(Governor.Kind.AddMember, NEWBANK, payload);
        vm.prank(aExporter);
        governor.vote(id);
        vm.prank(aLogistics);
        governor.vote(id);

        (uint64 from,) = governor.executionWindowOf(id);
        assertEq(from, governor.proposal(id).passedAt, "no delay on additions");
        governor.execute(id);
        assertEq(uint8(registry.member(NEWBANK).status), uint8(IMemberRegistry.Status.Active));
    }

    // --- expiry ---------------------------------------------------------------

    function test_votingClosesAfterThePeriod() public {
        uint256 id = _proposeStatus(aExporter, IMPORTER, IMemberRegistry.Status.Removed);
        vm.roll(block.number + VOTING_PERIOD + 1);

        vm.prank(aLogistics);
        vm.expectRevert(abi.encodeWithSelector(Governor.VotingClosed.selector, id));
        governor.vote(id);
    }

    /// @dev A passed proposal that is never executed must die rather than sit
    ///      waiting to be used when tactically convenient.
    function test_passedProposalExpires() public {
        uint256 id = _proposeStatus(aExporter, IMPORTER, IMemberRegistry.Status.Removed);
        vm.prank(aLogistics);
        governor.vote(id);

        (, uint64 until) = governor.executionWindowOf(id);
        vm.roll(until + 1);
        vm.expectRevert(abi.encodeWithSelector(Governor.TooLate.selector, id, until));
        governor.execute(id);
    }

    // --- the floor still holds through governance ----------------------------

    /// @dev Two removals would leave two validators. The registry refuses,
    ///      so the second proposal passes the vote and then fails to execute.
    ///      Governance cannot vote the chain into a halt.
    function test_governanceCannotVoteTheChainIntoAHalt() public {
        uint256 first = _proposeStatus(aExporter, IMPORTER, IMemberRegistry.Status.Removed);
        vm.prank(aLogistics);
        governor.vote(first);
        (uint64 from,) = governor.executionWindowOf(first);
        vm.roll(from);
        governor.execute(first);
        assertEq(registry.activeValidators().length, 3);

        uint256 second = _proposeStatus(aLogistics, EXPORTER, IMemberRegistry.Status.Removed);
        vm.prank(aOperator);
        governor.vote(second);
        (uint64 from2,) = governor.executionWindowOf(second);
        vm.roll(from2);

        vm.expectRevert(
            abi.encodeWithSelector(IMemberRegistry.ValidatorFloorBreached.selector, 2, 3)
        );
        governor.execute(second);
        assertEq(registry.activeValidators().length, 3, "the chain keeps a quorum");
    }

    // --- access ----------------------------------------------------------------

    function test_nonMemberCannotPropose() public {
        vm.prank(address(0xDEAD));
        vm.expectRevert(abi.encodeWithSelector(Governor.NotAMember.selector, address(0xDEAD)));
        governor.propose(Governor.Kind.SetValidator, IMPORTER, abi.encode(false));
    }

    function test_suspendedMemberCannotVote() public {
        uint256 id = _proposeStatus(aExporter, IMPORTER, IMemberRegistry.Status.Suspended);
        vm.prank(aLogistics);
        governor.vote(id);
        (uint64 from,) = governor.executionWindowOf(id);
        vm.roll(from);
        governor.execute(id);

        uint256 next = _proposeStatus(aExporter, LOGISTICS, IMemberRegistry.Status.Suspended);
        vm.prank(aImporter);
        vm.expectRevert(abi.encodeWithSelector(Governor.NotActive.selector, IMPORTER));
        governor.vote(next);
    }

    function test_cannotVoteTwice() public {
        uint256 id = _proposeStatus(aExporter, IMPORTER, IMemberRegistry.Status.Removed);
        vm.prank(aExporter);
        vm.expectRevert(abi.encodeWithSelector(Governor.AlreadyVoted.selector, id, EXPORTER));
        governor.vote(id);
    }

    function test_onlyProposerCancels() public {
        uint256 id = _proposeStatus(aExporter, IMPORTER, IMemberRegistry.Status.Removed);
        vm.prank(aLogistics);
        vm.expectRevert(abi.encodeWithSelector(Governor.NotProposer.selector, id));
        governor.cancel(id);

        vm.prank(aExporter);
        governor.cancel(id);
        assertTrue(governor.proposal(id).cancelled);
    }

    // --- replacing the governor ------------------------------------------------

    /// @dev The property the whole two-layer split depends on. The registry
    ///      and the validator view are permanent because QBFT reads the view
    ///      at an address fixed in the genesis. The governor is replaceable
    ///      because process rules are what change. Without this path a buggy
    ///      governor is permanent and the registry's validator floor protects
    ///      nothing, because there would be no way to replace the thing it is
    ///      protecting against.
    function test_governanceCanBeReplacedByVote() public {
        Governor next = new Governor(
            address(registry),
            address(infrastructure),
            VOTING_PERIOD,
            EXECUTION_DELAY,
            EXECUTION_WINDOW
        );

        vm.prank(aImporter);
        uint256 id = governor.propose(
            Governor.Kind.TransferGovernance, bytes32(0), abi.encode(address(next))
        );
        vm.prank(aExporter);
        governor.vote(id);
        vm.prank(aLogistics);
        governor.vote(id);

        (uint64 from,) = governor.executionWindowOf(id);
        assertEq(from, governor.proposal(id).passedAt + EXECUTION_DELAY, "transfers wait");

        vm.roll(from);
        governor.execute(id);

        assertEq(registry.governor(), address(next));
    }

    function test_replacedGovernorCanNoLongerWrite() public {
        Governor next = new Governor(
            address(registry),
            address(infrastructure),
            VOTING_PERIOD,
            EXECUTION_DELAY,
            EXECUTION_WINDOW
        );
        vm.prank(aImporter);
        uint256 id = governor.propose(
            Governor.Kind.TransferGovernance, bytes32(0), abi.encode(address(next))
        );
        vm.prank(aExporter);
        governor.vote(id);
        vm.prank(aLogistics);
        governor.vote(id);
        (uint64 from,) = governor.executionWindowOf(id);
        vm.roll(from);
        governor.execute(id);

        // A proposal carried by the old governor can no longer reach the
        // registry, which is what "replaced" has to mean.
        uint256 stale = _proposeStatus(aExporter, IMPORTER, IMemberRegistry.Status.Suspended);
        vm.prank(aLogistics);
        governor.vote(stale);
        (uint64 staleFrom,) = governor.executionWindowOf(stale);
        vm.roll(staleFrom);
        vm.expectRevert(
            abi.encodeWithSelector(IMemberRegistry.NotGovernor.selector, address(governor))
        );
        governor.execute(stale);

        // The new one works.
        vm.prank(aExporter);
        uint256 fresh = next.propose(
            Governor.Kind.SetStatus, IMPORTER, abi.encode(IMemberRegistry.Status.Suspended)
        );
        vm.prank(aLogistics);
        next.vote(fresh);
        (uint64 freshFrom,) = next.executionWindowOf(fresh);
        vm.roll(freshFrom);
        next.execute(fresh);
        assertEq(uint8(registry.member(IMPORTER).status), uint8(IMemberRegistry.Status.Suspended));
    }

    function test_transferNeedsMajorityOfAll() public {
        Governor next = new Governor(
            address(registry),
            address(infrastructure),
            VOTING_PERIOD,
            EXECUTION_DELAY,
            EXECUTION_WINDOW
        );
        vm.prank(aImporter);
        uint256 id = governor.propose(
            Governor.Kind.TransferGovernance, bytes32(0), abi.encode(address(next))
        );
        vm.prank(aExporter);
        governor.vote(id);
        assertEq(governor.proposal(id).passedAt, 0, "two of four is not a majority");
    }

    function test_cannotTransferToNowhere() public {
        vm.prank(aImporter);
        uint256 id =
            governor.propose(Governor.Kind.TransferGovernance, bytes32(0), abi.encode(address(0)));
        vm.prank(aExporter);
        governor.vote(id);
        vm.prank(aLogistics);
        governor.vote(id);
        (uint64 from,) = governor.executionWindowOf(id);
        vm.roll(from);
        vm.expectRevert(Governor.BadParameters.selector);
        governor.execute(id);
        assertEq(registry.governor(), address(governor), "governance is unchanged");
    }

    // --- infrastructure -------------------------------------------------------

    /// @dev Closes a real gap: an application asking whether an address is a
    ///      genuine letter of credit calls `factory.isCredit`, which only means
    ///      anything if everyone agrees which factory. Without this, the
    ///      factory address is out-of-band configuration and a member could
    ///      deploy its own and issue credits that look identical.
    function test_infrastructureIsSetByVote() public {
        bytes32 key = keccak256("loc-factory");
        address factory = address(0xFACE);

        vm.prank(aImporter);
        uint256 id = governor.propose(
            Governor.Kind.SetInfrastructure, bytes32(0), abi.encode(key, factory)
        );
        vm.prank(aExporter);
        governor.vote(id);
        vm.prank(aLogistics);
        governor.vote(id);

        (uint64 from,) = governor.executionWindowOf(id);
        assertEq(from, governor.proposal(id).passedAt + EXECUTION_DELAY, "repointing waits");

        vm.roll(from);
        governor.execute(id);
        assertEq(infrastructure.get(key), factory);
    }

    function test_infrastructureCannotBeSetDirectly() public {
        vm.prank(aImporter);
        vm.expectRevert(
            abi.encodeWithSelector(InfrastructureRegistry.NotGovernor.selector, aImporter)
        );
        infrastructure.set(keccak256("loc-factory"), address(0xFACE));
    }

    /// @dev The infrastructure registry reads its authority from the member
    ///      registry rather than storing it, so replacing the Governor carries
    ///      over with no second transfer and nothing to drift.
    function test_infrastructureFollowsGovernanceReplacement() public {
        Governor next = new Governor(
            address(registry),
            address(infrastructure),
            VOTING_PERIOD,
            EXECUTION_DELAY,
            EXECUTION_WINDOW
        );
        vm.prank(aImporter);
        uint256 id = governor.propose(
            Governor.Kind.TransferGovernance, bytes32(0), abi.encode(address(next))
        );
        vm.prank(aExporter);
        governor.vote(id);
        vm.prank(aLogistics);
        governor.vote(id);
        (uint64 from,) = governor.executionWindowOf(id);
        vm.roll(from);
        governor.execute(id);

        bytes32 key = keccak256("loc-factory");
        vm.prank(aExporter);
        uint256 fresh = next.propose(
            Governor.Kind.SetInfrastructure, bytes32(0), abi.encode(key, address(0xBEEF))
        );
        vm.prank(aLogistics);
        next.vote(fresh);
        vm.prank(aOperator);
        next.vote(fresh);
        (uint64 freshFrom,) = next.executionWindowOf(fresh);
        vm.roll(freshFrom);
        next.execute(fresh);

        assertEq(infrastructure.get(key), address(0xBEEF));

        // And the replaced governor can no longer reach it.
        vm.prank(aImporter);
        uint256 stale = governor.propose(
            Governor.Kind.SetInfrastructure, bytes32(0), abi.encode(key, address(0xDEAD))
        );
        vm.prank(aExporter);
        governor.vote(stale);
        vm.prank(aLogistics);
        governor.vote(stale);
        (uint64 staleFrom,) = governor.executionWindowOf(stale);
        vm.roll(staleFrom);
        vm.expectRevert(
            abi.encodeWithSelector(InfrastructureRegistry.NotGovernor.selector, address(governor))
        );
        governor.execute(stale);
    }

    function test_unknownInfrastructureKeyReverts() public {
        vm.expectRevert(
            abi.encodeWithSelector(InfrastructureRegistry.UnknownEntry.selector, keccak256("nope"))
        );
        infrastructure.get(keccak256("nope"));
        assertEq(infrastructure.tryGet(keccak256("nope")), address(0));
    }

    // --- fuzz --------------------------------------------------------------------

    function testFuzz_onlyMemberAccountsCanPropose(address caller) public {
        vm.assume(caller != aImporter && caller != aExporter);
        vm.assume(caller != aLogistics && caller != aOperator);
        vm.prank(caller);
        vm.expectRevert();
        governor.propose(Governor.Kind.SetValidator, IMPORTER, abi.encode(false));
    }

    function testFuzz_validatorFloorSurvivesArbitraryExecution(uint8 a, uint8 b) public {
        bytes32[4] memory ids = [IMPORTER, EXPORTER, LOGISTICS, OPERATOR];
        address[4] memory voters = [aImporter, aExporter, aLogistics, aOperator];
        bytes32 target = ids[a % 4];
        address voter = voters[b % 4];

        vm.assume(registry.memberOfAccount(voter) != target);

        uint256 id = _proposeStatus(voter, target, IMemberRegistry.Status.Removed);
        for (uint256 i = 0; i < 4; ++i) {
            if (ids[i] == target || voters[i] == voter) continue;
            vm.prank(voters[i]);
            try governor.vote(id) { } catch { }
        }
        (uint64 from,) = governor.executionWindowOf(id);
        if (from != 0) {
            vm.roll(from);
            try governor.execute(id) { } catch { }
        }
        assertGe(registry.activeValidators().length, registry.VALIDATOR_FLOOR());
    }
}

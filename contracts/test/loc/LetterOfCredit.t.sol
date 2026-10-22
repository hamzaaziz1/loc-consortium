// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.28;

import { Test } from "forge-std/Test.sol";
import { MemberRegistry } from "../../src/governance/MemberRegistry.sol";
import { LetterOfCredit } from "../../src/loc/LetterOfCredit.sol";
import { LetterOfCreditFactory } from "../../src/loc/LetterOfCreditFactory.sol";
import { ILetterOfCredit } from "../../src/interfaces/ILetterOfCredit.sol";
import { IMemberRegistry } from "../../src/interfaces/IMemberRegistry.sol";

contract LetterOfCreditTest is Test {
    MemberRegistry internal registry;
    LetterOfCreditFactory internal factory;

    address internal deployer = address(0xA0);

    bytes32 internal constant IMPORTER = keccak256("importer-bank");
    bytes32 internal constant EXPORTER = keccak256("exporter-bank");
    bytes32 internal constant LOGISTICS = keccak256("logistics");
    bytes32 internal constant OPERATOR = keccak256("operator");

    address internal aImporter = address(0x101);
    address internal aExporter = address(0x102);
    address internal aLogistics = address(0x103);
    address internal aOperator = address(0x104);
    address internal stranger = address(0xBAD);

    bytes32 internal constant TERMS = keccak256("terms v1");
    bytes32 internal constant LOCATOR = keccak256("locator");
    uint64 internal expiry;

    function setUp() public {
        registry = new MemberRegistry(deployer);
        _seed(IMPORTER, "Importer Bank", address(0x11), aImporter);
        _seed(EXPORTER, "Exporter Bank", address(0x12), aExporter);
        _seed(LOGISTICS, "Logistics", address(0x13), aLogistics);
        _seed(OPERATOR, "Operator", address(0x14), aOperator);
        vm.prank(deployer);
        registry.endFoundingPhase();

        factory = new LetterOfCreditFactory(address(registry));
        expiry = uint64(block.timestamp + 30 days);
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

    function _issue() internal returns (LetterOfCredit loc) {
        vm.prank(aImporter);
        loc = LetterOfCredit(factory.issue(EXPORTER, LOGISTICS, TERMS, LOCATOR, expiry));
    }

    // --- the happy path, which is the legal lifecycle ------------------------

    function test_fullLifecycle() public {
        LetterOfCredit loc = _issue();
        assertEq(uint8(loc.state()), uint8(ILetterOfCredit.State.Issued));

        vm.prank(aExporter);
        loc.advise();
        assertEq(uint8(loc.state()), uint8(ILetterOfCredit.State.Advised));

        vm.prank(aLogistics);
        loc.recordMilestone(keccak256("loaded"), keccak256("bill of lading"));
        vm.prank(aLogistics);
        loc.recordMilestone(keccak256("departed"), keccak256("vessel"));
        assertEq(loc.milestoneCount(), 2);

        vm.prank(aExporter);
        loc.presentDocuments(keccak256("documents"));
        assertEq(uint8(loc.state()), uint8(ILetterOfCredit.State.Presented));

        vm.prank(aImporter);
        loc.acceptPresentation();
        assertEq(uint8(loc.state()), uint8(ILetterOfCredit.State.Accepted));

        vm.prank(aImporter);
        loc.recordSettlement(keccak256("swift ref"));
        assertEq(uint8(loc.state()), uint8(ILetterOfCredit.State.Settled));
        assertEq(loc.settlementHash(), keccak256("swift ref"));
    }

    // --- no commercial terms on chain ----------------------------------------

    /// @dev The property that makes the m6 privacy work possible. The chain
    ///      holds a commitment, never the terms, so the carrier can act on a
    ///      credit whose commercial content it cannot read.
    function test_onlyACommitmentToTermsIsStored() public {
        LetterOfCredit loc = _issue();
        assertEq(loc.TERMS_HASH(), TERMS);
        // Expiry is on chain because it must be enforceable and the carrier
        // legitimately needs it. Nothing else about the terms is.
        assertEq(loc.EXPIRY(), expiry);
    }

    function test_cannotIssueWithoutACommitment() public {
        vm.prank(aImporter);
        vm.expectRevert(LetterOfCreditFactory.EmptyCommitment.selector);
        factory.issue(EXPORTER, LOGISTICS, bytes32(0), LOCATOR, expiry);
    }

    // --- roles come from the registry ----------------------------------------

    function test_onlyTheBeneficiaryBankAdvises() public {
        LetterOfCredit loc = _issue();
        vm.prank(aImporter);
        vm.expectRevert(
            abi.encodeWithSelector(ILetterOfCredit.NotAuthorised.selector, aImporter, EXPORTER)
        );
        loc.advise();
    }

    function test_onlyTheCarrierRecordsMilestones() public {
        LetterOfCredit loc = _issue();
        vm.prank(aExporter);
        loc.advise();
        vm.prank(aExporter);
        vm.expectRevert(
            abi.encodeWithSelector(ILetterOfCredit.NotAuthorised.selector, aExporter, LOGISTICS)
        );
        loc.recordMilestone(keccak256("loaded"), bytes32(0));
    }

    function test_nonMembersCannotActAtAll() public {
        LetterOfCredit loc = _issue();
        vm.prank(stranger);
        vm.expectRevert();
        loc.advise();
    }

    /// @dev The reason roles are resolved through the registry rather than
    ///      stored locally: a governance decision takes effect on live credits
    ///      immediately, with nothing to keep in step.
    function test_suspendedMemberLosesAccessToLiveCredits() public {
        LetterOfCredit loc = _issue();
        vm.prank(aExporter);
        loc.advise();

        vm.prank(deployer);
        registry.setStatus(EXPORTER, IMemberRegistry.Status.Suspended);

        vm.prank(aExporter);
        vm.expectRevert(abi.encodeWithSelector(ILetterOfCredit.MemberNotActive.selector, EXPORTER));
        loc.presentDocuments(keccak256("documents"));
    }

    function test_uninvolvedMemberCannotAct() public {
        LetterOfCredit loc = _issue();
        vm.prank(aOperator);
        vm.expectRevert(
            abi.encodeWithSelector(ILetterOfCredit.NotAuthorised.selector, aOperator, EXPORTER)
        );
        loc.advise();
    }

    // --- the state machine refuses out-of-order steps -------------------------

    function test_cannotPresentBeforeAdvice() public {
        LetterOfCredit loc = _issue();
        vm.prank(aExporter);
        vm.expectRevert(
            abi.encodeWithSelector(
                ILetterOfCredit.WrongState.selector,
                ILetterOfCredit.State.Issued,
                ILetterOfCredit.State.Advised
            )
        );
        loc.presentDocuments(keccak256("documents"));
    }

    function test_cannotSettleWithoutAcceptance() public {
        LetterOfCredit loc = _issue();
        vm.prank(aExporter);
        loc.advise();
        vm.prank(aExporter);
        loc.presentDocuments(keccak256("documents"));

        vm.prank(aImporter);
        vm.expectRevert(
            abi.encodeWithSelector(
                ILetterOfCredit.WrongState.selector,
                ILetterOfCredit.State.Presented,
                ILetterOfCredit.State.Accepted
            )
        );
        loc.recordSettlement(keccak256("swift ref"));
    }

    function test_rejectionIsTerminal() public {
        LetterOfCredit loc = _issue();
        vm.prank(aExporter);
        loc.advise();
        vm.prank(aExporter);
        loc.presentDocuments(keccak256("documents"));
        vm.prank(aImporter);
        loc.rejectPresentation(keccak256("discrepancies"));

        vm.prank(aImporter);
        vm.expectRevert();
        loc.acceptPresentation();
    }

    // --- expiry and cancellation ----------------------------------------------

    function test_cannotAdviseAfterExpiry() public {
        LetterOfCredit loc = _issue();
        vm.warp(expiry + 1);
        vm.prank(aExporter);
        vm.expectRevert(abi.encodeWithSelector(ILetterOfCredit.CreditExpired.selector, expiry));
        loc.advise();
    }

    function test_anyoneMayExpireALapsedCredit() public {
        LetterOfCredit loc = _issue();
        vm.warp(expiry + 1);
        vm.prank(stranger);
        loc.expire();
        assertEq(uint8(loc.state()), uint8(ILetterOfCredit.State.Expired));
    }

    function test_cannotExpireEarly() public {
        LetterOfCredit loc = _issue();
        vm.expectRevert(
            abi.encodeWithSelector(ILetterOfCredit.CreditNotYetExpired.selector, expiry)
        );
        loc.expire();
    }

    /// @dev An advised credit cannot be withdrawn unilaterally. That is what
    ///      irrevocability means, and it is the single most important
    ///      restriction in the whole instrument.
    function test_cannotCancelOnceAdvised() public {
        LetterOfCredit loc = _issue();
        vm.prank(aExporter);
        loc.advise();
        vm.prank(aImporter);
        vm.expectRevert();
        loc.cancel(keccak256("changed our mind"));
    }

    function test_canCancelBeforeAdvice() public {
        LetterOfCredit loc = _issue();
        vm.prank(aImporter);
        loc.cancel(keccak256("applicant withdrew"));
        assertEq(uint8(loc.state()), uint8(ILetterOfCredit.State.Cancelled));
    }

    /// @dev Examination legitimately runs past expiry, so a timely
    ///      presentation must stay acceptable afterwards.
    function test_acceptanceSurvivesExpiryAfterTimelyPresentation() public {
        LetterOfCredit loc = _issue();
        vm.prank(aExporter);
        loc.advise();
        vm.prank(aExporter);
        loc.presentDocuments(keccak256("documents"));

        vm.warp(expiry + 5 days);
        vm.prank(aImporter);
        loc.acceptPresentation();
        assertEq(uint8(loc.state()), uint8(ILetterOfCredit.State.Accepted));
    }

    // --- the factory ------------------------------------------------------------

    function test_issuerIsTheCaller() public {
        LetterOfCredit loc = _issue();
        (bytes32 issuing,,) = loc.parties();
        assertEq(issuing, IMPORTER);
    }

    function test_partiesMustDiffer() public {
        vm.prank(aImporter);
        vm.expectRevert(LetterOfCreditFactory.PartiesMustDiffer.selector);
        factory.issue(IMPORTER, LOGISTICS, TERMS, LOCATOR, expiry);
    }

    function test_cannotIssueToASuspendedMember() public {
        vm.prank(deployer);
        registry.setStatus(LOGISTICS, IMemberRegistry.Status.Suspended);
        vm.prank(aImporter);
        vm.expectRevert(
            abi.encodeWithSelector(LetterOfCreditFactory.MemberNotActive.selector, LOGISTICS)
        );
        factory.issue(EXPORTER, LOGISTICS, TERMS, LOCATOR, expiry);
    }

    function test_nonMemberCannotIssue() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(LetterOfCreditFactory.NotAMember.selector, stranger));
        factory.issue(EXPORTER, LOGISTICS, TERMS, LOCATOR, expiry);
    }

    function test_creditsAreIndexedForEveryParty() public {
        LetterOfCredit loc = _issue();
        assertEq(factory.creditCount(), 1);
        assertTrue(factory.isCredit(address(loc)));
        assertEq(factory.creditsOf(IMPORTER).length, 1);
        assertEq(factory.creditsOf(EXPORTER).length, 1);
        assertEq(factory.creditsOf(LOGISTICS).length, 1);
        assertEq(factory.creditsOf(OPERATOR).length, 0);
    }

    function test_eachCreditIsItsOwnInstance() public {
        LetterOfCredit a = _issue();
        LetterOfCredit b = _issue();
        assertTrue(address(a) != address(b));

        // One credit progressing does not touch another, which is the point of
        // an instance per credit rather than one contract holding many.
        vm.prank(aExporter);
        a.advise();
        assertEq(uint8(b.state()), uint8(ILetterOfCredit.State.Issued));
    }

    // --- fuzz ----------------------------------------------------------------------

    function testFuzz_onlyNamedPartiesCanAdvise(address caller) public {
        vm.assume(caller != aExporter);
        LetterOfCredit loc = _issue();
        vm.prank(caller);
        vm.expectRevert();
        loc.advise();
    }

    function testFuzz_expiryIsAlwaysInTheFuture(uint64 candidate) public {
        vm.assume(candidate <= uint64(block.timestamp));
        vm.prank(aImporter);
        vm.expectRevert(
            abi.encodeWithSelector(LetterOfCreditFactory.ExpiryInThePast.selector, candidate)
        );
        factory.issue(EXPORTER, LOGISTICS, TERMS, LOCATOR, candidate);
    }
}

// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.28;

import { Test } from "forge-std/Test.sol";
import { MemberRegistry } from "../../src/governance/MemberRegistry.sol";
import { ValidatorSetView } from "../../src/governance/ValidatorSetView.sol";
import { IMemberRegistry } from "../../src/interfaces/IMemberRegistry.sol";

contract MemberRegistryTest is Test {
    MemberRegistry internal registry;
    ValidatorSetView internal view_;

    address internal governorAddr = address(0xA0);
    address internal stranger = address(0xBAD);

    bytes32 internal constant IMPORTER = keccak256("importer-bank");
    bytes32 internal constant EXPORTER = keccak256("exporter-bank");
    bytes32 internal constant LOGISTICS = keccak256("logistics");
    bytes32 internal constant OPERATOR = keccak256("operator");

    address internal vImporter = address(0x11);
    address internal vExporter = address(0x12);
    address internal vLogistics = address(0x13);
    address internal vOperator = address(0x14);

    function setUp() public {
        registry = new MemberRegistry(governorAddr);
        view_ = new ValidatorSetView(address(registry));
        _seedFourMembers();
    }

    function _add(bytes32 id, string memory name, address validatorAddr, address account) internal {
        address[] memory accounts = new address[](1);
        accounts[0] = account;
        string[] memory enodes = new string[](1);
        enodes[0] = "enode://aa@172.28.0.11:30303";
        vm.prank(governorAddr);
        registry.addMember(id, name, validatorAddr, true, accounts, enodes);
    }

    function _seedFourMembers() internal {
        _add(IMPORTER, "Importer Bank", vImporter, address(0x101));
        _add(EXPORTER, "Exporter Bank", vExporter, address(0x102));
        _add(LOGISTICS, "Logistics Operator", vLogistics, address(0x103));
        _add(OPERATOR, "Consortium Operator", vOperator, address(0x104));
        vm.prank(governorAddr);
        registry.endFoundingPhase();
    }

    // --- basics -------------------------------------------------------------

    function test_seedsFourActiveValidators() public view {
        assertEq(registry.activeValidators().length, 4);
        assertEq(registry.activeMemberCount(), 4);
        assertTrue(registry.founded());
    }

    function test_validatorViewMatchesRegistry() public view {
        assertEq(view_.getValidators().length, registry.activeValidators().length);
        assertEq(view_.getValidators()[0], registry.activeValidators()[0]);
    }

    function test_onlyGovernorCanWrite() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IMemberRegistry.NotGovernor.selector, stranger));
        registry.setValidator(IMPORTER, false);
    }

    function test_accountAllowlistTracksStatus() public {
        assertTrue(registry.isAccountAllowed(address(0x101)));
        vm.prank(governorAddr);
        registry.setStatus(IMPORTER, IMemberRegistry.Status.Suspended);
        assertFalse(registry.isAccountAllowed(address(0x101)));
    }

    function test_duplicateAccountRejected() public {
        vm.prank(governorAddr);
        vm.expectRevert(
            abi.encodeWithSelector(IMemberRegistry.DuplicateAccount.selector, address(0x101))
        );
        registry.addAccount(EXPORTER, address(0x101));
    }

    // --- the validator floor, which is the invariant that matters -----------

    function test_canRemoveOneValidator() public {
        vm.prank(governorAddr);
        registry.setValidator(IMPORTER, false);
        assertEq(registry.activeValidators().length, 3);
    }

    function test_cannotDropBelowFloorByFlag() public {
        vm.prank(governorAddr);
        registry.setValidator(IMPORTER, false);

        vm.prank(governorAddr);
        vm.expectRevert(
            abi.encodeWithSelector(IMemberRegistry.ValidatorFloorBreached.selector, 2, 3)
        );
        registry.setValidator(EXPORTER, false);
    }

    function test_cannotDropBelowFloorByStatus() public {
        vm.prank(governorAddr);
        registry.setStatus(IMPORTER, IMemberRegistry.Status.Removed);

        vm.prank(governorAddr);
        vm.expectRevert(
            abi.encodeWithSelector(IMemberRegistry.ValidatorFloorBreached.selector, 2, 3)
        );
        registry.setStatus(EXPORTER, IMemberRegistry.Status.Suspended);
    }

    /// @dev The floor is the last line of defence, so it must hold against a
    ///      governor that is actively trying to break it rather than only
    ///      against honest mistakes.
    function test_floorHoldsAgainstAMaliciousGovernor() public {
        vm.startPrank(governorAddr);
        registry.setValidator(IMPORTER, false);
        vm.expectRevert();
        registry.setValidator(EXPORTER, false);
        vm.expectRevert();
        registry.setStatus(EXPORTER, IMemberRegistry.Status.Removed);
        vm.stopPrank();
        assertEq(registry.activeValidators().length, 3);
    }

    function test_foundingPhaseAllowsGrowthFromZero() public {
        MemberRegistry fresh = new MemberRegistry(governorAddr);
        address[] memory accounts = new address[](0);
        string[] memory enodes = new string[](0);

        vm.startPrank(governorAddr);
        fresh.addMember(IMPORTER, "Importer Bank", vImporter, true, accounts, enodes);
        assertEq(fresh.activeValidators().length, 1, "one validator is allowed while founding");
        fresh.addMember(EXPORTER, "Exporter Bank", vExporter, true, accounts, enodes);
        fresh.addMember(LOGISTICS, "Logistics", vLogistics, true, accounts, enodes);
        fresh.endFoundingPhase();
        vm.stopPrank();

        assertTrue(fresh.founded());
    }

    function test_cannotEndFoundingPhaseBelowFloor() public {
        MemberRegistry fresh = new MemberRegistry(governorAddr);
        address[] memory accounts = new address[](0);
        string[] memory enodes = new string[](0);

        vm.startPrank(governorAddr);
        fresh.addMember(IMPORTER, "Importer Bank", vImporter, true, accounts, enodes);
        vm.expectRevert(
            abi.encodeWithSelector(IMemberRegistry.ValidatorFloorBreached.selector, 1, 3)
        );
        fresh.endFoundingPhase();
        vm.stopPrank();
    }

    // --- governance replacement ---------------------------------------------

    function test_governanceCanBeTransferred() public {
        address newGovernor = address(0xBEEF);
        vm.prank(governorAddr);
        registry.transferGovernance(newGovernor);

        vm.prank(governorAddr);
        vm.expectRevert(abi.encodeWithSelector(IMemberRegistry.NotGovernor.selector, governorAddr));
        registry.setValidator(IMPORTER, false);

        vm.prank(newGovernor);
        registry.setValidator(IMPORTER, false);
        assertEq(registry.activeValidators().length, 3);
    }

    /// @dev The view's registry pointer is immutable by design: if it could be
    ///      repointed, whoever could repoint it would control consensus.
    function test_validatorViewPointerIsFixed() public view {
        assertEq(address(view_.REGISTRY()), address(registry));
    }

    // --- fuzz ----------------------------------------------------------------

    function testFuzz_onlyGovernorEverWrites(address caller) public {
        vm.assume(caller != governorAddr);
        vm.prank(caller);
        vm.expectRevert();
        registry.setStatus(IMPORTER, IMemberRegistry.Status.Suspended);
    }

    function testFuzz_validatorCountNeverBelowFloorAfterFounding(uint8 which) public {
        bytes32[4] memory ids = [IMPORTER, EXPORTER, LOGISTICS, OPERATOR];
        bytes32 id = ids[which % 4];

        vm.prank(governorAddr);
        try registry.setValidator(id, false) { } catch { }

        assertGe(registry.activeValidators().length, registry.VALIDATOR_FLOOR());
    }
}

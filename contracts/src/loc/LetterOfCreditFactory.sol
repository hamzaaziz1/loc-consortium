// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.28;

import { LetterOfCredit } from "./LetterOfCredit.sol";
import { IMemberRegistry } from "../interfaces/IMemberRegistry.sol";

/// @title LetterOfCreditFactory
/// @notice Issues letters of credit and keeps the index of them.
///
/// @dev One instance per credit, not one contract holding many. That follows
///      from the decision not to make credits upgradeable: a bug is fixed by
///      deploying a new factory and issuing new credits under it, while
///      existing credits run to completion under the code they were created
///      with. A single shared contract would make every credit share a fate.
///
///      The factory is the only thing that needs replacing to change future
///      behaviour, and replacing it changes nothing about credits already
///      issued. That is the property being bought.
contract LetterOfCreditFactory {
    IMemberRegistry public immutable REGISTRY;

    /// @notice Every credit this factory has issued, in order.
    address[] private _credits;
    mapping(address credit => bool) public isCredit;
    mapping(bytes32 member => address[]) private _creditsByMember;

    event CreditIssued(
        address indexed credit,
        bytes32 indexed issuingBank,
        bytes32 indexed beneficiaryBank,
        bytes32 carrier,
        bytes32 termsHash,
        uint64 expiry
    );

    error NotAMember(address caller);
    error MemberNotActive(bytes32 member);
    error PartiesMustDiffer();
    error ExpiryInThePast(uint64 expiry);
    error EmptyCommitment();

    constructor(address registry) {
        REGISTRY = IMemberRegistry(registry);
    }

    /// @notice Opens a credit. The caller's organisation becomes the issuing
    ///         bank: a bank cannot open a credit in another bank's name.
    function issue(
        bytes32 beneficiaryBank,
        bytes32 carrier,
        bytes32 termsHash,
        bytes32 termsLocator,
        uint64 expiry
    ) external returns (address credit) {
        bytes32 issuingBank = REGISTRY.memberOfAccount(msg.sender);
        if (issuingBank == bytes32(0)) revert NotAMember(msg.sender);

        _requireActive(issuingBank);
        _requireActive(beneficiaryBank);
        _requireActive(carrier);

        // Three distinct organisations. A credit where the issuing and
        // beneficiary banks are the same party is not a documentary credit,
        // and allowing it would make the role checks meaningless.
        if (issuingBank == beneficiaryBank || issuingBank == carrier || beneficiaryBank == carrier)
        {
            revert PartiesMustDiffer();
        }

        if (termsHash == bytes32(0)) revert EmptyCommitment();
        // Expiry is a calendar date; validator timestamp tolerance is seconds.
        // forge-lint: disable-next-line(unsafe-typecast, block-timestamp)
        if (expiry <= uint64(block.timestamp)) revert ExpiryInThePast(expiry);

        credit = address(
            new LetterOfCredit(
                address(REGISTRY),
                issuingBank,
                beneficiaryBank,
                carrier,
                termsHash,
                termsLocator,
                expiry
            )
        );

        _credits.push(credit);
        isCredit[credit] = true;
        _creditsByMember[issuingBank].push(credit);
        _creditsByMember[beneficiaryBank].push(credit);
        _creditsByMember[carrier].push(credit);

        // Emitted after the deployment because the address is part of the
        // event. The callee is a contract this factory just created from known
        // bytecode with no constructor callbacks, so there is nothing that
        // could reorder this log.
        // forge-lint: disable-next-line(reentrancy-events)
        emit CreditIssued(credit, issuingBank, beneficiaryBank, carrier, termsHash, expiry);
    }

    function _requireActive(bytes32 member) private view {
        if (REGISTRY.member(member).status != IMemberRegistry.Status.Active) {
            revert MemberNotActive(member);
        }
    }

    function creditCount() external view returns (uint256) {
        return _credits.length;
    }

    function credits() external view returns (address[] memory) {
        return _credits;
    }

    /// @notice Credits a given organisation is a party to, in any role.
    function creditsOf(bytes32 member) external view returns (address[] memory) {
        return _creditsByMember[member];
    }
}

// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.28;

/// @title Letter of credit lifecycle
/// @notice The states and transitions of a documentary credit, as the paper
///         instrument defines them.
///
/// @dev The lifecycle is an explicit enum with one transition per function
///      rather than scattered checks, because the audit value of this contract
///      is that a reader can recover the legal lifecycle from the code. A
///      reviewer should not have to assemble it from require statements.
interface ILetterOfCredit {
    /// @dev Mirrors the paper process:
    ///      Issued    the issuing bank has opened the credit
    ///      Advised   the beneficiary's bank has acknowledged it
    ///      Presented the beneficiary's bank has presented documents
    ///      Accepted  the issuing bank has accepted the presentation
    ///      Rejected  the issuing bank has refused it, citing discrepancies
    ///      Settled   payment has been made and recorded
    ///      Expired   the credit lapsed before presentation
    ///      Cancelled withdrawn by agreement before advice
    enum State {
        None,
        Issued,
        Advised,
        Presented,
        Accepted,
        Rejected,
        Settled,
        Expired,
        Cancelled
    }

    /// @dev A shipment event recorded by the carrier. Deliberately carries no
    ///      commercial information: a milestone says that something happened
    ///      and when, with a hash committing to the detail held off chain.
    ///      This is what lets the carrier prove shipment without reading the
    ///      credit's terms. See ADR 0007.
    struct Milestone {
        bytes32 kind;
        bytes32 detailHash;
        uint64 recordedAt;
        address recordedBy;
    }

    event Advised(bytes32 indexed by);
    event MilestoneRecorded(bytes32 indexed kind, bytes32 detailHash, uint256 index);
    event DocumentsPresented(bytes32 documentsHash);
    event PresentationAccepted();
    event PresentationRejected(bytes32 reasonHash);
    event Settled(bytes32 paymentReferenceHash);
    event Expired();
    event Cancelled(bytes32 reasonHash);

    error WrongState(State current, State required);
    error NotAuthorised(address caller, bytes32 requiredMember);
    error MemberNotActive(bytes32 member);
    error CreditExpired(uint64 expiry);
    error CreditNotYetExpired(uint64 expiry);
    error EmptyCommitment();
}

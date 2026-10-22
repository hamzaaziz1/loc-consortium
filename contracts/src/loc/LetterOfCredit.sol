// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.28;

import { ILetterOfCredit } from "../interfaces/ILetterOfCredit.sol";
import { IMemberRegistry } from "../interfaces/IMemberRegistry.sol";

/// @title LetterOfCredit
/// @notice One documentary credit, from issuance to settlement.
///
/// @dev DELIBERATELY NOT UPGRADEABLE. A letter of credit is a legal instrument
///      with a defined lifecycle, and a contract whose behaviour can change
///      mid-flight undermines the thing it exists to prove. Each credit is a
///      separate instance from the factory, so a bug is fixed by deploying a
///      new implementation and issuing new credits under it while existing
///      ones run to completion under the code they were created with.
///
///      The cost, stated plainly: a bug in a live credit cannot be patched,
///      only worked around by agreement between the parties. That is exactly
///      what happens with the paper process, and it is the right trade for an
///      instrument whose value is that its terms did not change. See ADR 0007.
///
///      ROLES COME FROM THE REGISTRY, NOT FROM LOCAL STORAGE. A caller's
///      organisation is resolved through `memberOfAccount`, and the credit
///      names which organisation holds each role. So a member suspended by
///      governance immediately loses the ability to act on live credits, with
///      no second mechanism to keep in step. Identity comes from the registry,
///      the role comes from the instrument.
///
///      NO COMMERCIAL TERMS ARE STORED. The chain holds a commitment to the
///      terms, not the terms. Amount, goods, pricing and documentary
///      requirements live off chain, encrypted per party. That is what lets
///      the carrier record shipment milestones against a credit whose
///      commercial content it cannot read. The m6 work builds the
///      distribution; this contract is already shaped for it.
contract LetterOfCredit is ILetterOfCredit {
    IMemberRegistry public immutable REGISTRY;

    /// @notice The organisation that opened the credit, on the applicant's behalf.
    bytes32 public immutable ISSUING_BANK;
    /// @notice The organisation advising and presenting, for the beneficiary.
    bytes32 public immutable BENEFICIARY_BANK;
    /// @notice The organisation carrying the goods and recording milestones.
    bytes32 public immutable CARRIER;

    /// @notice Commitment to the credit's terms, held off chain.
    bytes32 public immutable TERMS_HASH;
    /// @notice External reference, so a party can find its copy of the terms.
    ///         Not secret and not sufficient to read them.
    bytes32 public immutable TERMS_LOCATOR;

    /// @notice Expiry is on chain because it has to be enforceable, and because
    ///         the carrier legitimately needs it. The rest of the terms do not
    ///         have that property.
    uint64 public immutable EXPIRY;

    State public state;
    bytes32 public documentsHash;
    bytes32 public settlementHash;

    Milestone[] private _milestones;

    constructor(
        address registry,
        bytes32 issuingBank,
        bytes32 beneficiaryBank,
        bytes32 carrier,
        bytes32 termsHash,
        bytes32 termsLocator,
        uint64 expiry
    ) {
        if (termsHash == bytes32(0)) revert EmptyCommitment();
        REGISTRY = IMemberRegistry(registry);
        ISSUING_BANK = issuingBank;
        BENEFICIARY_BANK = beneficiaryBank;
        CARRIER = carrier;
        TERMS_HASH = termsHash;
        TERMS_LOCATOR = termsLocator;
        EXPIRY = expiry;
        state = State.Issued;
    }

    // --- access -------------------------------------------------------------

    /// @dev Resolves the caller's organisation and checks both that it is the
    ///      one this role belongs to and that it is still Active. A suspended
    ///      member is refused even where it holds the role.
    modifier onlyMember(bytes32 member) {
        bytes32 caller = REGISTRY.memberOfAccount(msg.sender);
        if (caller != member) revert NotAuthorised(msg.sender, member);
        if (REGISTRY.member(caller).status != IMemberRegistry.Status.Active) {
            revert MemberNotActive(caller);
        }
        _;
    }

    modifier inState(State required) {
        if (state != required) revert WrongState(state, required);
        _;
    }

    modifier notExpired() {
        // Validators can nudge block.timestamp within a tolerance, and one of
        // the four is assumed potentially hostile. It does not matter here: a
        // credit's expiry is a calendar date and the tolerance is seconds. A
        // design where seconds of drift changed the outcome would be the bug.
        // forge-lint: disable-next-line(unsafe-typecast, block-timestamp)
        if (uint64(block.timestamp) > EXPIRY) revert CreditExpired(EXPIRY);
        _;
    }

    // --- lifecycle ------------------------------------------------------------

    /// @notice The beneficiary's bank acknowledges the credit.
    function advise() external onlyMember(BENEFICIARY_BANK) inState(State.Issued) notExpired {
        state = State.Advised;
        emit Advised(BENEFICIARY_BANK);
    }

    /// @notice The carrier records a shipment event.
    /// @dev Allowed from Advised through Presented: goods can still move while
    ///      documents are with the issuing bank, and refusing to record a real
    ///      event because of the credit's paperwork state would make the record
    ///      less truthful rather than more controlled.
    function recordMilestone(bytes32 kind, bytes32 detailHash)
        external
        onlyMember(CARRIER)
        returns (uint256 index)
    {
        if (state != State.Advised && state != State.Presented) {
            revert WrongState(state, State.Advised);
        }
        index = _milestones.length;
        _milestones.push(
            Milestone({
                kind: kind,
                detailHash: detailHash,
                // forge-lint: disable-next-line(unsafe-typecast)
                recordedAt: uint64(block.timestamp),
                recordedBy: msg.sender
            })
        );
        emit MilestoneRecorded(kind, detailHash, index);
    }

    /// @notice The beneficiary's bank presents documents.
    function presentDocuments(bytes32 documents)
        external
        onlyMember(BENEFICIARY_BANK)
        inState(State.Advised)
        notExpired
    {
        if (documents == bytes32(0)) revert EmptyCommitment();
        documentsHash = documents;
        state = State.Presented;
        emit DocumentsPresented(documents);
    }

    /// @notice The issuing bank accepts the presentation.
    /// @dev No expiry check. Presentation happened in time; the issuing bank's
    ///      examination period legitimately extends past expiry, and refusing
    ///      a timely presentation because examination ran long would be wrong.
    function acceptPresentation() external onlyMember(ISSUING_BANK) inState(State.Presented) {
        state = State.Accepted;
        emit PresentationAccepted();
    }

    /// @notice The issuing bank refuses the presentation, citing discrepancies.
    /// @dev Rejected is terminal for this credit. The paper process allows a
    ///      corrected re-presentation, which here means a new credit: amending
    ///      a refused instrument in place is exactly the mutability this design
    ///      rejects.
    function rejectPresentation(bytes32 reasonHash)
        external
        onlyMember(ISSUING_BANK)
        inState(State.Presented)
    {
        state = State.Rejected;
        emit PresentationRejected(reasonHash);
    }

    /// @notice The issuing bank records that payment has been made.
    /// @dev Records rather than performs. There is no value on this chain and
    ///      settlement happens in the banking system; what belongs here is the
    ///      attestation that it happened, bound to the credit it discharges.
    function recordSettlement(bytes32 paymentReferenceHash)
        external
        onlyMember(ISSUING_BANK)
        inState(State.Accepted)
    {
        settlementHash = paymentReferenceHash;
        state = State.Settled;
        emit Settled(paymentReferenceHash);
    }

    /// @notice Marks a credit that lapsed before presentation.
    /// @dev Callable by anyone once expiry has passed. The state change is a
    ///      fact about the clock rather than a decision, so gating it on a role
    ///      would only let an inattentive party leave stale credits open.
    function expire() external {
        if (state != State.Issued && state != State.Advised) {
            revert WrongState(state, State.Advised);
        }
        // forge-lint: disable-next-line(unsafe-typecast, block-timestamp)
        if (uint64(block.timestamp) <= EXPIRY) revert CreditNotYetExpired(EXPIRY);
        state = State.Expired;
        emit Expired();
    }

    /// @notice Withdraws a credit before it has been advised.
    /// @dev Only before advice. Once the beneficiary's bank has acknowledged
    ///      the credit the beneficiary may have acted on it, and unilateral
    ///      cancellation is precisely what an irrevocable credit forbids.
    function cancel(bytes32 reasonHash) external onlyMember(ISSUING_BANK) inState(State.Issued) {
        state = State.Cancelled;
        emit Cancelled(reasonHash);
    }

    // --- views ----------------------------------------------------------------

    function milestones() external view returns (Milestone[] memory) {
        return _milestones;
    }

    function milestoneCount() external view returns (uint256) {
        return _milestones.length;
    }

    function parties()
        external
        view
        returns (bytes32 issuing, bytes32 beneficiary, bytes32 carrier)
    {
        return (ISSUING_BANK, BENEFICIARY_BANK, CARRIER);
    }
}

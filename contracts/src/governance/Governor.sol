// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.28;

import { IMemberRegistry } from "../interfaces/IMemberRegistry.sol";

/// @title Governor
/// @notice Proposal, vote and execution for consortium membership changes.
///
/// @dev This contract holds process. The registry holds the invariant. If this
///      contract is replaced by a buggy one — and it is replaceable, by
///      transferring governance on the registry — the validator floor still
///      holds, because the thing that can brick the chain is guarded at the
///      last line and not only the first.
///
///      Three rules shape everything here.
///
///      1. ANY ACTIVE MEMBER MAY PROPOSE. With four members, restricting
///         proposal rights buys nothing and creates a gatekeeper.
///
///      2. A STRICT MAJORITY OF ACTIVE MEMBERS, EXCLUDING THE SUBJECT. This
///         matters more than it looks. With four members and a plain majority
///         of all, a member facing removal votes against it and turns three
///         against one into a tie. Excluding the subject means removal needs
///         two of the remaining three, and no member can filibuster its own
///         exit. Proposals with no existing subject, such as adding a member,
///         need a majority of all active members.
///
///      3. PROPOSALS EXPIRE, AND EXPIRY IS MEASURED IN BLOCKS. A proposal that
///         sits open for a year and then executes is a governance bug: the
///         votes cast reflected a consortium that may no longer exist, and
///         someone can sit on a passed removal until it is tactically useful.
///         Blocks rather than timestamps because QBFT block time is fixed and
///         validators control timestamps within a tolerance; with one
///         potentially hostile member, timestamps are the weaker clock.
///
///      Reductions in standing wait before executing, so a member being
///      removed has a window to see it coming and the others have a window to
///      notice a hostile proposal passing. Additions execute as soon as they
///      pass, because adding a member cannot brick anything.
///
///      There is deliberately no emergency bypass. The bypass is where
///      governance contracts usually get compromised, and the PKI revocation
///      path exists in parallel if a member must be cut off faster than
///      governance can act.
contract Governor {
    enum Kind {
        None,
        AddMember,
        SetStatus,
        SetValidator,
        AddAccount,
        RemoveAccount,
        AddEnode,
        RemoveEnode
    }

    struct Proposal {
        Kind kind;
        bytes32 subject;
        address proposer;
        bytes32 proposerMember;
        uint64 votingEndsAt;
        uint64 passedAt;
        bool executed;
        bool cancelled;
        uint32 forVotes;
        bytes payload;
    }

    event Proposed(uint256 indexed id, Kind kind, bytes32 indexed subject, bytes32 indexed by);
    event Voted(uint256 indexed id, bytes32 indexed member);
    event Passed(uint256 indexed id, uint64 executableFrom, uint64 executableUntil);
    event Executed(uint256 indexed id);
    event Cancelled(uint256 indexed id);

    error NotAMember(address caller);
    error NotActive(bytes32 member);
    error UnknownProposal(uint256 id);
    error VotingClosed(uint256 id);
    error AlreadyVoted(uint256 id, bytes32 member);
    error SubjectCannotVote(uint256 id, bytes32 member);
    error NotPassed(uint256 id);
    error TooEarly(uint256 id, uint64 executableFrom);
    error TooLate(uint256 id, uint64 executableUntil);
    error AlreadyFinalised(uint256 id);
    error NotProposer(uint256 id);
    error BadParameters();

    IMemberRegistry public immutable REGISTRY;

    /// @notice Blocks a proposal stays open for voting.
    uint64 public immutable VOTING_PERIOD;
    /// @notice Blocks between a reduction in standing passing and becoming
    ///         executable. Zero for proposals that only add.
    uint64 public immutable EXECUTION_DELAY;
    /// @notice Blocks after the delay during which a passed proposal may be
    ///         executed, after which it is dead and must be reproposed.
    uint64 public immutable EXECUTION_WINDOW;

    uint256 public proposalCount;
    mapping(uint256 id => Proposal) private _proposals;
    mapping(uint256 id => mapping(bytes32 member => bool)) public hasVoted;

    constructor(
        address registry,
        uint64 votingPeriod,
        uint64 executionDelay,
        uint64 executionWindow
    ) {
        if (registry == address(0)) revert BadParameters();
        if (votingPeriod == 0 || executionWindow == 0) revert BadParameters();
        REGISTRY = IMemberRegistry(registry);
        VOTING_PERIOD = votingPeriod;
        EXECUTION_DELAY = executionDelay;
        EXECUTION_WINDOW = executionWindow;
    }

    // --- proposing -----------------------------------------------------------

    function propose(Kind kind, bytes32 subject, bytes calldata payload)
        external
        returns (uint256 id)
    {
        bytes32 by = _callerMember();
        if (kind == Kind.None) revert BadParameters();

        id = ++proposalCount;
        Proposal storage p = _proposals[id];
        p.kind = kind;
        p.subject = subject;
        p.proposer = msg.sender;
        p.proposerMember = by;
        // forge-lint: disable-next-line(unsafe-typecast)
        p.votingEndsAt = uint64(block.number) + VOTING_PERIOD;
        p.payload = payload;

        emit Proposed(id, kind, subject, by);

        // Proposing is a vote. Requiring a separate transaction to vote for
        // your own proposal is friction with no safety value.
        _castVote(id, by);
    }

    function vote(uint256 id) external {
        _castVote(id, _callerMember());
    }

    function cancel(uint256 id) external {
        Proposal storage p = _proposals[id];
        if (p.kind == Kind.None) revert UnknownProposal(id);
        if (p.proposer != msg.sender) revert NotProposer(id);
        if (p.executed || p.cancelled) revert AlreadyFinalised(id);
        p.cancelled = true;
        emit Cancelled(id);
    }

    // --- execution -----------------------------------------------------------

    /// @notice Anyone may execute a passed proposal. Execution carries no
    ///         discretion, so restricting who may call it would only create a
    ///         party able to stall a decision the consortium already made.
    function execute(uint256 id) external {
        Proposal storage p = _proposals[id];
        if (p.kind == Kind.None) revert UnknownProposal(id);
        if (p.executed || p.cancelled) revert AlreadyFinalised(id);
        if (p.passedAt == 0) revert NotPassed(id);

        (uint64 from, uint64 until) = _window(p);
        if (block.number < from) revert TooEarly(id, from);
        if (block.number > until) revert TooLate(id, until);

        // Effects, then the event, then the external call. The registry is a
        // trusted immutable contract so reentrancy is not a live risk here,
        // but ordering it the other way makes the log sequence depend on the
        // callee, which off-chain consumers like the permissioning controller
        // read.
        p.executed = true;
        emit Executed(id);
        _apply(p);
    }

    function proposal(uint256 id) external view returns (Proposal memory) {
        return _proposals[id];
    }

    /// @notice Votes needed for a proposal to pass right now.
    /// @dev Computed live rather than frozen at proposal time: if the
    ///      consortium shrinks while a vote is open, the threshold should
    ///      reflect the consortium that exists when the decision lands.
    function votesRequired(bytes32 subject) public view returns (uint256) {
        uint256 eligible = REGISTRY.activeMemberCount();
        if (
            subject != bytes32(0)
                && REGISTRY.member(subject).status == IMemberRegistry.Status.Active
        ) {
            --eligible;
        }
        return eligible / 2 + 1;
    }

    function executionWindowOf(uint256 id) external view returns (uint64 from, uint64 until) {
        return _window(_proposals[id]);
    }

    // --- internals -----------------------------------------------------------

    function _callerMember() private view returns (bytes32 id) {
        id = REGISTRY.memberOfAccount(msg.sender);
        if (id == bytes32(0)) revert NotAMember(msg.sender);
        if (REGISTRY.member(id).status != IMemberRegistry.Status.Active) revert NotActive(id);
    }

    function _castVote(uint256 id, bytes32 member) private {
        Proposal storage p = _proposals[id];
        if (p.kind == Kind.None) revert UnknownProposal(id);
        if (p.executed || p.cancelled) revert AlreadyFinalised(id);
        if (block.number > p.votingEndsAt) revert VotingClosed(id);
        if (member == p.subject) revert SubjectCannotVote(id, member);
        if (hasVoted[id][member]) revert AlreadyVoted(id, member);

        hasVoted[id][member] = true;
        ++p.forVotes;
        emit Voted(id, member);

        if (p.passedAt == 0 && p.forVotes >= votesRequired(p.subject)) {
            // forge-lint: disable-next-line(unsafe-typecast)
            p.passedAt = uint64(block.number);
            (uint64 from, uint64 until) = _window(p);
            emit Passed(id, from, until);
        }
    }

    /// @dev Only proposals that reduce a member's standing wait. Everything
    ///      else is executable the moment it passes.
    function _reducesStanding(Proposal storage p) private view returns (bool) {
        if (p.kind == Kind.SetStatus) {
            IMemberRegistry.Status next = abi.decode(p.payload, (IMemberRegistry.Status));
            return next != IMemberRegistry.Status.Active;
        }
        if (p.kind == Kind.SetValidator) {
            return !abi.decode(p.payload, (bool));
        }
        return p.kind == Kind.RemoveAccount || p.kind == Kind.RemoveEnode;
    }

    function _window(Proposal storage p) private view returns (uint64 from, uint64 until) {
        if (p.passedAt == 0) return (0, 0);
        from = p.passedAt + (_reducesStanding(p) ? EXECUTION_DELAY : 0);
        until = from + EXECUTION_WINDOW;
    }

    function _apply(Proposal storage p) private {
        if (p.kind == Kind.AddMember) {
            (
                string memory name,
                address validatorAddress,
                bool isValidator,
                address[] memory accounts,
                string[] memory enodes
            ) = abi.decode(p.payload, (string, address, bool, address[], string[]));
            REGISTRY.addMember(p.subject, name, validatorAddress, isValidator, accounts, enodes);
        } else if (p.kind == Kind.SetStatus) {
            REGISTRY.setStatus(p.subject, abi.decode(p.payload, (IMemberRegistry.Status)));
        } else if (p.kind == Kind.SetValidator) {
            REGISTRY.setValidator(p.subject, abi.decode(p.payload, (bool)));
        } else if (p.kind == Kind.AddAccount) {
            REGISTRY.addAccount(p.subject, abi.decode(p.payload, (address)));
        } else if (p.kind == Kind.RemoveAccount) {
            REGISTRY.removeAccount(p.subject, abi.decode(p.payload, (address)));
        } else if (p.kind == Kind.AddEnode) {
            REGISTRY.addEnode(p.subject, abi.decode(p.payload, (string)));
        } else if (p.kind == Kind.RemoveEnode) {
            REGISTRY.removeEnode(p.subject, abi.decode(p.payload, (uint256)));
        } else {
            revert BadParameters();
        }
    }
}

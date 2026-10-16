// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.28;

import { IMemberRegistry } from "../interfaces/IMemberRegistry.sol";

/// @title MemberRegistry
/// @notice The authoritative record of who belongs to the consortium.
///
/// @dev Two governance paths run off this contract, and they differ because
///      of what the client supports rather than by preference:
///
///      Validator set changes are enforced on chain. QBFT reads the validator
///      set from a contract (`ValidatorSetView`, which is a view over this
///      registry), so a governance decision changes who produces blocks as a
///      direct consequence, with no operator in the loop.
///
///      Node and account allowlist changes are applied off chain by a
///      reconciling controller that watches this contract's events, because
///      Besu removed its onchain permissioning hook in the 25.6.0 line. The
///      registry is still the authority; only the enforcement point moved.
///
///      THE VALIDATOR FLOOR LIVES HERE, NOT IN THE GOVERNOR.
///
///      The governor enforces process: who may propose, what carries, how long
///      a removal waits. This contract enforces the one invariant that can
///      destroy the network. If a future governor is replaced with a buggy one
///      — and it is replaceable by design — the floor still holds, because the
///      thing that can brick the chain should be guarded at the last line and
///      not only the first.
///
///      Emptying or shrinking the validator set past a quorum halts the chain,
///      and it cannot be fixed on chain: the fix would need a transaction, and
///      there is nobody left to mine one. Recovery is the genesis `transitions`
///      escape hatch in ADR 0002, which means a coordinated restart across all
///      four organisations.
contract MemberRegistry is IMemberRegistry {
    /// @notice Below three active validators a single node failure stops the
    ///         chain, which is the property that made BFT worth choosing.
    /// @dev The contract can count members; it cannot know whether their nodes
    ///      are actually running. A count floor is the honest limit of what
    ///      this layer can guarantee, and the runbook owns the rest.
    uint256 public constant VALIDATOR_FLOOR = 3;

    address public governor;

    mapping(bytes32 id => Member) private _members;
    mapping(bytes32 id => address[]) private _accounts;
    mapping(bytes32 id => string[]) private _enodes;
    mapping(address account => bytes32 id) private _accountOwner;
    bytes32[] private _ids;

    modifier onlyGovernor() {
        if (msg.sender != governor) revert NotGovernor(msg.sender);
        _;
    }

    modifier known(bytes32 id) {
        if (_members[id].status == Status.None) revert UnknownMember(id);
        _;
    }

    /// @param initialGovernor Usually the deploying operator, which transfers
    ///        governance to the Governor contract once that is deployed and
    ///        the founding members are seeded. Seeding through the full voting
    ///        process is impossible: there is no electorate before the first
    ///        member exists.
    constructor(address initialGovernor) {
        if (initialGovernor == address(0)) revert ZeroAddress();
        governor = initialGovernor;
        emit GovernanceTransferred(address(0), initialGovernor);
    }

    // --- writes, governor only ---------------------------------------------

    function addMember(
        bytes32 id,
        string calldata name,
        address validatorAddress,
        bool isValidator,
        address[] calldata accounts,
        string[] calldata enodeUrls
    ) external onlyGovernor {
        if (id == bytes32(0)) revert UnknownMember(id);
        if (_members[id].status != Status.None) revert MemberExists(id);
        if (isValidator && validatorAddress == address(0)) revert ZeroAddress();

        _members[id] = Member({
            id: id,
            name: name,
            status: Status.Active,
            isValidator: isValidator,
            validatorAddress: validatorAddress,
            // forge-lint: disable-next-line(unsafe-typecast)
            joinedAt: uint64(block.timestamp),
            // forge-lint: disable-next-line(unsafe-typecast)
            statusChangedAt: uint64(block.timestamp)
        });
        _ids.push(id);

        for (uint256 i = 0; i < accounts.length; ++i) {
            _addAccount(id, accounts[i]);
        }
        for (uint256 i = 0; i < enodeUrls.length; ++i) {
            _enodes[id].push(enodeUrls[i]);
            emit EnodeAdded(id, enodeUrls[i]);
        }

        emit MemberAdded(id, name, validatorAddress, isValidator);
    }

    function setStatus(bytes32 id, Status status) external onlyGovernor known(id) {
        if (status == Status.None) revert UnknownMember(id);
        Status previous = _members[id].status;
        if (previous == status) return;

        _members[id].status = status;
        // forge-lint: disable-next-line(unsafe-typecast)
        _members[id].statusChangedAt = uint64(block.timestamp);
        _assertValidatorFloor();

        emit StatusChanged(id, previous, status);
    }

    function setValidator(bytes32 id, bool isValidator) external onlyGovernor known(id) {
        if (isValidator) {
            if (_members[id].status != Status.Active) revert MemberNotActive(id);
            if (_members[id].validatorAddress == address(0)) revert ZeroAddress();
        }
        _members[id].isValidator = isValidator;
        _assertValidatorFloor();
        emit ValidatorFlagChanged(id, isValidator);
    }

    function addAccount(bytes32 id, address account) external onlyGovernor known(id) {
        _addAccount(id, account);
    }

    function removeAccount(bytes32 id, address account) external onlyGovernor known(id) {
        if (_accountOwner[account] != id) revert UnknownAccount(account);
        address[] storage list = _accounts[id];
        for (uint256 i = 0; i < list.length; ++i) {
            if (list[i] == account) {
                list[i] = list[list.length - 1];
                list.pop();
                delete _accountOwner[account];
                emit AccountRemoved(id, account);
                return;
            }
        }
        revert UnknownAccount(account);
    }

    function addEnode(bytes32 id, string calldata enodeUrl) external onlyGovernor known(id) {
        _enodes[id].push(enodeUrl);
        emit EnodeAdded(id, enodeUrl);
    }

    function removeEnode(bytes32 id, uint256 index) external onlyGovernor known(id) {
        string[] storage list = _enodes[id];
        require(index < list.length, "index out of range");
        string memory removed = list[index];
        list[index] = list[list.length - 1];
        list.pop();
        emit EnodeRemoved(id, removed);
    }

    /// @notice Hands control to a new governor.
    /// @dev This is how the voting logic is replaced. The registry itself is
    ///      permanent, because QBFT reads validators through a view whose
    ///      registry pointer is immutable: if that pointer could change,
    ///      whoever could change it would control consensus.
    function transferGovernance(address newGovernor) external onlyGovernor {
        if (newGovernor == address(0)) revert ZeroAddress();
        address previous = governor;
        // forge-lint: disable-next-line(missing-events-access-control)
        governor = newGovernor;
        emit GovernanceTransferred(previous, newGovernor);
    }

    // --- views --------------------------------------------------------------

    function memberIds() external view returns (bytes32[] memory) {
        return _ids;
    }

    function member(bytes32 id) external view returns (Member memory) {
        return _members[id];
    }

    function accountsOf(bytes32 id) external view returns (address[] memory) {
        return _accounts[id];
    }

    function enodesOf(bytes32 id) external view returns (string[] memory) {
        return _enodes[id];
    }

    function memberOfAccount(address account) external view returns (bytes32) {
        return _accountOwner[account];
    }

    function isAccountAllowed(address account) external view returns (bool) {
        bytes32 id = _accountOwner[account];
        return id != bytes32(0) && _members[id].status == Status.Active;
    }

    /// @notice The validator set, as consensus sees it.
    /// @dev Called indirectly by every node on every block, so it must be
    ///      cheap and must never revert. Linear over members is correct at
    ///      four and would need rethinking at forty.
    function activeValidators() public view returns (address[] memory) {
        uint256 n = _ids.length;
        address[] memory buffer = new address[](n);
        uint256 count = 0;
        for (uint256 i = 0; i < n; ++i) {
            Member storage m = _members[_ids[i]];
            if (m.status == Status.Active && m.isValidator) {
                buffer[count++] = m.validatorAddress;
            }
        }
        address[] memory out = new address[](count);
        for (uint256 i = 0; i < count; ++i) {
            out[i] = buffer[i];
        }
        return out;
    }

    function activeMemberCount() external view returns (uint256) {
        uint256 count = 0;
        for (uint256 i = 0; i < _ids.length; ++i) {
            if (_members[_ids[i]].status == Status.Active) ++count;
        }
        return count;
    }

    // --- internals ----------------------------------------------------------

    function _addAccount(bytes32 id, address account) private {
        // Reverting here aborts the whole addMember call when seeding a
        // member with several accounts. That is intended: a member is added
        // with its full account set or not at all, never partially.
        // forge-lint: disable-next-line(require-revert-in-loop)
        if (account == address(0)) revert ZeroAddress();
        // forge-lint: disable-next-line(require-revert-in-loop)
        if (_accountOwner[account] != bytes32(0)) revert DuplicateAccount(account);
        _accountOwner[account] = id;
        _accounts[id].push(account);
        emit AccountAdded(id, account);
    }

    /// @dev Applied after any write that can shrink the validator set. The
    ///      floor does not apply while the consortium is still being founded,
    ///      because a network necessarily passes through one and two
    ///      validators on its way to four.
    function _assertValidatorFloor() private view {
        uint256 resulting = activeValidators().length;
        if (resulting >= VALIDATOR_FLOOR) return;
        if (_foundingPhase()) return;
        revert ValidatorFloorBreached(resulting, VALIDATOR_FLOOR);
    }

    /// @dev True until the validator set has reached the floor for the first
    ///      time. Tracked as a flag rather than inferred, so that a network
    ///      which has once been healthy can never silently re-enter the
    ///      permissive phase.
    bool private _founded;

    function _foundingPhase() private view returns (bool) {
        return !_founded;
    }

    /// @notice Closes the founding phase, after which the validator floor is
    ///         enforced unconditionally.
    /// @dev Separate from seeding so that it is a deliberate act with its own
    ///      transaction in the audit trail.
    function endFoundingPhase() external onlyGovernor {
        if (activeValidators().length < VALIDATOR_FLOOR) {
            revert ValidatorFloorBreached(activeValidators().length, VALIDATOR_FLOOR);
        }
        _founded = true;
    }

    function founded() external view returns (bool) {
        return _founded;
    }
}

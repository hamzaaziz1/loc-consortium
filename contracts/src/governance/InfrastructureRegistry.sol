// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.28;

import { IMemberRegistry } from "../interfaces/IMemberRegistry.sol";

/// @title InfrastructureRegistry
/// @notice The consortium's answer to "which contract is ours".
///
/// @dev An application asking whether an address is a genuine letter of credit
///      calls `factory.isCredit(address)`, which only means anything if every
///      party agrees which factory. Without an on-chain answer, the factory
///      address is configuration each party receives out of band, and nothing
///      stops a member deploying its own and issuing credits that look
///      identical.
///
///      DELIBERATELY SEPARATE FROM MemberRegistry. The obvious place for this
///      is a field on the member registry, and that is wrong. QBFT reads the
///      validator set through a view whose registry pointer is immutable and
///      whose address is fixed in the genesis, so changing MemberRegistry
///      means a new view and a coordinated restart of every node. It can never
///      practically be replaced, which means it must stay minimal: anything
///      added to it for convenience is permanent.
///
///      GOVERNANCE IS NOT STORED HERE EITHER. The authority is whoever governs
///      the member registry, read live. So replacing the Governor carries over
///      automatically, with no second transfer to perform and nothing that can
///      drift out of step.
contract InfrastructureRegistry {
    IMemberRegistry public immutable REGISTRY;

    mapping(bytes32 key => address value) private _entries;
    bytes32[] private _keys;
    mapping(bytes32 key => bool known) private _known;

    event EntrySet(bytes32 indexed key, address indexed previous, address indexed current);

    error NotGovernor(address caller);
    error UnknownEntry(bytes32 key);

    constructor(address registry) {
        require(registry != address(0), "registry is the zero address");
        REGISTRY = IMemberRegistry(registry);
    }

    /// @dev Read live from the member registry rather than stored, so a
    ///      governance transfer needs no action here.
    modifier onlyGovernor() {
        if (msg.sender != REGISTRY.governor()) revert NotGovernor(msg.sender);
        _;
    }

    /// @notice Points a well-known key at a contract.
    /// @dev Setting to the zero address retires an entry rather than deleting
    ///      the key, so the history of what the consortium once pointed at
    ///      stays readable in the event log.
    function set(bytes32 key, address value) external onlyGovernor {
        address previous = _entries[key];
        _entries[key] = value;
        if (!_known[key]) {
            _known[key] = true;
            _keys.push(key);
        }
        emit EntrySet(key, previous, value);
    }

    function get(bytes32 key) external view returns (address) {
        address value = _entries[key];
        if (value == address(0)) revert UnknownEntry(key);
        return value;
    }

    /// @dev Non-reverting variant, for callers that want to handle absence.
    function tryGet(bytes32 key) external view returns (address) {
        return _entries[key];
    }

    function keys() external view returns (bytes32[] memory) {
        return _keys;
    }
}

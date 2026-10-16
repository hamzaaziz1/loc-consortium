// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.28;

/// @title Consortium membership registry interface
/// @notice One entry per member organisation. A member is a single record
///         carrying its accounts, its nodes, its status and whether it
///         validates, rather than separate registries per concern.
///
///         The layers of this system have to agree on what a member is. ADR
///         0003 made removal a single revocation at the PKI layer, because an
///         organisation intermediate dying takes everything beneath it with
///         it. Splitting membership across several registries here would make
///         removal a sequence of writes that can partially succeed, and a
///         half-removed member is the worst state this network can reach.
interface IMemberRegistry {
    /// @notice Lifecycle of a member.
    /// @dev Suspended members keep their identity and history but lose their
    ///      allowlist entries and cannot validate. Removed is terminal; a
    ///      returning organisation is added again as a new entry so the audit
    ///      trail of the original is never overwritten.
    enum Status {
        None,
        Active,
        Suspended,
        Removed
    }

    struct Member {
        bytes32 id;
        string name;
        Status status;
        bool isValidator;
        /// @dev The QBFT block-signing address, derived from the node key.
        ///      Deliberately not one of the member's transacting accounts:
        ///      signing blocks and submitting transactions are different
        ///      capabilities held by different keys.
        address validatorAddress;
        uint64 joinedAt;
        uint64 statusChangedAt;
    }

    event MemberAdded(bytes32 indexed id, string name, address validatorAddress, bool isValidator);
    event StatusChanged(bytes32 indexed id, Status previous, Status current);
    event ValidatorFlagChanged(bytes32 indexed id, bool isValidator);
    event AccountAdded(bytes32 indexed id, address indexed account);
    event AccountRemoved(bytes32 indexed id, address indexed account);
    event EnodeAdded(bytes32 indexed id, string enode);
    event EnodeRemoved(bytes32 indexed id, string enode);
    event GovernanceTransferred(address indexed previous, address indexed current);

    error NotGovernor(address caller);
    error UnknownMember(bytes32 id);
    error MemberExists(bytes32 id);
    error MemberNotActive(bytes32 id);
    error ValidatorFloorBreached(uint256 resulting, uint256 floor);
    error ZeroAddress();
    error DuplicateAccount(address account);
    error UnknownAccount(address account);

    function addMember(
        bytes32 id,
        string calldata name,
        address validatorAddress,
        bool isValidator,
        address[] calldata accounts,
        string[] calldata enodeUrls
    ) external;

    function setStatus(bytes32 id, Status status) external;
    function setValidator(bytes32 id, bool isValidator) external;
    function addAccount(bytes32 id, address account) external;
    function removeAccount(bytes32 id, address account) external;
    function addEnode(bytes32 id, string calldata enodeUrl) external;
    function removeEnode(bytes32 id, uint256 index) external;
    function transferGovernance(address newGovernor) external;

    function governor() external view returns (address);
    function memberIds() external view returns (bytes32[] memory);
    function member(bytes32 id) external view returns (Member memory);
    function accountsOf(bytes32 id) external view returns (address[] memory);
    function enodesOf(bytes32 id) external view returns (string[] memory);
    function memberOfAccount(address account) external view returns (bytes32);
    function isAccountAllowed(address account) external view returns (bool);
    function activeValidators() external view returns (address[] memory);
    function activeMemberCount() external view returns (uint256);
    function VALIDATOR_FLOOR() external view returns (uint256);
}

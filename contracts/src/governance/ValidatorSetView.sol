// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.28;

import { IMemberRegistry } from "../interfaces/IMemberRegistry.sol";

/// @title ValidatorSetView
/// @notice The contract QBFT reads the validator set from.
///
/// @dev Besu's QBFT supports two validator selection modes: `blockheader`,
///      where the set is voted into the block header via RPC, and `contract`,
///      where the set is read from a contract implementing exactly this
///      interface. That hook survived the 25.6.0 removals that took out
///      onchain permissioning, which is why validator governance in this
///      network is genuinely on chain while allowlist governance is not.
///
///      This contract has no state, no owner, and one function. That is the
///      whole point. The surface consensus depends on should be auditable in
///      twenty lines and incapable of reverting for any reason unrelated to
///      validator selection.
///
///      The registry pointer is immutable, and must be. If it could be
///      changed, whoever could change it would control consensus. Governance
///      remains replaceable, but by transferring governance on the registry,
///      not by repointing this view.
///
///      Consequence worth stating: the address of this contract is fixed in
///      the genesis `transitions` block, so changing it means a coordinated
///      restart of every node in the consortium. It is effectively permanent
///      from the moment the network starts.
contract ValidatorSetView {
    IMemberRegistry public immutable REGISTRY;

    constructor(address registry) {
        require(registry != address(0), "registry is the zero address");
        REGISTRY = IMemberRegistry(registry);
    }

    /// @notice The current validator set.
    /// @dev The signature Besu expects. Called by every node on every block,
    ///      so it must stay cheap and must never revert: a revert here stops
    ///      block production across the whole network.
    function getValidators() external view returns (address[] memory) {
        return REGISTRY.activeValidators();
    }
}

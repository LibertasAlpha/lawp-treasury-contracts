// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {LAWPStructs} from "../libraries/LAWPStructs.sol";

/// @title ILAWPMultiSigController
/// @author Obinna Franklin Duru (BinnaDev)
/// @notice Interface for the off-chain verification and execution engine.
interface ILAWPMultiSigController {
    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Emitted when the required signature threshold is updated.
    event ThresholdUpdated(uint256 oldThreshold, uint256 newThreshold);

    /// @notice Emitted when a multi-sig proposal is successfully executed.
    event ProposalExecuted(
        bytes32 indexed digest,
        uint256 indexed proposalId,
        uint256 indexed poolId,
        uint256 totalAmount,
        LAWPStructs.FlowType flowType
    );

    /*//////////////////////////////////////////////////////////////
                                 LOGIC
    //////////////////////////////////////////////////////////////*/

    /// @notice            Executes a revenue routing proposal after validating
    ///                    a threshold of off-chain signatures.
    /// @dev               Implements Safe-style packed ECDSA signatures.
    ///                    Reverts if signatures are duplicated or unordered.
    ///                    Requires M-of-N threshold. Enforces nonce-based replay protection.
    ///                    If successful, calls `engine.routeOperationalAllocation()`.
    /// @param proposalId  Unique identifier/nonce for the proposal to track off-chain references.
    /// @param poolId      The project deployment pool ID receiving the revenue.
    /// @param totalAmount The total CNGN generated off-chain to be routed.
    /// @param flowType    The strict classification of the revenue
    ///                    (RoC, GRANT_INITIAL, GRANT_CONTINUOUS).
    /// @param deadline    Unix timestamp after which the payload is permanently invalid.
    /// @param signatures  Concatenated, packed byte array of ECDSA signatures,
    ///                    sorted strictly by signer address.
    function executeProposal(
        uint256 proposalId,
        uint256 poolId,
        uint256 totalAmount,
        LAWPStructs.FlowType flowType,
        uint256 deadline,
        bytes calldata signatures
    ) external;

    /// @notice Updates the required number of signatures for execution.
    ///         Callable only by the Governance Role.
    function updateThreshold(uint256 _newThreshold) external;
}

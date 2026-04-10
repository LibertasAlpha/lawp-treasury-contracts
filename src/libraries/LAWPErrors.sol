// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title LAWPErrors
 * @dev Centralized custom errors for the LAWP ecosystem.
 * Utilizing custom errors over require strings saves deployment and runtime gas
 * while providing standard, machine-readable failure modes.
 */
library LAWPErrors {
    /* -------------------------------------------------------------------------- */
    /* Compliance Engine Errors                           */
    /* -------------------------------------------------------------------------- */
    error Error_ExceedsPrincipal();
    error Error_InvalidFlowType();
    error Error_InvalidSplitAllocation();
    error Error_RoCTokenMismatch();

    /* -------------------------------------------------------------------------- */
    /* Access Control & Auth Errors                       */
    /* -------------------------------------------------------------------------- */
    error Error_Unauthorized();
    error Error_InvalidSigner();
    error Error_RoleNotRegistered(bytes32 role, address account);

    /* -------------------------------------------------------------------------- */
    /* Multi-Signature Errors                             */
    /* -------------------------------------------------------------------------- */
    error Error_ProposalExpired();
    error Error_ProposalAlreadyExecuted();
    error Error_InsufficientSignatures();
    error Error_InvalidSignatureLength();

    /* -------------------------------------------------------------------------- */
    /* Generic Validation Errors                          */
    /* -------------------------------------------------------------------------- */
    error Error_ZeroAddress();
    error Error_ZeroAmount();
}
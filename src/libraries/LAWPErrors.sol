// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title LAWP Custom Errors
/// @author Obinna Franklin Duru (BinnaDev)
/// @notice Centralized error declarations for the entire protocol.
/// @dev Prefixing ensures precise debugging and clear identification of the reverting contract.
interface LAWPErrors {
    /*//////////////////////////////////////////////////////////////
                        COMPLIANCE ENGINE ERRORS
    //////////////////////////////////////////////////////////////*/
    error LAWPComplianceEngine_InvalidRiskFee();
    error LAWPComplianceEngine_SystemPaused();
    error LAWPComplianceEngine_UnauthorizedCaller();
    error LAWPComplianceEngine_InvalidFlowType();
    error LAWPComplianceEngine_ExceedsPrincipalCap();

    /*//////////////////////////////////////////////////////////////
                            TREASURY ERRORS
    //////////////////////////////////////////////////////////////*/
    error LAWPTreasury_YieldAlreadyClaimed();
    error LAWPTreasury_UnauthorizedCommand();
    error LAWPTreasury_InsufficientVaultFunds();

    /*//////////////////////////////////////////////////////////////
                          IMPACT TOKEN ERRORS
    //////////////////////////////////////////////////////////////*/
    error LAWPImpactToken_TransferIntercepted();
    error LAWPImpactToken_InvalidTokenId();
    error LAWPImpactToken_ZeroAddressMint();

    /*//////////////////////////////////////////////////////////////
                           MULTI-SIG ERRORS
    //////////////////////////////////////////////////////////////*/
    error LAWPMultiSigController_InvalidSignatures();
    error LAWPMultiSigController_BelowThreshold();
    error LAWPMultiSigController_ProposalAlreadyExecuted();
    error LAWPMultiSigController_InvalidPayload();
}

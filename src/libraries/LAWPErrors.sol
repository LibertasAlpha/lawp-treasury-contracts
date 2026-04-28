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
    error LAWPComplianceEngine_ArrayMismatch();
    error LAWPComplianceEngine_InvalidBPS();
    error LAWPComplianceEngine_ZeroAddress();
    error LAWPComplianceEngine_InvalidAmount();
    error LAWPComplianceEngine_PoolAlreadyExists();
    error LAWPComplianceEngine_InvalidActor();
    error LAWPComplianceEngine_ArrayTooLarge();
    error LAWPComplianceEngine_NothingToClaim();

    /*//////////////////////////////////////////////////////////////
                            TREASURY ERRORS
    //////////////////////////////////////////////////////////////*/
    error LAWPTreasury_YieldAlreadyClaimed();
    error LAWPTreasury_UnauthorizedCommand();
    error LAWPTreasury_InsufficientVaultFunds();
    error LAWPTreasury_ZeroAddress();
    error LAWPTreasury_InvalidAmount();
    error LAWPTreasury_RiskPoolNotSet();

    /*//////////////////////////////////////////////////////////////
                          IMPACT TOKEN ERRORS
    //////////////////////////////////////////////////////////////*/
    error LAWPImpactToken_TransferIntercepted();
    error LAWPImpactToken_InvalidTokenId();
    error LAWPImpactToken_ZeroAddressMint();
    error LAWPImpactToken_InvalidRocAmount();
    error LAWPImpactToken_ZeroAddress();
    error LAWPImpactToken_InvalidBaseURI();
    error LAWPImpactToken_InvalidPrincipal();
    error LAWPImpactToken_InvalidBPS();
    error LAWPImpactToken_InvalidPoolId();

    /*//////////////////////////////////////////////////////////////
                           MULTI-SIG ERRORS
    //////////////////////////////////////////////////////////////*/
    error LAWPMultiSigController_InvalidSignatures();
    error LAWPMultiSigController_BelowThreshold();
    error LAWPMultiSigController_ProposalAlreadyExecuted();
    error LAWPMultiSigController_InvalidPayload();
}

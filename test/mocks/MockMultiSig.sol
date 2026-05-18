// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { ILAWPComplianceEngine } from "../../src/interfaces/ILAWPComplianceEngine.sol";
import { LAWPStructs } from "../../src/libraries/LAWPStructs.sol";

/// @title MockMultiSig
/// @notice Bypasses EIP-712 signature verification for invariant and integration testing,
///         allowing the fuzzer and integration tests to hammer the Compliance Engine's
///         mathematical boundaries directly without signature overhead.
contract MockMultiSig {
    ILAWPComplianceEngine public engine;

    constructor(address _engine) {
        engine = ILAWPComplianceEngine(_engine);
    }

    /// @notice Directly calls routeOperationalAllocation on the engine.
    ///         The engine's onlyMultiSig modifier will allow this since the
    ///         compliance engine is configured with this contract as multiSigController.
    function execute(uint256 _poolId, uint256 _amount, LAWPStructs.FlowType _flow) external {
        engine.routeOperationalAllocation(_poolId, _amount, _flow);
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { ILAWPComplianceEngine } from "../../src/interfaces/ILAWPComplianceEngine.sol";
import { LAWPStructs } from "../../src/libraries/LAWPStructs.sol";

/// @title MockMultiSig
/// @notice Bypasses EIP-712 signature verification for invariant and integration testing,
///         allowing the fuzzer to hammer the Compliance Engine's mathematical boundaries directly.
contract MockMultiSig {
    ILAWPComplianceEngine public engine;

    constructor(address _engine) {
        engine = ILAWPComplianceEngine(_engine);
    }

    function execute(uint256 _poolId, uint256 _amount, LAWPStructs.FlowType _flow) external {
        engine.validateAndRoute(_poolId, _amount, _flow);
    }
}

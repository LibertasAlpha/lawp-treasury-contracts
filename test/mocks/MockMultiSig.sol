// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { ILAWPComplianceEngine } from "../../src/interfaces/ILAWPComplianceEngine.sol";
import { LAWPStructs } from "../../src/libraries/LAWPStructs.sol";

/// @title MockMultiSig
/// @notice Bypasses EIP-712 signature verification for invariant and integration testing.
///
/// @dev ARCHITECTURAL INVARIANT: This contract holds ZERO cNGN at all times.
///
///      The caller of execute() is the relayer. The relayer's address is forwarded
///      to the engine as `_fundProvider`. The engine then calls:
///          cNGNToken.safeTransferFrom(_fundProvider, vault, amount)
///      pulling cNGN DIRECTLY from the relayer - not from this contract.
///
///      Prerequisite: The relayer must approve the ENGINE (not this contract) before
///      calling execute().
contract MockMultiSig {
    ILAWPComplianceEngine public engine;

    constructor(address _engine) {
        engine = ILAWPComplianceEngine(_engine);
    }

    /// @notice Routes revenue to the Compliance Engine, forwarding msg.sender as fund provider.
    /// @dev The caller must have approved the engine to spend cNGN on their behalf.
    ///      This contract never touches tokens - it is a pure verification bypass.
    function execute(uint256 _poolId, uint256 _amount, LAWPStructs.FlowType _flow) external {
        // Pass msg.sender (the relayer) as the fund provider.
        // Engine pulls cNGN directly from the relayer's wallet.
        engine.routeOperationalAllocation(_poolId, _amount, msg.sender, _flow);
    }
}

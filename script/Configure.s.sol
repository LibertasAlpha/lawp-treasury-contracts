// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Script, console2 } from "forge-std/Script.sol";
import { TimelockController } from "@openzeppelin/contracts/governance/TimelockController.sol";
import { LAWPComplianceEngine } from "../src/core/LAWPComplianceEngine.sol";
import { LAWPTreasury } from "../src/core/LAWPTreasury.sol";
import { LAWPImpactToken } from "../src/core/LAWPImpactToken.sol";
import { LAWPActorRegistry } from "../src/core/LAWPActorRegistry.sol";
import { LAWPMultiSigController } from "../src/core/LAWPMultiSigController.sol";

/// @title LAWP Configuration Script
/// @author Obinna Franklin Duru (BinnaDev)
/// @notice Wires protocol connections, executes the atomic Ownable2Step transition, and locks out the deployer.
contract Configure is Script {
    /// @notice The permanent production delay for the Timelock.
    uint256 public constant FINAL_TIMELOCK_DELAY = 2 days;

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        TimelockController timelock = TimelockController(payable(vm.envAddress("TIMELOCK_ADDRESS")));
        LAWPComplianceEngine engine = LAWPComplianceEngine(vm.envAddress("ENGINE_ADDRESS"));
        LAWPTreasury treasury = LAWPTreasury(vm.envAddress("TREASURY_ADDRESS"));
        LAWPImpactToken impactToken = LAWPImpactToken(vm.envAddress("TOKEN_ADDRESS"));
        LAWPActorRegistry registry = LAWPActorRegistry(vm.envAddress("REGISTRY_ADDRESS"));
        LAWPMultiSigController multiSig = LAWPMultiSigController(vm.envAddress("MULTISIG_ADDRESS"));
        address adminSafe = vm.envAddress("ADMIN_SAFE_ADDRESS");

        vm.startBroadcast(deployerPrivateKey);

        // 1. Configure Actor Registry
        registry.setLA2Wallet(vm.envAddress("LA2_WALLET"));
        registry.setMVI1Wallet(vm.envAddress("MVI1_WALLET"));
        registry.setRiskPoolWallet(vm.envAddress("RISK_POOL_WALLET"));
        registry.setDevWallet(vm.envAddress("DEV_WALLET"));

        // 2. Wire the Ecosystem Trust Boundaries
        engine.setMultiSigController(address(multiSig));
        treasury.setComplianceEngine(address(engine));
        treasury.setRiskPoolWallet(vm.envAddress("RISK_POOL_WALLET"));
        impactToken.setComplianceEngine(address(engine));

        // 3. Initiate Ownable2Step Transfer
        registry.transferOwnership(address(timelock));
        treasury.transferOwnership(address(timelock));
        impactToken.transferOwnership(address(timelock));
        engine.transferOwnership(address(timelock));
        multiSig.transferOwnership(address(timelock));

        // ====================================================================
        // PRE-FLIGHT CHECKS: Verify all ownerships are pending correctly
        // ====================================================================
        require(registry.pendingOwner() == address(timelock), "PreFlight: Registry owner mismatch");
        require(treasury.pendingOwner() == address(timelock), "PreFlight: Treasury owner mismatch");
        require(impactToken.pendingOwner() == address(timelock), "PreFlight: Token owner mismatch");
        require(engine.pendingOwner() == address(timelock), "PreFlight: Engine owner mismatch");
        require(multiSig.pendingOwner() == address(timelock), "PreFlight: MultiSig owner mismatch");

        // 4. ATOMIC TIMELOCK SETUP (0-Delay Batch Execution)
        address[] memory targets = new address[](6);
        targets[0] = address(registry);
        targets[1] = address(treasury);
        targets[2] = address(impactToken);
        targets[3] = address(engine);
        targets[4] = address(multiSig);
        targets[5] = address(timelock); // The Timelock updates itself

        uint256[] memory values = new uint256[](6); // All 0 ETH

        bytes[] memory payloads = new bytes[](6);
        bytes memory acceptOwnershipPayload = abi.encodeWithSignature("acceptOwnership()");
        payloads[0] = acceptOwnershipPayload;
        payloads[1] = acceptOwnershipPayload;
        payloads[2] = acceptOwnershipPayload;
        payloads[3] = acceptOwnershipPayload;
        payloads[4] = acceptOwnershipPayload;
        payloads[5] = abi.encodeWithSignature("updateDelay(uint256)", FINAL_TIMELOCK_DELAY);

        bytes32 salt = keccak256("LAWP_PRODUCTION_SETUP");

        // Schedule and Execute instantly because initial delay is 0
        timelock.scheduleBatch(targets, values, payloads, bytes32(0), salt, 0);
        timelock.executeBatch(targets, values, payloads, bytes32(0), salt);

        // 5. Grant Permanent Roles
        bytes32 DEFAULT_ADMIN_ROLE = 0x00;
        bytes32 PROPOSER_ROLE = timelock.PROPOSER_ROLE();
        bytes32 CANCELLER_ROLE = timelock.CANCELLER_ROLE();
        bytes32 EXECUTOR_ROLE = timelock.EXECUTOR_ROLE();

        timelock.grantRole(PROPOSER_ROLE, adminSafe);
        timelock.grantRole(CANCELLER_ROLE, adminSafe);
        timelock.grantRole(EXECUTOR_ROLE, address(0)); // Open Execution

        // 6. DISARM THE DEPLOYMENT TRAP (Strict Revocation)
        timelock.renounceRole(PROPOSER_ROLE, deployer);
        timelock.renounceRole(CANCELLER_ROLE, deployer);
        timelock.renounceRole(EXECUTOR_ROLE, deployer);
        timelock.renounceRole(DEFAULT_ADMIN_ROLE, deployer);

        vm.stopBroadcast();

        // ====================================================================
        // POST-FLIGHT ASSERTIONS: Mathematically prove the handover succeeded
        // ====================================================================
        require(registry.owner() == address(timelock), "PostFlight: Registry handover failed");
        require(treasury.owner() == address(timelock), "PostFlight: Treasury handover failed");
        require(impactToken.owner() == address(timelock), "PostFlight: Token handover failed");
        require(engine.owner() == address(timelock), "PostFlight: Engine handover failed");
        require(multiSig.owner() == address(timelock), "PostFlight: MultiSig handover failed");

        require(timelock.getMinDelay() == FINAL_TIMELOCK_DELAY, "PostFlight: Delay update failed");

        require(
            !timelock.hasRole(DEFAULT_ADMIN_ROLE, deployer),
            "PostFlight: Deployer retains God Mode!"
        );
        require(
            !timelock.hasRole(CANCELLER_ROLE, deployer),
            "PostFlight: Deployer retains Canceller Mode!"
        );

        console2.log("Configuration Complete. Ownable2Step Accepted by Timelock.");
        console2.log("Timelock Delay safely raised to 48 Hours.");
        console2.log("Deployer has been completely locked out and verified.");
    }
}

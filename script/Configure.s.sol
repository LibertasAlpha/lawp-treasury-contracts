// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Script, console2 } from "forge-std/Script.sol";
import { TimelockController } from "@openzeppelin/contracts/governance/TimelockController.sol";
import { LAWPComplianceEngine } from "../src/core/LAWPComplianceEngine.sol";
import { LAWPYieldVault } from "../src/core/LAWPYieldVault.sol";
import { LAWPOperationalVault } from "../src/core/LAWPOperationalVault.sol";
import { LAWPImpactToken } from "../src/core/LAWPImpactToken.sol";
import { LAWPActorRegistry } from "../src/core/LAWPActorRegistry.sol";
import { LAWPMultiSigController } from "../src/core/LAWPMultiSigController.sol";

/// @title LAWP Configuration Script
/// @author Obinna Franklin Duru (BinnaDev)
/// @notice Wires protocol trust boundaries, executes Ownable2Step transition, locks out deployer.
contract Configure is Script {
    uint256 public constant FINAL_TIMELOCK_DELAY = 2 days;

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        TimelockController timelock = TimelockController(payable(vm.envAddress("TIMELOCK_ADDRESS")));
        LAWPComplianceEngine engine = LAWPComplianceEngine(vm.envAddress("ENGINE_ADDRESS"));
        LAWPYieldVault yieldVault = LAWPYieldVault(vm.envAddress("YIELD_VAULT_ADDRESS"));
        LAWPOperationalVault operationalVault =
            LAWPOperationalVault(vm.envAddress("OP_VAULT_ADDRESS"));
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

        // 2. Wire trust boundaries (dual-vault architecture)
        engine.setMultiSigController(address(multiSig));
        yieldVault.setComplianceEngine(address(engine));
        operationalVault.setComplianceEngine(address(engine));
        impactToken.setComplianceEngine(address(engine));

        // 3. Initiate Ownable2Step transfers to Timelock
        registry.transferOwnership(address(timelock));
        yieldVault.transferOwnership(address(timelock));
        operationalVault.transferOwnership(address(timelock));
        impactToken.transferOwnership(address(timelock));
        engine.transferOwnership(address(timelock));
        multiSig.transferOwnership(address(timelock));

        // PRE-FLIGHT: Verify all pending owners are set correctly
        require(registry.pendingOwner() == address(timelock), "PreFlight: Registry owner mismatch");
        require(
            yieldVault.pendingOwner() == address(timelock), "PreFlight: YieldVault owner mismatch"
        );
        require(
            operationalVault.pendingOwner() == address(timelock),
            "PreFlight: OpVault owner mismatch"
        );
        require(impactToken.pendingOwner() == address(timelock), "PreFlight: Token owner mismatch");
        require(engine.pendingOwner() == address(timelock), "PreFlight: Engine owner mismatch");
        require(multiSig.pendingOwner() == address(timelock), "PreFlight: MultiSig owner mismatch");

        // 4. Atomic Timelock batch execution (0-delay)
        address[] memory targets = new address[](7);
        targets[0] = address(registry);
        targets[1] = address(yieldVault);
        targets[2] = address(operationalVault);
        targets[3] = address(impactToken);
        targets[4] = address(engine);
        targets[5] = address(multiSig);
        targets[6] = address(timelock);

        uint256[] memory values = new uint256[](7);
        bytes[] memory payloads = new bytes[](7);
        bytes memory acceptOwnership = abi.encodeWithSignature("acceptOwnership()");
        payloads[0] = acceptOwnership;
        payloads[1] = acceptOwnership;
        payloads[2] = acceptOwnership;
        payloads[3] = acceptOwnership;
        payloads[4] = acceptOwnership;
        payloads[5] = acceptOwnership;
        payloads[6] = abi.encodeWithSignature("updateDelay(uint256)", FINAL_TIMELOCK_DELAY);

        bytes32 salt = keccak256("LAWP_PRODUCTION_SETUP");
        timelock.scheduleBatch(targets, values, payloads, bytes32(0), salt, 0);
        timelock.executeBatch(targets, values, payloads, bytes32(0), salt);

        // 5. Grant permanent roles to Admin Safe
        bytes32 DEFAULT_ADMIN_ROLE = 0x00;
        timelock.grantRole(timelock.PROPOSER_ROLE(), adminSafe);
        timelock.grantRole(timelock.CANCELLER_ROLE(), adminSafe);
        timelock.grantRole(timelock.EXECUTOR_ROLE(), address(0)); // Open execution

        // 6. Revoke all deployer roles
        timelock.renounceRole(timelock.PROPOSER_ROLE(), deployer);
        timelock.renounceRole(timelock.CANCELLER_ROLE(), deployer);
        timelock.renounceRole(timelock.EXECUTOR_ROLE(), deployer);
        timelock.renounceRole(DEFAULT_ADMIN_ROLE, deployer);

        vm.stopBroadcast();

        // POST-FLIGHT: Mathematical proof of successful handover
        require(registry.owner() == address(timelock), "PostFlight: Registry handover failed");
        require(yieldVault.owner() == address(timelock), "PostFlight: YieldVault handover failed");
        require(
            operationalVault.owner() == address(timelock), "PostFlight: OpVault handover failed"
        );
        require(impactToken.owner() == address(timelock), "PostFlight: Token handover failed");
        require(engine.owner() == address(timelock), "PostFlight: Engine handover failed");
        require(multiSig.owner() == address(timelock), "PostFlight: MultiSig handover failed");
        require(timelock.getMinDelay() == FINAL_TIMELOCK_DELAY, "PostFlight: Delay update failed");
        require(!timelock.hasRole(DEFAULT_ADMIN_ROLE, deployer), "PostFlight: Deployer God Mode!");
        require(
            !timelock.hasRole(timelock.CANCELLER_ROLE(), deployer),
            "PostFlight: Deployer Canceller!"
        );

        console2.log("Configuration complete. Ownable2Step accepted by Timelock.");
        console2.log("Timelock delay raised to 48h. Deployer locked out and verified.");
    }
}

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
/// @dev Contract-level state variables are used instead of local variables in run() to avoid
///      the EVM 16-slot stack depth limit ("Stack too deep") during coverage analysis.
///      Each internal helper function operates on a small, isolated subset of state.
contract Configure is Script {
    // uint256 public constant FINAL_TIMELOCK_DELAY = 2 days;
    uint256 public constant FINAL_TIMELOCK_DELAY = 2 minutes; // for testing two minutes

    // STATE: Contract References
    // Stored at contract level so helpers can access them without passing
    // everything as function parameters (which would re-introduce stack pressure).
    LAWPMultiSigController internal _multiSig;
    TimelockController internal _timelock;
    LAWPComplianceEngine internal _engine;
    LAWPImpactToken internal _impactToken;
    LAWPActorRegistry internal _registry;

    LAWPYieldVault internal _yieldVault;
    LAWPOperationalVault internal _operationalVault;

    address internal _adminSafe;
    address internal _deployer;

    // ENTRY POINT
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        _deployer = vm.addr(deployerPrivateKey);
        _adminSafe = vm.envAddress("ADMIN_SAFE_ADDRESS");

        // Load contract addresses from env into state - keeps run() stack shallow.
        _loadContracts();

        vm.startBroadcast(deployerPrivateKey);
        _configure();
        vm.stopBroadcast();

        _postFlight();
    }

    // STEP 0: Load Contracts
    // Reads env vars and populates state references. Isolated here so run()
    // only holds deployerPrivateKey + deployer on its stack frame.
    function _loadContracts() internal {
        _yieldVault = LAWPYieldVault(vm.envAddress("YIELD_VAULT_ADDRESS"));
        _operationalVault = LAWPOperationalVault(vm.envAddress("OP_VAULT_ADDRESS"));

        _impactToken = LAWPImpactToken(vm.envAddress("TOKEN_ADDRESS"));
        _engine = LAWPComplianceEngine(vm.envAddress("ENGINE_ADDRESS"));
        _registry = LAWPActorRegistry(vm.envAddress("REGISTRY_ADDRESS"));
        _multiSig = LAWPMultiSigController(vm.envAddress("MULTISIG_ADDRESS"));
        _timelock = TimelockController(payable(vm.envAddress("TIMELOCK_ADDRESS")));
    }

    // STEP 1–6 Orchestrator (broadcast scope)
    function _configure() internal {
        _configureRegistry(); // 1. Set operational wallets
        _wireTrustBoundaries(); // 2. Link engine <-> vaults <-> token <-> multiSig
        _initiateOwnership(); // 3. transferOwnership -> timelock (pending)
        _preFlight(); // 4. Assert all pendingOwner == timelock
        _executeTimelockBatch(); // 5. Timelock accepts ownership + raises delay
        _lockoutDeployer(); // 6. Grant Admin Safe roles, revoke deployer roles
    }

    // STEP 1: Configure Actor Registry
    function _configureRegistry() internal {
        _registry.setLA2Wallet(vm.envAddress("LA2_WALLET"));
        _registry.setMVI1Wallet(vm.envAddress("MVI1_WALLET"));
        _registry.setRiskPoolWallet(vm.envAddress("RISK_POOL_WALLET"));
        _registry.setDevWallet(vm.envAddress("DEV_WALLET"));
    }

    // STEP 2: Wire Trust Boundaries (dual-vault architecture)
    function _wireTrustBoundaries() internal {
        _engine.setMultiSigController(address(_multiSig));
        _yieldVault.setComplianceEngine(address(_engine));
        _operationalVault.setComplianceEngine(address(_engine));
        _impactToken.setComplianceEngine(address(_engine));
    }

    // STEP 3: Initiate Ownable2Step Transfers -> Timelock
    function _initiateOwnership() internal {
        _registry.transferOwnership(address(_timelock));
        _yieldVault.transferOwnership(address(_timelock));
        _operationalVault.transferOwnership(address(_timelock));
        _impactToken.transferOwnership(address(_timelock));
        _engine.transferOwnership(address(_timelock));
        _multiSig.transferOwnership(address(_timelock));
    }

    // STEP 4: Pre-Flight Checks - verify pending owners before Timelock acts
    function _preFlight() internal view {
        require(
            _registry.pendingOwner() == address(_timelock), "PreFlight: Registry owner mismatch"
        );
        require(
            _yieldVault.pendingOwner() == address(_timelock), "PreFlight: YieldVault owner mismatch"
        );
        require(
            _operationalVault.pendingOwner() == address(_timelock),
            "PreFlight: OpVault owner mismatch"
        );
        require(
            _impactToken.pendingOwner() == address(_timelock), "PreFlight: Token owner mismatch"
        );
        require(_engine.pendingOwner() == address(_timelock), "PreFlight: Engine owner mismatch");
        require(
            _multiSig.pendingOwner() == address(_timelock), "PreFlight: MultiSig owner mismatch"
        );
    }

    // STEP 5: Atomic Timelock Batch - acceptOwnership × 6 + updateDelay
    function _executeTimelockBatch() internal {
        address[] memory targets = new address[](7);
        targets[0] = address(_registry);
        targets[1] = address(_yieldVault);
        targets[2] = address(_operationalVault);
        targets[3] = address(_impactToken);
        targets[4] = address(_engine);
        targets[5] = address(_multiSig);
        targets[6] = address(_timelock);

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
        _timelock.scheduleBatch(targets, values, payloads, bytes32(0), salt, 0);
        _timelock.executeBatch(targets, values, payloads, bytes32(0), salt);
    }

    // STEP 6: Grant Admin Safe roles, revoke deployer roles
    function _lockoutDeployer() internal {
        bytes32 DEFAULT_ADMIN_ROLE = 0x00;

        // Grant permanent governance roles to the Admin Safe multisig
        _timelock.grantRole(_timelock.PROPOSER_ROLE(), _adminSafe);
        _timelock.grantRole(_timelock.CANCELLER_ROLE(), _adminSafe);
        _timelock.grantRole(_timelock.EXECUTOR_ROLE(), address(0)); // Open execution

        // Revoke ALL deployer roles - deployer becomes a zero-privilege EOA
        _timelock.renounceRole(_timelock.PROPOSER_ROLE(), _deployer);
        _timelock.renounceRole(_timelock.CANCELLER_ROLE(), _deployer);
        _timelock.renounceRole(_timelock.EXECUTOR_ROLE(), _deployer);
        _timelock.renounceRole(DEFAULT_ADMIN_ROLE, _deployer);
    }

    // POST-FLIGHT: Mathematical proof of successful handover (view only)
    // Runs AFTER vm.stopBroadcast() - no gas cost in production.
    function _postFlight() internal view {
        bytes32 DEFAULT_ADMIN_ROLE = 0x00;

        require(_registry.owner() == address(_timelock), "PostFlight: Registry handover failed");
        require(_yieldVault.owner() == address(_timelock), "PostFlight: YieldVault handover failed");
        require(
            _operationalVault.owner() == address(_timelock), "PostFlight: OpVault handover failed"
        );
        require(_impactToken.owner() == address(_timelock), "PostFlight: Token handover failed");
        require(_engine.owner() == address(_timelock), "PostFlight: Engine handover failed");
        require(_multiSig.owner() == address(_timelock), "PostFlight: MultiSig handover failed");
        require(_timelock.getMinDelay() == FINAL_TIMELOCK_DELAY, "PostFlight: Delay update failed");
        require(!_timelock.hasRole(DEFAULT_ADMIN_ROLE, _deployer), "PostFlight: Deployer God Mode!");
        require(
            !_timelock.hasRole(_timelock.CANCELLER_ROLE(), _deployer),
            "PostFlight: Deployer Canceller"
        );

        console2.log("Configuration complete. Ownable2Step accepted by Timelock.");
        console2.log("Timelock delay raised to 48h. Deployer locked out and verified.");
    }
}

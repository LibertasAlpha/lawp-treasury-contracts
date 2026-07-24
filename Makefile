.PHONY: all clean build format test test-invariant coverage \
        simulate-deploy-core simulate-configure \
        install-contractdev init-stagenet generate-wallet push-contracts \
        deploy-core-anvil configure-anvil \
        deploy-core-stagenet configure-stagenet \
        deploy-core-base-sepolia configure-protocol-base-sepolia \
        deploy-core-polygon-amoy configure-protocol-polygon-amoy \
        deploy-core-monad-testnet configure-protocol-monad-testnet \
        deploy-core-base-mainnet configure-protocol-base-mainnet \
        deploy-core-polygon-mainnet configure-protocol-polygon-mainnet \
        deploy-core-monad-mainnet configure-protocol-monad-mainnet \
        deploy-all-testnets configure-all-testnets deploy-and-configure-testnets \
        deploy-all-mainnets configure-all-mainnets deploy-and-configure-mainnets \
        deploy-all configure-all deploy-and-configure-all \
        deploy-full-base-sepolia deploy-full-base-mainnet \
        deploy-full-polygon-amoy deploy-full-polygon-mainnet \
        deploy-full-monad-testnet deploy-full-monad-mainnet \
        deploy-cngn deploy-cngn-polygon-amoy deploy-cngn-base-sepolia deploy-cngn-monad-testnet \
        deploy-cngn-all

-include .env

# Default RPC URL if not explicitly set in .env (Anvil)
RPC_URL ?= http://localhost:8545


# ==============================================================================
# BUILD & FORMAT
# ==============================================================================

all: clean format build test

clean:
	forge clean

build:
	forge build

format:
	forge fmt

slither:
	slither src/ \
		--foundry-compile-all \
		--exclude-dependencies \


# ==============================================================================
# TESTING & VERIFICATION
# ==============================================================================

# Standard unit and integration tests
test:
	forge test -vvv

# Deep stateful invariant testing
test-invariant:
	forge test --match-path test/invariant/LAWPInvariantsTest.t.sol -vvv

# Generate coverage reports
# Note: viaIR is automatically disabled by forge coverage - this is expected.
coverage:
	forge coverage


# ==============================================================================
# SIMULATIONS (Dry Runs with controlled execution model)

# simulate-deploy-core uses --broadcast to ensure contracts are actually deployed and addresses persist for downstream configuration steps.

# simulate-configure does NOT use --broadcast since it is intended for execution tracing and validation against already-deployed contract state.

# Run these to verify execution flow, gas estimations, and payload correctness before full protocol deployment.
# ==============================================================================

simulate-deploy-core:
	forge script script/Deploy.s.sol:DeployLAWPSystem --rpc-url $(RPC_URL) --broadcast -vvvv

simulate-configure:
	forge script script/Configure.s.sol:ConfigureLAWPSystem --rpc-url $(RPC_URL) -vvvv


# ==============================================================================
# ANVIL LOCAL DEPLOYMENTS (2-step sequence against local Anvil node)
# REQUIRES: `anvil` running in a separate terminal
# Run in order: deploy-core-anvil -> configure-anvil
# After each step, copy the printed contract addresses into .env
# ==============================================================================

# Step 1: Deploy core protocol contracts
#         -> copy all 6 addresses (Registry, YieldVault, OpVault,
#            ImpactToken, Engine, MultiSig) into .env
deploy-core-anvil:
	forge script script/DeployLocal.s.sol:DeployLocal \
		--rpc-url $(RPC_URL) \
		--private-key $(PRIVATE_KEY) \
		--broadcast \
		-vvvv

# Step 2: Wire contracts + complete Ownable2Step handover to Admin Safe
configure-anvil:
	forge script script/Configure.s.sol:ConfigureLAWPSystem \
		--rpc-url $(RPC_URL) \
		--private-key $(PRIVATE_KEY) \
		--broadcast \
		-vvvv


# ==============================================================================
# CONTRACT.DEV STAGENET - SETUP
# Run these once to initialise the contract.dev CLI for your project.
# REQUIRES: Node.js installed, STAGENET_RPC_URL set in .env
# ==============================================================================

# Install the contract.dev CLI into your npm globally
install-contractdev:
	npm install -g contract.dev

# Initialise the contract.dev config (creates contract.dev.js in project root)
# Run this after setting STAGENET_RPC_URL in .env
init-stagenet:
	npx contract.dev init --rpc-url=$(STAGENET_RPC_URL)

# Generate a funded deployer wallet for Stagenet use
# Copy the printed private key into STAGENET_PRIVATE_KEY in .env
# WARNING: This key is test-only - never use on mainnet
generate-wallet:
	npx contract.dev generate-wallet

# Clean + Build + upload compiled contract artifacts to the Stagenet
# This creates inactive Workspaces that activate on deployment
push-contracts:
	forge clean
	forge build
	npx contract.dev push-contracts


# ==============================================================================
# CONTRACT.DEV STAGENET DEPLOYMENTS (2-step sequence)
# REQUIRES: init-stagenet + generate-wallet + push-contracts completed first.
#           STAGENET_RPC_URL and STAGENET_PRIVATE_KEY set in .env.
# Run in order: deploy-core-stagenet -> configure-stagenet
# After each step, copy the printed contract addresses into .env
# Workspaces on the Stagenet activate automatically when matching bytecode
# is detected - view them at app.contract.dev -> Analytics
# ==============================================================================

# Step 1: Deploy core protocol contracts to Stagenet
#         -> copy all 6 addresses into .env
deploy-core-stagenet:
	forge script script/Deploy.s.sol:DeployLAWPSystem \
		--rpc-url $(STAGENET_RPC_URL) \
		--private-key $(STAGENET_PRIVATE_KEY) \
		--broadcast \
		-vvvv

# Step 2: Wire contracts + complete Ownable2Step handover on Stagenet
configure-stagenet:
	forge script script/Configure.s.sol:ConfigureLAWPSystem \
		--rpc-url $(STAGENET_RPC_URL) \
		--private-key $(STAGENET_PRIVATE_KEY) \
		--broadcast \
		-vvvv


# ==============================================================================
# BASE SEPOLIA TESTNET DEPLOYMENTS
# REQUIRES: DEPLOYER_PRIVATE_KEY, BASE_SEPOLIA_RPC, and BASESCAN_API_KEY in .env
# ==============================================================================

# Step 1: Deploy core protocol bytecodes
deploy-core-base-sepolia:
	forge script script/Deploy.s.sol:DeployLAWPSystem \
		--rpc-url $(BASE_SEPOLIA_RPC) \
		--private-key $(DEPLOYER_PRIVATE_KEY) \
		--broadcast \
		--verify \
		--etherscan-api-key $(BASESCAN_API_KEY) \
		-vvvv

# Step 2: Wire contracts + complete Ownable2Step handover
configure-protocol-base-sepolia:
	forge script script/Configure.s.sol:ConfigureLAWPSystem \
		--rpc-url $(BASE_SEPOLIA_RPC) \
		--private-key $(DEPLOYER_PRIVATE_KEY) \
		--broadcast \
		--verify \
		--etherscan-api-key $(BASESCAN_API_KEY) \
		-vvvv


# ==============================================================================
# POLYGON AMOY TESTNET DEPLOYMENTS
# REQUIRES: DEPLOYER_PRIVATE_KEY, POLYGON_AMOY_RPC, and POLYGONSCAN_API_KEY in .env
# ==============================================================================

# Step 1: Deploy core protocol bytecodes
deploy-core-polygon-amoy:
	forge script script/Deploy.s.sol:DeployLAWPSystem \
		--rpc-url $(POLYGON_AMOY_RPC) \
		--private-key $(DEPLOYER_PRIVATE_KEY) \
		--broadcast \
		--verify \
		--etherscan-api-key $(POLYGONSCAN_API_KEY) \
		-vvvv

# Step 2: Wire contracts + complete Ownable2Step handover
configure-protocol-polygon-amoy:
	forge script script/Configure.s.sol:ConfigureLAWPSystem \
		--rpc-url $(POLYGON_AMOY_RPC) \
		--private-key $(DEPLOYER_PRIVATE_KEY) \
		--broadcast \
		--verify \
		--etherscan-api-key $(POLYGONSCAN_API_KEY) \
		-vvvv


# ==============================================================================
# MONAD TESTNET DEPLOYMENTS
# REQUIRES: DEPLOYER_PRIVATE_KEY, MONAD_TESTNET_RPC, and MONADSCAN_API_KEY in .env
# ==============================================================================

# Step 1: Deploy core protocol bytecodes
deploy-core-monad-testnet:
	forge script script/Deploy.s.sol:DeployLAWPSystem \
		--rpc-url $(MONAD_TESTNET_RPC) \
		--private-key $(DEPLOYER_PRIVATE_KEY) \
		--broadcast \
		--verify \
		--etherscan-api-key $(MONADSCAN_API_KEY) \
		--legacy \
		-vvvv

# Step 2: Wire contracts + complete Ownable2Step handover
configure-protocol-monad-testnet:
	forge script script/Configure.s.sol:ConfigureLAWPSystem \
		--rpc-url $(MONAD_TESTNET_RPC) \
		--private-key $(DEPLOYER_PRIVATE_KEY) \
		--broadcast \
		--verify \
		--etherscan-api-key $(MONADSCAN_API_KEY) \
		--legacy \
		-vvvv


# ==============================================================================
# BASE MAINNET DEPLOYMENTS
# REQUIRES: DEPLOYER_PRIVATE_KEY, BASE_MAINNET_RPC, and BASESCAN_API_KEY in .env
# ==============================================================================

# Step 1: Deploy core protocol bytecodes
deploy-core-base-mainnet:
	forge script script/Deploy.s.sol:DeployLAWPSystem \
		--rpc-url $(BASE_MAINNET_RPC) \
		--private-key $(DEPLOYER_PRIVATE_KEY) \
		--broadcast \
		--verify \
		--etherscan-api-key $(BASESCAN_API_KEY) \
		-vvvv

# Step 2: Wire contracts + complete Ownable2Step handover
configure-protocol-base-mainnet:
	forge script script/Configure.s.sol:ConfigureLAWPSystem \
		--rpc-url $(BASE_MAINNET_RPC) \
		--private-key $(DEPLOYER_PRIVATE_KEY) \
		--broadcast \
		--verify \
		--etherscan-api-key $(BASESCAN_API_KEY) \
		-vvvv


# ==============================================================================
# POLYGON MAINNET DEPLOYMENTS
# REQUIRES: DEPLOYER_PRIVATE_KEY, POLYGON_MAINNET_RPC, and POLYGONSCAN_API_KEY in .env
# ==============================================================================

# Step 1: Deploy core protocol bytecodes
deploy-core-polygon-mainnet:
	forge script script/Deploy.s.sol:DeployLAWPSystem \
		--rpc-url $(POLYGON_MAINNET_RPC) \
		--private-key $(DEPLOYER_PRIVATE_KEY) \
		--broadcast \
		--verify \
		--etherscan-api-key $(POLYGONSCAN_API_KEY) \
		-vvvv

# Step 2: Wire contracts + complete Ownable2Step handover
configure-protocol-polygon-mainnet:
	forge script script/Configure.s.sol:ConfigureLAWPSystem \
		--rpc-url $(POLYGON_MAINNET_RPC) \
		--private-key $(DEPLOYER_PRIVATE_KEY) \
		--broadcast \
		--verify \
		--etherscan-api-key $(POLYGONSCAN_API_KEY) \
		-vvvv


# ==============================================================================
# MONAD MAINNET DEPLOYMENTS
# REQUIRES: DEPLOYER_PRIVATE_KEY, MONAD_MAINNET_RPC, and MONADSCAN_API_KEY in .env
# ==============================================================================

# Step 1: Deploy core protocol bytecodes
deploy-core-monad-mainnet:
	forge script script/Deploy.s.sol:DeployLAWPSystem \
		--rpc-url $(MONAD_MAINNET_RPC) \
		--private-key $(DEPLOYER_PRIVATE_KEY) \
		--broadcast \
		--verify \
		--etherscan-api-key $(MONADSCAN_API_KEY) \
		-vvvv

# Step 2: Wire contracts + complete Ownable2Step handover
configure-protocol-monad-mainnet:
	forge script script/Configure.s.sol:ConfigureLAWPSystem \
		--rpc-url $(MONAD_MAINNET_RPC) \
		--private-key $(DEPLOYER_PRIVATE_KEY) \
		--broadcast \
		--verify \
		--etherscan-api-key $(MONADSCAN_API_KEY) \
		-vvvv


# ==============================================================================
# CNGN TOKEN DEPLOYMENTS
# Deploys Mock CNGN token on networks where it doesn't exist
# REQUIRES: DEPLOYER_PRIVATE_KEY and appropriate RPC_URL in .env
# ==============================================================================

# Deploy CNGN on default RPC (Anvil)
deploy-cngn:
	forge script script/DeployCNGN.s.sol:DeployCNGNLocal \
		--rpc-url $(RPC_URL) \
		--private-key $(DEPLOYER_PRIVATE_KEY) \
		--broadcast \
		-vvvv

# Deploy CNGN on Base Sepolia
deploy-cngn-base-sepolia:
	forge script script/DeployCNGN.s.sol:DeployCNGNLocal \
		--rpc-url $(BASE_SEPOLIA_RPC) \
		--private-key $(DEPLOYER_PRIVATE_KEY) \
		--broadcast \
		--verify \
		--etherscan-api-key $(BASESCAN_API_KEY) \
		-vvvv

# Deploy CNGN on Polygon Amoy
deploy-cngn-polygon-amoy:
	forge script script/DeployCNGN.s.sol:DeployCNGNLocal \
		--rpc-url $(POLYGON_AMOY_RPC) \
		--private-key $(DEPLOYER_PRIVATE_KEY) \
		--broadcast \
		--verify \
		--etherscan-api-key $(POLYGONSCAN_API_KEY) \
		-vvvv

# Deploy CNGN on Monad Testnet
deploy-cngn-monad-testnet:
	forge script script/DeployCNGN.s.sol:DeployCNGNLocal \
		--rpc-url $(MONAD_TESTNET_RPC) \
		--private-key $(DEPLOYER_PRIVATE_KEY) \
		--broadcast \
		--verify \
		--etherscan-api-key $(MONADSCAN_API_KEY) \
		--legacy \
		-vvvv

# Deploy CNGN on all testnets
deploy-cngn-all: deploy-cngn-base-sepolia deploy-cngn-polygon-amoy deploy-cngn-monad-testnet


# ==============================================================================
# CONVENIENCE TARGETS
# ==============================================================================

# Testnet targets
deploy-all-testnets: deploy-core-base-sepolia deploy-core-polygon-amoy deploy-core-monad-testnet
configure-all-testnets: configure-protocol-base-sepolia configure-protocol-polygon-amoy configure-protocol-monad-testnet
deploy-and-configure-testnets: deploy-all-testnets configure-all-testnets

# Mainnet targets
deploy-all-mainnets: deploy-core-base-mainnet deploy-core-polygon-mainnet deploy-core-monad-mainnet
configure-all-mainnets: configure-protocol-base-mainnet configure-protocol-polygon-mainnet configure-protocol-monad-mainnet
deploy-and-configure-mainnets: deploy-all-mainnets configure-all-mainnets

# All networks
deploy-all: deploy-all-testnets deploy-all-mainnets
configure-all: configure-all-testnets configure-all-mainnets
deploy-and-configure-all: deploy-all configure-all

# Individual network full deploy (deploy + configure)
deploy-full-base-sepolia: deploy-core-base-sepolia configure-protocol-base-sepolia
deploy-full-base-mainnet: deploy-core-base-mainnet configure-protocol-base-mainnet
deploy-full-polygon-amoy: deploy-core-polygon-amoy configure-protocol-polygon-amoy
deploy-full-polygon-mainnet: deploy-core-polygon-mainnet configure-protocol-polygon-mainnet
deploy-full-monad-testnet: deploy-core-monad-testnet configure-protocol-monad-testnet
deploy-full-monad-mainnet: deploy-core-monad-mainnet configure-protocol-monad-mainnet

# Deploy everything (protocol + CNGN) on all testnets
deploy-everything-testnets: deploy-all-testnets deploy-cngn-all
deploy-everything-all: deploy-all deploy-cngn-all
-include .env

.PHONY: all clean build format test test-invariant coverage \
        simulate-deploy-core simulate-configure \
        install-contractdev init-stagenet generate-wallet push-contracts \
        deploy-core-anvil configure-anvil \
        deploy-core-stagenet configure-stagenet \
        deploy-core-testnet configure-protocol-testnet

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
# SIMULATIONS (Dry Runs - No actual broadcast)
# Run these to verify gas estimations and payload correctness before deployment.
# ==============================================================================

simulate-deploy-core:
	forge script script/Deploy.s.sol:DeployLAWPSystem --rpc-url $(RPC_URL) -vvvv

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
	forge script script/Deploy.s.sol:DeployLAWPSystem \
		--rpc-url $(RPC_URL) \
		--private-key $(DEPLOYER_PRIVATE_KEY) \
		--broadcast \
		-vvvv

# Step 2: Wire contracts + complete Ownable2Step handover to Admin Safe
configure-anvil:
	forge script script/Configure.s.sol:ConfigureLAWPSystem \
		--rpc-url $(RPC_URL) \
		--private-key $(DEPLOYER_PRIVATE_KEY) \
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
deploy-core-testnet:
	forge script script/Deploy.s.sol:DeployLAWPSystem \
		--rpc-url $(BASE_SEPOLIA_RPC) \
		--private-key $(DEPLOYER_PRIVATE_KEY) \
		--broadcast \
		--verify \
		--etherscan-api-key $(BASESCAN_API_KEY) \
		-vvvv

# Step 2: Wire contracts + complete Ownable2Step handover
configure-protocol-testnet:
	forge script script/Configure.s.sol:ConfigureLAWPSystem \
		--rpc-url $(BASE_SEPOLIA_RPC) \
		--private-key $(DEPLOYER_PRIVATE_KEY) \
		--broadcast \
		--verify \
		--etherscan-api-key $(BASESCAN_API_KEY) \
		-vvvv
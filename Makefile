-include .env

.PHONY: all clean build format test test-invariant coverage simulate-deploy-mocks simulate-deploy-core simulate-configure deploy-mocks-testnet deploy-core-testnet configure-protocol-testnet

# Default RPC URL if not explicitly set in .env
RPC_URL ?= http://localhost:8545

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

# Deep stateful invariant testing (Phase 5)
test-invariant:
	forge test --match-path test/invariant/LAWPInvariants.t.sol -vvv

# Generate coverage reports
coverage:
	forge coverage

# ==============================================================================
# SIMULATIONS (Dry Runs - No actual broadcast)
# Run these to verify gas estimations and payload correctness before deployment
# ==============================================================================

simulate-deploy-mocks:
	forge script script/DeployMock.s.sol:DeployMock --rpc-url $(RPC_URL) -vvvv

simulate-deploy-core:
	forge script script/Deploy.s.sol:Deploy --rpc-url $(RPC_URL) -vvvv

simulate-configure:
	forge script script/Configure.s.sol:Configure --rpc-url $(RPC_URL) -vvvv

# ==============================================================================
# LIVE DEPLOYMENTS (Broadcasts transactions to the network)
# REQUIRES: PRIVATE_KEY, BASE_SEPOLIA_RPC, and BASESCAN_API_KEY in .env
# ==============================================================================

# Step 1: Deploy Mocks (For Testnet only)
deploy-mocks-testnet:
	forge script script/DeployMock.s.sol:DeployMock --rpc-url $(BASE_SEPOLIA_RPC) --private-key $(PRIVATE_KEY) --broadcast --verify --etherscan-api-key $(BASESCAN_API_KEY) -vvvv

# Step 2: Deploy Core Protocol Bytecodes
deploy-core-testnet:
	forge script script/Deploy.s.sol:Deploy --rpc-url $(BASE_SEPOLIA_RPC) --private-key $(PRIVATE_KEY) --broadcast --verify --etherscan-api-key $(BASESCAN_API_KEY) -vvvv

# Step 3: Wire Contracts and Execute Atomic Timelock Bootstrap
configure-protocol-testnet:
	forge script script/Configure.s.sol:Configure --rpc-url $(BASE_SEPOLIA_RPC) --private-key $(PRIVATE_KEY) --broadcast --verify --etherscan-api-key $(BASESCAN_API_KEY) -vvvv
-include .env

.PHONY: all build test test-coverage lint format deploy-anvil deploy-base-sepolia deploy-base deploy-monad

all: clean install build test

clean:
	forge clean

install:
	forge install

build:
	forge build

test:
	forge test

test-coverage:
	forge coverage

lint:
	forge fmt --check

format:
	forge fmt

# Deployment Scripts

# Deploy to local anvil node
deploy-anvil:
	@echo "Deploying to Anvil local node..."
	forge script script/DeployLAWPSystem.s.sol:DeployLAWPSystem --rpc-url http://localhost:8545 --broadcast -vvvv

# Deploy to Base Sepolia
deploy-base-sepolia:
	@echo "Deploying to Base Sepolia..."
	forge script script/DeployLAWPSystem.s.sol:DeployLAWPSystem --rpc-url $(BASE_SEPOLIA_RPC_URL) --broadcast --verify -vvvv

# Deploy to Base Mainnet
deploy-base:
	@echo "Deploying to Base Mainnet..."
	forge script script/DeployLAWPSystem.s.sol:DeployLAWPSystem --rpc-url $(BASE_RPC_URL) --broadcast --verify --etherscan-api-key $(BASESCAN_API_KEY) -vvvv

# Deploy to Monad Testnet
deploy-monad:
	@echo "Deploying to Monad Testnet..."
	forge script script/DeployLAWPSystem.s.sol:DeployLAWPSystem --rpc-url $(MONAD_RPC_URL) --broadcast -vvvv

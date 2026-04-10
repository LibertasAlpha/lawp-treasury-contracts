-include .env

.PHONY: all test clean deploy-sepolia

all: clean build

build:
	forge build

test:
	forge test -vvv

clean:
	forge clean

format:
	forge fmt

# Deployment simulator
deploy-dry-run:
	forge script script/Deploy.s.sol:Deploy --rpc-url $(BASE_SEPOLIA_RPC) --private-key $(DEPLOYER_PRIVATE_KEY) --broadcast --verify --tc Deploy
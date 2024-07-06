-include .env

.PHONY: deploy

deploy :; @forge script script/DeployDTsla.s.sol --rpc-url ${SEPOLIA_RPC_URL} --etherscan-api-key ${ETHERSCAN_API_KEY} --priority-gas-price 1 --legacy --verify --broadcast --account metamask-wallet --sender #add your wallet address
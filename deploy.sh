#!/bin/bash

source .env

if [[ -z "$RPC_URL" ]]; then
    error_exit "RPC_URL is not defined"
fi
echo "RPC endpoint = $RPC_URL"

# echo "Balance = $(echo "$(cast balance $ETH_FROM)/10^18" | bc -l) ETH"

forge script script/AxelarXCMRelayer.s.sol:AxelarXCMRelayerScript --optimize --rpc-url $RPC_URL --gas-estimate-multiplier 500 --private-key $PRIVATE_KEY --verify --broadcast --chain-id $CHAIN_ID --etherscan-api-key $ETHERSCAN_KEY
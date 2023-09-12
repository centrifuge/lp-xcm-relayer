// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.21;

import {AxelarXCMRelayer} from "src/XCMRelayer.sol";
import "forge-std/Script.sol";

// Script to deploy Axelar over XCM relayer.
contract AxelarXCMRelayerScript is Script {
    function setUp() public {}

    function run() public {
        vm.startBroadcast();

        address admin = vm.envAddress("ADMIN");

        AxelarXCMRelayer router = new AxelarXCMRelayer(
            address(vm.envAddress("CENTRIFUGE_CHAIN_ORIGIN")),
            address(vm.envAddress("AXELAR_GATEWAY")),
            uint8(vm.envUint("CENTRIFUGE_CHAIN_LIQUIDITY_POOLS_GATEWAY_PALLET_INDEX")),
            uint8(vm.envUint("CENTRIFUGE_CHAIN_LIQUIDITY_POOLS_GATEWAY_PALLET_PROCESS_MSG_CALL_INDEX"))
        );

        router.rely(admin);
        router.deny(address(this));

        vm.stopBroadcast();
    }
}

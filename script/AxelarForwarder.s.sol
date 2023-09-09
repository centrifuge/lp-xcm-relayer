// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.21;

import {AxelarForwarder} from "src/Forwarder.sol";
import "forge-std/Script.sol";

// Script to deploy Axelar over XCM relayer.
contract AxelarForwarderScript is Script {
    function setUp() public {}

    function run() public {
        vm.startBroadcast();

        address admin = vm.envAddress("ADMIN");

        AxelarForwarder router = new AxelarForwarder(
            address(vm.envAddress("AXELAR_GATEWAY"))
        );

        router.rely(admin);
        router.deny(address(this));

        vm.stopBroadcast();
    }
}

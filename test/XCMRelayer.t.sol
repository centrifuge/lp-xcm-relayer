// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.21;

import "forge-std/Test.sol";
import {_centrifugeCall} from "src/XCMRelayer.sol";

contract XCMRelayerTest is Test {
    function test_centrifuge_call() public {
        string memory sourceChain = "ethereum-2";
        string memory sourceAddress = "0x8503b4452Bf6238cC76CdbEE223b46d7196b1c93";
        bytes memory message =
            hex"0b0000000000000001811acd5b3f17c06841c7e41e9e04cb1b45645645645645645645645645645645645645645645645645645645645645640000000000000000000000000eb5ec7b000000000052b7d2dcc80cd2e4000000";
        bytes memory expected =
            hex"730555020000000a657468657265756d2d320000002a3078383530336234343532426636323338634337364364624545323233623436643731393662316339330b0000000000000001811acd5b3f17c06841c7e41e9e04cb1b45645645645645645645645645645645645645645645645645645645645645640000000000000000000000000eb5ec7b000000000052b7d2dcc80cd2e4000000";

        assertEq(_centrifugeCall(115, 5, sourceChain, sourceAddress, message), expected);
    }
}

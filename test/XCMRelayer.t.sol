// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.21;

import "forge-std/Test.sol";
import {_processMsgPayload} from "src/XCMRelayer.sol";

contract XCMRelayerTest is Test {
    function setUp() public {}

    function test_call_centrifuge_process_msg_payload() public {
        string memory sourceChain = "ethereum-2";
        string memory sourceAddress = "8503b4452Bf6238cC76CdbEE223b46d7196b1c93";
        bytes memory message =
            hex"0b0000000000000001811acd5b3f17c06841c7e41e9e04cb1b45645645645645645645645645645645645645645645645645645645645645640000000000000000000000000eb5ec7b000000000052b7d2dcc80cd2e4000000";
        bytes memory centrifugeGeneratedPayload =
            hex"0000000a657468657265756d2d32000000148503b4452bf6238cc76cdbee223b46d7196b1c930b0000000000000001811acd5b3f17c06841c7e41e9e04cb1b45645645645645645645645645645645645645645645645645645645645645640000000000000000000000000eb5ec7b000000000052b7d2dcc80cd2e4000000";

        assertEq(_processMsgPayload(sourceChain, sourceAddress, message), centrifugeGeneratedPayload);
    }
}

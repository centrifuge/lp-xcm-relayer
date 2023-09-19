// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.21;

import {Auth} from "./util/Auth.sol";

struct Multilocation {
    uint8 parents;
    bytes[] interior;
}

// https://github.com/PureStake/moonbeam/blob/v0.30.0/precompiles/xcm-transactor/src/v2/XcmTransactorV2.sol#L12
interface XcmTransactorV2 {
    function transactThroughSignedMultilocation(
        Multilocation memory dest,
        Multilocation memory feeLocation,
        uint64 transactRequiredWeightAtMost,
        bytes memory call,
        uint256 feeAmount,
        uint64 overallWeight
    ) external;
}

struct XcmWeightInfo {
    // The weight limit in Weight units we accept amount to pay for the
    // execution of the whole XCM on the Centrifuge chain. This should be
    // transactWeightAtMost + an extra amount to cover for the other
    // instructions in the XCM message.
    uint64 buyExecutionWeightLimit;
    // The weight limit in Weight units we accept paying for having the Transact
    // call be executed. This is the cost associated with executing the handle call
    // in the Centrifuge.
    uint64 transactWeightAtMost;
    // The amount to cover for the fees. It will be used in XCM to buy
    // execution and thus have credit for pay those fees.
    uint256 feeAmount;
}

interface AxelarGatewayLike {
    function callContract(string calldata destinationChain, string calldata contractAddress, bytes calldata payload)
        external;

    function validateContractCall(
        bytes32 commandId,
        string calldata sourceChain,
        string calldata sourceAddress,
        bytes32 payloadHash
    ) external returns (bool);
}

contract AxelarXCMRelayer is Auth {
    address private constant XCM_TRANSACTOR_V2_ADDRESS = 0x000000000000000000000000000000000000080D;
    uint32 private constant CENTRIFUGE_PARACHAIN_ID = 2031;
    uint8 private constant LP_GATEWAY_CALL_INDEX = 5;

    AxelarGatewayLike public immutable axelarGateway;
    address public immutable centrifugeChainOrigin;
    mapping(string => string) public axelarEVMRouters;

    XcmWeightInfo public xcmWeightInfo;
    uint8 public immutable lpGatewayPalletIndex;

    // --- Events ---
    event File(bytes32 indexed what, XcmWeightInfo xcmWeightInfo);
    event File(bytes32 indexed what, string chain, string addr);
    event Executed(
        bytes payloadWithHash,
        uint8 lpPalletIndex,
        uint8 lpCallIndex,
        bytes32 sourceChainLength,
        bytes sourceChain,
        bytes32 sourceAddressLength,
        bytes sourceAddress,
        bytes payload
    );

    constructor(address centrifugeChainOrigin_, address axelarGateway_, uint8 lpGatewayPalletIndex_) {
        centrifugeChainOrigin = centrifugeChainOrigin_;
        axelarGateway = AxelarGatewayLike(axelarGateway_);

        xcmWeightInfo = XcmWeightInfo({
            buyExecutionWeightLimit: 15530000000,
            transactWeightAtMost: 12530000000,
            feeAmount: 155548480000000000
        });
        lpGatewayPalletIndex = lpGatewayPalletIndex_;

        wards[msg.sender] = 1;
        emit Rely(msg.sender);
    }

    modifier onlyCentrifugeChain() {
        require(msg.sender == address(centrifugeChainOrigin), "AxelarXCMRelayer/only-centrifuge-chain-allowed");
        _;
    }

    modifier onlyAxelarEVMRouter(string memory sourceChain, string memory sourceAddress) {
        require(
            keccak256(abi.encodePacked(axelarEVMRouters[sourceChain])) == keccak256(abi.encodePacked(sourceAddress)),
            "AxelarXCMRelayer/only-axelar-evm-router-allowed"
        );
        _;
    }

    // --- Administration ---
    function file(bytes32 what, string calldata axelarEVMRouterChain, string calldata axelarEVMRouterAddress)
        external
        auth
    {
        if (what == "axelarEVMRouter") {
            axelarEVMRouters[axelarEVMRouterChain] = axelarEVMRouterAddress;
        } else {
            revert("AxelarXCMRelayer/file-unrecognized-param");
        }

        emit File(what, axelarEVMRouterChain, axelarEVMRouterAddress);
    }

    function file(bytes32 what, uint64 buyExecutionWeightLimit, uint64 transactWeightAtMost, uint256 feeAmount)
        external
        auth
    {
        if (what == "xcmWeightInfo") {
            xcmWeightInfo = XcmWeightInfo(buyExecutionWeightLimit, transactWeightAtMost, feeAmount);
        } else {
            revert("AxelarXCMRelayer/file-unrecognized-param");
        }

        emit File(what, xcmWeightInfo);
    }

    // --- Incoming ---
    // A message that's coming from another EVM chain, headed to the Centrifuge Chain.
    function execute(
        bytes32 commandId,
        string calldata sourceChain,
        string calldata sourceAddress,
        bytes calldata payload
    ) public onlyAxelarEVMRouter(sourceChain, sourceAddress) {
        require(
            axelarGateway.validateContractCall(commandId, sourceChain, sourceAddress, keccak256(payload)),
            "XCMRelayer/not-approved-by-gateway"
        );

        bytes memory encodedCall =
            _centrifugeCall(lpGatewayPalletIndex, LP_GATEWAY_CALL_INDEX, sourceChain, sourceAddress, payload);

        emit Executed(
            encodedCall,
            lpGatewayPalletIndex,
            LP_GATEWAY_CALL_INDEX,
            bytes32(bytes(sourceChain).length),
            bytes(sourceChain),
            bytes32(bytes(sourceAddress).length),
            bytes(sourceAddress),
            payload
        );

        XcmTransactorV2(XCM_TRANSACTOR_V2_ADDRESS).transactThroughSignedMultilocation(
            // dest chain
            _centrifugeParachainMultilocation(),
            // fee asset
            _cfgAssetMultilocation(),
            // the weight limit for the transact call execution
            xcmWeightInfo.transactWeightAtMost,
            // the call to be executed on the cent chain
            encodedCall,
            // the CFG we offer to pay for execution fees of the whole XCM
            xcmWeightInfo.feeAmount,
            // overall XCM weight, the total weight the XCM-transactor extrinsic can use.
            // This includes all the XCM instructions plus the weight of the Transact call itself.
            xcmWeightInfo.buyExecutionWeightLimit
        );

        return;
    }

    // --- Outgoing ---
    // A message that has been sent from the Centrifuge Chain, heading to a specific destination EVM chain
    function send(string calldata destinationChain, string calldata destinationAddress, bytes calldata payload)
        external
        onlyCentrifugeChain
    {
        axelarGateway.callContract(destinationChain, destinationAddress, payload);
    }

    function _centrifugeParachainMultilocation() internal pure returns (Multilocation memory) {
        bytes[] memory interior = new bytes[](1);
        interior[0] = _parachainId();

        return Multilocation({parents: 1, interior: interior});
    }

    function _cfgAssetMultilocation() internal pure returns (Multilocation memory) {
        bytes[] memory interior = new bytes[](2);
        interior[0] = _parachainId();
        // Multilocation V3
        // GeneralKey prefix - 06
        // Length - 2 bytes
        // 0001 + padded to 32 bytes
        interior[1] = hex"06020001000000000000000000000000000000000000000000000000000000000000";

        return Multilocation({parents: 1, interior: interior});
    }

    function _parachainId() internal pure returns (bytes memory) {
        return abi.encodePacked(uint8(0), CENTRIFUGE_PARACHAIN_ID);
    }
}

// --- Utilities ---
function _centrifugeCall(
    uint8 palletIndex,
    uint8 callIndex,
    string memory sourceChain,
    string memory sourceAddress,
    bytes memory message
) pure returns (bytes memory) {
    bytes memory payload = abi.encodePacked(
        uint32(bytes(sourceChain).length), sourceChain, uint32(bytes(sourceAddress).length), sourceAddress, message
    );

    return abi.encodePacked(palletIndex, callIndex, _compactLen(payload), payload);
}

function _compactLen(bytes memory payload) pure returns (bytes memory) {
    // Panic if length exceeds uint32::MAX
    require(payload.length < uint256(0xFFFFFFFF), "AxelarXCMRelayer/payload-exceeds-max-length");

    uint32 length = uint32(payload.length);

    // NOTE: The following is the Scale-Codec for a Compact<u32> value.
    if (length <= 0x3F) {
        bytes1 valueU8 = bytes1((uint8(length) << 2));
        return bytes.concat(valueU8[0]);
    } else if (length <= 0x3FFF) {
        bytes2 valueU16 = bytes2(uint16(length) << 2 | 0x1);
        return bytes.concat(valueU16[1], valueU16[0]);
    } else if (length <= 0x3FFFFFFF) {
        bytes4 valueU32 = bytes4(uint32(length) << 2 | 0x2);
        return bytes.concat(valueU32[3], valueU32[2], valueU32[1], valueU32[0]);
    } else {
        bytes1 valueU8 = bytes1(uint8(0x3));
        bytes4 valueU32 = bytes4(length);
        return bytes.concat(valueU8[0], valueU32[3], valueU32[2], valueU32[1], valueU32[0]);
    }
}

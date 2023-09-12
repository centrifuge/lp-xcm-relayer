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

    AxelarGatewayLike public immutable axelarGateway;
    address public immutable centrifugeChainOrigin;
    mapping(string => string) public axelarEVMRouters;

    XcmWeightInfo public xcmWeightInfo;
    uint8 public immutable centrifugeChainLiquidityPoolsGatewayPalletIndex;
    uint8 public immutable centrifugeChainLiquidityPoolsGatewayPalletProcessMsgCallIndex;

    // --- Events ---
    event File(bytes32 indexed what, XcmWeightInfo xcmWeightInfo);
    event File(bytes32 indexed what, string chain, string addr);
    event Executed(
        bytes payloadWithHash,
        bytes lpPalletIndex,
        bytes lpCallIndex,
        bytes32 sourceChainLength,
        bytes sourceChain,
        bytes32 sourceAddressLength,
        bytes sourceAddress,
        bytes payload
    );

    constructor(
        address centrifugeChainOrigin_,
        address axelarGateway_,
        uint8 centrifugeChainLiquidityPoolsGatewayPalletIndex_,
        uint8 centrifugeChainLiquidityPoolsGatewayPalletProcessMsgCallIndex_
    ) {
        centrifugeChainOrigin = centrifugeChainOrigin_;
        axelarGateway = AxelarGatewayLike(axelarGateway_);

        xcmWeightInfo = XcmWeightInfo({
            buyExecutionWeightLimit: 19000000000,
            transactWeightAtMost: 8000000000,
            feeAmount: 1000000000000000000
        });
        centrifugeChainLiquidityPoolsGatewayPalletIndex = centrifugeChainLiquidityPoolsGatewayPalletIndex_;
        centrifugeChainLiquidityPoolsGatewayPalletProcessMsgCallIndex = centrifugeChainLiquidityPoolsGatewayPalletProcessMsgCallIndex_;

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

        bytes memory encodedCall = _centrifugeCall(message);

        emit Executed(
            encodedCall,
            "0x73",
            "0x05",
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

    /// TMP: Test execute a given LP msg
    function test_execute_msg(bytes message) external {
        bytes memory encodedCall = _centrifugeCall(message);

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

    /// TMP: Test execute a given Centrifuge chain encoded call
    function test_execute_call(bytes encodedCall) external {
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

    // --- Utilities ---
    function _centrifugeCall(bytes memory message) internal view returns (bytes memory) {
        return abi.encodePacked(
        // The Centrifuge liquidity-pools pallet index
        centrifugeChainLiquidityPoolsGatewayPalletIndex,
        // The `handle` call index within the liquidity-pools pallet
        centrifugeChainLiquidityPoolsGatewayPalletProcessMsgCallIndex,
        // We need to specify the length of the message in the scale-encoding format
        messageLengthScaleEncoded(message),
        // The connector message itself
        message
        );
    }

    // Obtain the Scale-encoded length of a given message. Each Liquidity Pools Message is fixed-sized and
    // have thus a fixed scale-encoded length associated to which message variant (aka Call).
    //
    // TODO(Nuno): verify this is still correct and that we support all new incoming messages
    function messageLengthScaleEncoded(bytes memory _msg) internal pure returns (bytes memory) {
        Call call = messageType(_msg);

        if (call == Call.Transfer) {
            return hex"8501";
        } else if (call == Call.transferTrancheTokens(_msg)) {
            // A TransferTrancheTokens message is 82 bytes long which encodes to 0x4901 in Scale
            return hex"4901";
        } else if (call == Call.IncreaseInvestOrder) {
            return hex"6501";
        } else if (call == Call.DecreaseInvestOrder) {
            return hex"6501";
        } else if (call == Call.IncreaseRedeemOrder) {
            return hex"6501";
        } else if (call == Call.DecreaseRedeemOrder) {
            return hex"6501";
        } else if (call == Call.CollectInvest) {
            return hex"e4";
        } else if (call == Call.CollectRedeem) {
            return hex"e4";
        } else {
            revert("AxelarXCMRelayer/unsupported-outgoing-message");
        }
    }

}


enum Call
    /// 0 - An invalid message
{
    Invalid,
    /// 1 - Add a currency id -> EVM address mapping
    AddCurrency,
    /// 2 - Add Pool
    AddPool,
    /// 3 - Allow a registered currency to be used as a pool currency or as an investment currency
    AllowPoolCurrency,
    /// 4 - Add a Pool's Tranche Token
    AddTranche,
    /// 5 - Update the price of a Tranche Token
    UpdateTrancheTokenPrice,
    /// 6 - Update the member list of a tranche token with a new member
    UpdateMember,
    /// 7 - A transfer of Stable CoinsformatTransferTrancheTokens
    Transfer,
    /// 8 - A transfer of Tranche tokens
    TransferTrancheTokens,
    /// 9 - Increase an investment order by a given amount
    IncreaseInvestOrder,
    /// 10 - Decrease an investment order by a given amount
    DecreaseInvestOrder,
    /// 11 - Increase a Redeem order by a given amount
    IncreaseRedeemOrder,
    /// 12 - Decrease a Redeem order by a given amount
    DecreaseRedeemOrder,
    /// 13 - Collect investment
    CollectInvest,
    /// 14 - Collect Redeem
    CollectRedeem,
    /// 15 - Executed Decrease Invest Order
    ExecutedDecreaseInvestOrder,
    /// 16 - Executed Decrease Redeem Order
    ExecutedDecreaseRedeemOrder,
    /// 17 - Executed Collect Invest
    ExecutedCollectInvest,
    /// 18 - Executed Collect Redeem
    ExecutedCollectRedeem,
    /// 19 - Cancel an investment order
    CancelInvestOrder,
    /// 20 - Cancel a redeem order
    CancelRedeemOrder,
    /// 21 - Schedule an upgrade contract to be granted admin rights
    ScheduleUpgrade,
    /// 22 - Cancel a previously scheduled upgrade
    CancelUpgrade,
    /// 23 - Update tranche token metadata
    UpdateTrancheTokenMetadata,
    /// 24 - Update tranche investment limit
    UpdateTrancheInvestmentLimit
}

function messageType(bytes memory _msg) internal pure returns (Call _call) {
    _call = Call(BytesLib.toUint8(_msg, 0));
}
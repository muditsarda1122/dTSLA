// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {ConfirmedOwner} from "@chainlink/contracts/src/v0.8/shared/access/ConfirmedOwner.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {FunctionsClient} from "@chainlink/contracts/src/v0.8/functions/dev/v1_0_0/FunctionsClient.sol";
import {FunctionsRequest} from "@chainlink/contracts/src/v0.8/functions/dev/v1_0_0/libraries/FunctionsRequest.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

contract dTSLA is ConfirmedOwner, Pausable, FunctionsClient, ERC20 {
    using FunctionsRequest for FunctionsRequest.Request;
    using Strings for uint256;

    enum MintOrRedeem {
        mint,
        redeem
    }

    // this will allow us to store information about every request that we shall make
    struct dTslaRequest {
        uint256 amountOfToken;
        address requester;
        MintOrRedeem mintOrRedeem;
    }

    //////////////////////////////////////////
    // CONSTANTS AND IMMUTABLES //////////////
    //////////////////////////////////////////
    // Math constants
    uint256 constant PRECISION = 1e18;
    uint256 constant ADDITIONAL_FEED_PRECISION = 1e10;

    address constant SEPOLIA_FUNCTIONS_ROUTER = 0xb83E47C2bC239B3bf370bc41e1459A34b41238D0;
    uint32 constant GAS_LIMIT = 300_000;
    bytes32 constant DON_ID = hex"66756e2d657468657265756d2d7365706f6c69612d3100000000000000000000";
    address constant SEPOLIA_TSLA_PRICE_FEED = 0x42585eD362B3f1BCa95c640FdFf35Ef899212734; // This is actually LINK/ETH price feed address because TSLA/USD price feed could not be found for Sepolia. It is available for Polygon.
    address constant SEPOLIA_USDC_PRICE_FEED = 0xA2F78ab2355fe2f984D808B5CeE7FD0A93D5270E;
    address constant SEPOLIA_USDC = 0xAF0d217854155ea67D583E4CB5724f7caeC3Dc87; // this is a fake USDC address for Sepolia
    uint256 constant COLLATERAL_RATIO = 200; //it means we need 200% over collateralization. eg. If we have $200 worth of TSLA stocks, we will mint AT MAX $100 worth of dTSLA tokens
    uint256 constant COLLATERAL_PRECISION = 100;
    uint256 constant MINIMUM_WITHDRAWL_AMOUNT = 100e18;
    uint64 immutable i_subId;

    /////////////////////////
    // STORAGE VARIABLES ////
    /////////////////////////
    // will be used to call chainlink function
    string private s_mintSourceCode;
    string private s_redeemSourceCode;
    uint256 private s_portfolioBalance;
    bytes32 private s_mostRecentRequestId;
    mapping(bytes32 requestId => dTslaRequest request) private s_requestIdToRequest;
    mapping(address user => uint256 pendingWithdrawlAmount) private s_userToWithdrawlAMount;
    uint8 donHostedSecretsSlotID = 0;
    uint64 donHostedSecretsVersion = 1719823937;

    ////////////////
    // ERRORS //////
    ////////////////
    error dTSLA__NotEnoughCollateral();
    error dTSLA__DoesntMeetMinimumWithdrawlAMount();
    error dTSLA__FailedToWithdraw();

    //////////////////
    // FUNCTIONS /////
    //////////////////
    constructor(string memory mintSourceCode, string memory redeemSourceCode, uint64 subId)
        ConfirmedOwner(msg.sender)
        FunctionsClient(SEPOLIA_FUNCTIONS_ROUTER)
        ERC20("dTSLA", "dTSLA")
    {
        s_mintSourceCode = mintSourceCode;
        s_redeemSourceCode = redeemSourceCode;
        i_subId = subId;
    }
    // send an HTTP request to:
    // 1. See how much TSLA has been bought
    // 2. If enough TSLA is in the alpaca account, mint dTSLA

    function sendMintRequest(uint256 amount) external onlyOwner whenNotPaused returns (bytes32) {
        FunctionsRequest.Request memory req;
        // will allow us to write code in javascript
        req.initializeRequestForInlineJavaScript(s_mintSourceCode);
        req.addDONHostedSecrets(donHostedSecretsSlotID, donHostedSecretsVersion);
        bytes32 requestId = _sendRequest(req.encodeCBOR(), i_subId, GAS_LIMIT, DON_ID);
        s_mostRecentRequestId = requestId;
        s_requestIdToRequest[requestId] = dTslaRequest(amount, msg.sender, MintOrRedeem.mint);
        return requestId;
    }

    // Returns the amount of TSLA value(in USD) stored in our brokerage
    // If we have enough TSLA(in value), then we mint dTSLA tokens
    // 'response' will have yes/no if we have enough TSLA
    function _mintFulfillRequest(bytes32 requestId, bytes memory response) internal {
        uint256 amountOfTokensToMint = s_requestIdToRequest[requestId].amountOfToken;
        s_portfolioBalance = uint256(bytes32(response));

        // if TSLA collateral(how much TSLA we have bought) > dTSLA to mint --> mint
        // we need to answer 2 questions:
        // How much TSLA in $ do we have?
        // How much TSLA in $ are we minting?
        if (_getCollateralRatioAdjustedTotalBalance(amountOfTokensToMint) > s_portfolioBalance) {
            //we always want more TSLA stocks than TSLA tokens
            revert dTSLA__NotEnoughCollateral();
        }

        if (amountOfTokensToMint != 0) {
            _mint(s_requestIdToRequest[requestId].requester, amountOfTokensToMint);
        }
    }

    // User send a request to sell TSLA for USDC
    // This will have chainlink function call our alpaca account(bank) to do the following:
    // 1. sell TSLA on the brokerage
    // 2.buy USDC on the brokerage
    // 3. send USDC back to this contract for the user to withdraw
    function sendRedeemRequest(uint256 amountdTslaToSell) external {
        uint256 amountdTsalInUsdc = getUsdcValueOfUsd(getUsdValueOfTsla(amountdTslaToSell));
        if (amountdTsalInUsdc < MINIMUM_WITHDRAWL_AMOUNT) {
            revert dTSLA__DoesntMeetMinimumWithdrawlAMount();
        }

        FunctionsRequest.Request memory req;
        req.initializeRequestForInlineJavaScript(s_redeemSourceCode);

        string[] memory args = new string[](2);
        args[0] = amountdTslaToSell.toString(); //sell this much dTSLA
        args[1] = amountdTsalInUsdc.toString(); // send back this much usdc to this smart contract
        req.setArgs(args); // this way we can send additional information with the request

        bytes32 requestId = _sendRequest(req.encodeCBOR(), i_subId, GAS_LIMIT, DON_ID);
        s_requestIdToRequest[requestId] = dTslaRequest(amountdTslaToSell, msg.sender, MintOrRedeem.redeem);
        s_mostRecentRequestId = requestId;

        _burn(msg.sender, amountdTslaToSell);
    }

    function _redeemFulfillRequest(bytes32 requestId, bytes memory response) internal {
        // assume that the token always has 18 decimals. If not, in future we can add a mechanism to check the decimals of the token and adjust it to match 18 decimals
        uint256 usdcAmount = uint256(bytes32(response));
        // below is a kind of refund mechanism
        if (usdcAmount == 0) {
            uint256 amountOfdTSLABurned = s_requestIdToRequest[requestId].amountOfToken;
            _mint(s_requestIdToRequest[requestId].requester, amountOfdTSLABurned);
            return;
        }

        s_userToWithdrawlAMount[s_requestIdToRequest[requestId].requester] += usdcAmount;
    }

    function withdraw() external {
        uint256 amountToWithdraw = s_userToWithdrawlAMount[msg.sender];
        s_userToWithdrawlAMount[msg.sender] = 0;

        bool success = ERC20(0xAF0d217854155ea67D583E4CB5724f7caeC3Dc87).transfer(msg.sender, amountToWithdraw);
        if (!success) {
            revert dTSLA__FailedToWithdraw();
        }
    }

    // whenever a chainlink oracle calls back to a contract, it hits 'handleOracleFulfillment' function which calls 'fulfillRequest' function(hence this needs to be internal)
    // doing this conditional statement is very gas inefficient, therefore when this code should be sent for production, we will need to have 2 different smart contracts for mint and redeem.
    // but because we are not doing redeem here yet, we can just focus on mint part.
    function fulfillRequest(bytes32 requestId, bytes memory response, bytes memory /*err*/ ) internal override {
        // if(s_requestIdToRequest[requestId].mintOrRedeem == MintOrRedeem.mint){
        //     _mintFulfillRequest(requestId, response);
        // } else {
        //     _redeemFulfillRequest(requestId, response);
        // }
        s_portfolioBalance = uint256(bytes32(response));
    }

    function finishMint() external onlyOwner {
        uint256 amountOfTokensToMint = s_requestIdToRequest[s_mostRecentRequestId].amountOfToken;
        if (_getCollateralRatioAdjustedTotalBalance(amountOfTokensToMint) > s_portfolioBalance) {
            revert dTSLA__NotEnoughCollateral();
        }
        _mint(s_requestIdToRequest[s_mostRecentRequestId].requester, amountOfTokensToMint);
    }

    function _getCollateralRatioAdjustedTotalBalance(uint256 amountOfTokensToMint) internal view returns (uint256) {
        uint256 calculatedNewTotalValue = getCalculatedNewTotalValue(amountOfTokensToMint);
        return ((calculatedNewTotalValue * COLLATERAL_RATIO) / COLLATERAL_PRECISION);
    }

    // get new expected total value in USD of all the dTSLA tokens combined
    function getCalculatedNewTotalValue(uint256 addedNumberOfTokens) internal view returns (uint256) {
        // 10 tsla tokens + 5 tsla tokens = 15 tsla tokens * ($100) = $1500 --> min balance in custodian bank account
        return ((totalSupply() + addedNumberOfTokens) * getTslaPrice()) / PRECISION;
    }

    function getUsdcValueOfUsd(uint256 usdAmount) public view returns (uint256) {
        return (usdAmount * getUsdcPrice()) / PRECISION;
    }

    function getUsdValueOfTsla(uint256 tslaAmount) public view returns (uint256) {
        return (tslaAmount * getTslaPrice()) / PRECISION;
    }

    function getTslaPrice() public view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(SEPOLIA_TSLA_PRICE_FEED);
        (, int256 price,,,) = priceFeed.latestRoundData();
        return (uint256(price) * ADDITIONAL_FEED_PRECISION); // to get 18 decimal places
    }

    function getUsdcPrice() public view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(SEPOLIA_USDC_PRICE_FEED);
        (, int256 price,,,) = priceFeed.latestRoundData();
        return (uint256(price) * ADDITIONAL_FEED_PRECISION); // to get 18 decimal places
    }

    //////////////////////////
    // VIEW AND PURE /////////
    //////////////////////////

    function getRequest(bytes32 requestId) public view returns (dTslaRequest memory) {
        return s_requestIdToRequest[requestId];
    }

    function getPendingWithdrawlAmount(address user) public view returns (uint256) {
        return s_userToWithdrawlAMount[user];
    }

    function getPortfolioBalance() public view returns (uint256) {
        return s_portfolioBalance;
    }

    function getSubId() public view returns (uint256) {
        return i_subId;
    }

    function getMintSourceCode() public view returns (string memory) {
        return s_mintSourceCode;
    }

    function getRedeemSourceCode() public view returns (string memory) {
        return s_redeemSourceCode;
    }
}

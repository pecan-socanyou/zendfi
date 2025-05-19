// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import "lib/openzeppelin-contracts/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "lib/openzeppelin-contracts/contracts/security/ReentrancyGuard.sol";
import "lib/openzeppelin-contracts/contracts/access/Ownable2Step.sol";
import "./OptionFactory.sol";

/**
 * @title PhysicallySettledCallOptionLoanCoordinator
 * @notice Coordinates collateralized loans using physically settled call options
 * @dev Main workflow:
 * 1. Borrower deposits collateral (e.g. WETH) and requests loan by specifying:
 *    - Collateral amount and token
 *    - Strike price (determines maximum loan value)
 *    - Expiry timestamp
 * 2. Creates RFQ in OptionFactory for lenders to bid with settlement tokens (e.g. USDC)
 *    - Loan amount is market-driven through competitive bidding
 *    - Expected amount = (collateral * strike) - option premium - lending cost
 *    - Fees: configurable fee currently 6bps to factory, configurable fee to coordinator capped at 10bps, both taken from loan amount
 * 3. When bid accepted, creates loan handler that:
 *    - Transfers settlement tokens to borrower (minus fees)
 *    - Creates physically settled call option
 *    - Moves collateral to option contract
 * 4. At expiry:
 *    - If option not exercised, lender keeps the collateral
 *    - If exercised, borrower reclaims collateral by paying strike price
 */
contract PhysicallySettledCallOptionLoanCoordinator is ReentrancyGuard, Ownable2Step {
    using SafeERC20 for IERC20;

    // Immutable addresses
    address public immutable optionFactory;
    address public immutable callOptionImplementation;
    address public immutable loanHandlerImplementation;

    // Fee amount in basis points
    uint256 public fee;
    uint256 public constant MAX_FEE = 10; // 0.1%

    /**
     * @notice Configuration for an approved asset combination
     * @param collateralToken Token that can be used as collateral (e.g. WETH)
     * @param priceFeed Chainlink price feed for collateral/USD
     * @param settlementToken Token used for loan settlement (e.g. USDC)
     * @param isActive Whether this asset combination is currently approved
     */
    struct AssetConfig {
        address collateralToken;
        address priceFeed;
        address settlementToken;
        bool isActive;
    }

    // Mapping to track approved asset combinations
    mapping(bytes32 => AssetConfig) public assetConfigs;

    // Events
    event AssetConfigAdded(address indexed collateralToken, address indexed priceFeed, address indexed settlementToken);
    event AssetConfigRemoved(
        address indexed collateralToken, address indexed priceFeed, address indexed settlementToken
    );

    /**
     * @notice Details of an active loan request
     * @param requester Address that requested the loan
     * @param collateralAmount Amount of collateral token deposited
     * @param strike Strike price for the call option
     * @param expiryTimestamp When the option expires
     * @param collateralToken Token used as collateral
     * @param settlementToken Token requested for loan
     * @param isSettled Whether loan has been settled or cancelled
     */
    struct LoanRequest {
        address requester;
        uint256 collateralAmount;
        uint256 strike;
        uint256 expiryTimestamp;
        address collateralToken;
        address settlementToken;
        bool isSettled;
        address settledOptionContract;
    }

    // Mapping from request ID to loan details
    mapping(uint256 => LoanRequest) public loanRequests; // quotationId => LoanRequest

    // Events
    event LoanRequested(
        uint256 indexed quotationId,
        address indexed requester,
        address collateralToken,
        address settlementToken,
        uint256 collateralAmount,
        uint256 minSettlementAmount,
        uint256 strike,
        uint256 expiryTimestamp,
        uint256 offerEndTimestamp,
        bool convertToLimitOrder
    );
    event FeeCollected(uint256 indexed quotationId, uint256 feeAmount);

    /**
     * @notice Parameters for requesting a new loan
     * @param collateralToken Token to deposit as collateral
     * @param priceFeed Price feed for collateral valuation
     * @param settlementToken Token requested for loan
     * @param collateralAmount Amount of collateral to deposit
     * @param strike Strike price for the call option - determines maximum potential loan value
     *        Loan amount will be market-driven but approximately:
     *        (collateral * strike) - option premium - lending cost
     * @param expiryTimestamp When the option expires. Borrower has one hour grace period
     *                        to return the loan, otherwise, lender keeps the collateral
     * @param offerEndTimestamp When RFQ bidding period ends
     * @param minSettlementAmount Minimum acceptable loan amount
     * @param convertToLimitOrder Whether to convert the RFQ to a limit order
     * @param requesterPublicKey Key for encrypted communication
     */
    struct LoanRequestParams {
        address collateralToken;
        address priceFeed;
        address settlementToken;
        uint256 collateralAmount;
        uint256 strike;
        uint256 expiryTimestamp;
        uint256 offerEndTimestamp;
        uint256 minSettlementAmount;
        bool convertToLimitOrder;
        string requesterPublicKey;
    }

    // Add mapping to track total collateral locked for each token
    mapping(address => uint256) public totalLockedCollateral;

    constructor(
        address _optionFactory,
        address _callOptionImplementation,
        address _loanHandlerImplementation,
        uint256 _fee
    ) {
        optionFactory = _optionFactory;
        callOptionImplementation = _callOptionImplementation;
        loanHandlerImplementation = _loanHandlerImplementation;
        fee = _fee;
    }

    /**
     * @notice Add or update an approved asset configuration
     * @param collateralToken The collateral token address
     * @param priceFeed The Chainlink price feed address
     * @param settlementToken The settlement token address
     */
    function setAssetConfig(address collateralToken, address priceFeed, address settlementToken) external onlyOwner {
        require(collateralToken != address(0), "Invalid collateral token");
        require(priceFeed != address(0), "Invalid price feed");
        require(settlementToken != address(0), "Invalid settlement token");

        bytes32 configId = keccak256(abi.encode(collateralToken, priceFeed, settlementToken));

        assetConfigs[configId] = AssetConfig({
            collateralToken: collateralToken,
            priceFeed: priceFeed,
            settlementToken: settlementToken,
            isActive: true
        });

        emit AssetConfigAdded(collateralToken, priceFeed, settlementToken);
    }

    /**
     * @notice Remove an approved asset configuration
     */
    function removeAssetConfig(address collateralToken, address priceFeed, address settlementToken)
        external
        onlyOwner
    {
        bytes32 configId = keccak256(abi.encode(collateralToken, priceFeed, settlementToken));
        require(assetConfigs[configId].isActive, "Config not active");

        assetConfigs[configId].isActive = false;

        emit AssetConfigRemoved(collateralToken, priceFeed, settlementToken);
    }

    /**
     * @notice Request a USDC loan against WETH collateral
     * @param params Struct containing all loan request parameters
     * @return quotationId The ID of the created quotation
     */
    function requestLoan(LoanRequestParams calldata params) external nonReentrant returns (uint256 quotationId) {
        // Verify asset config is approved
        bytes32 configId = keccak256(abi.encode(params.collateralToken, params.priceFeed, params.settlementToken));
        require(assetConfigs[configId].isActive, "Asset config not approved");

        // Transfer collateral from requester
        IERC20(params.collateralToken).safeTransferFrom(msg.sender, address(this), params.collateralAmount);

        // Update locked collateral tracking
        totalLockedCollateral[params.collateralToken] += params.collateralAmount;

        {
            // Calculate settlement amount based on strike price
            uint256 settlementAmount = (
                params.collateralAmount * params.strike * (10 ** IERC20Metadata(params.settlementToken).decimals())
            ) / (10 ** IERC20Metadata(params.collateralToken).decimals()) / 1e8;

            uint256 numContracts = settlementAmount * 1e8 / params.strike;

            // Get next quotation ID
            uint256 nextQuotationId = OptionFactory(optionFactory).getQuotationCount();

            // Convert BaseOption.OptionParams to OptionFactory.QuotationParameters
            OptionFactory.QuotationParameters memory quotationParams = OptionFactory.QuotationParameters({
                requester: address(0), // Will be set by RFQ
                existingOptionAddress: address(0),
                collateral: params.settlementToken,
                collateralPriceFeed: params.priceFeed,
                implementation: loanHandlerImplementation,
                strikes: _createSingleElementArray(params.strike),
                numContracts: numContracts,
                requesterDeposit: 0, // No deposit needed since we're the seller
                collateralAmount: settlementAmount,
                expiryTimestamp: params.expiryTimestamp,
                offerEndTimestamp: params.offerEndTimestamp,
                isRequestingLongPosition: false, // We're the seller
                convertToLimitOrder: params.convertToLimitOrder,
                extraOptionData: abi.encode(address(this), nextQuotationId)
            });

            // Create tracking info for off-chain integration rewards
            OptionFactory.QuotationTracking memory tracking =
                OptionFactory.QuotationTracking({referralId: 0, eventCode: 0});

            // Request quotation from factory
            quotationId = OptionFactory(optionFactory).requestForQuotation(
                quotationParams,
                tracking,
                params.minSettlementAmount, // Minimum USDC bid to accept
                params.requesterPublicKey // Allow requester to decode offers
            );

            // Ensure the quotation ID is the next one in the sequence
            require(quotationId == nextQuotationId, "Unexpected quotation ID");
        }

        // Store loan request details
        loanRequests[quotationId] = LoanRequest({
            requester: msg.sender,
            collateralAmount: params.collateralAmount,
            strike: params.strike,
            expiryTimestamp: params.expiryTimestamp,
            collateralToken: params.collateralToken,
            settlementToken: params.settlementToken,
            isSettled: false,
            settledOptionContract: address(0)
        });

        emit LoanRequested(
            quotationId,
            msg.sender,
            params.collateralToken,
            params.settlementToken,
            params.collateralAmount,
            params.minSettlementAmount,
            params.strike,
            params.expiryTimestamp,
            params.offerEndTimestamp,
            params.convertToLimitOrder
        );
    }

    /**
     * @notice Handle settlement callback from loan handler
     * @dev Only callable by a loan handler created by the factory for a valid quotation
     * @param quotationId The ID of the quotation being settled
     * @return requester The address of the original loan requester
     * @return settlementAmount The final settlement amount paid by the winning bidder
     */
    function handleSettlement(uint256 quotationId, address settledOptionContract)
        external
        nonReentrant
        returns (address requester, uint256 settlementAmount, address collateralToken, uint256 collateralAmount)
    {
        // Get quotation details from factory
        (, OptionFactory.QuotationState memory state) = OptionFactory(optionFactory).quotations(quotationId);

        require(!state.isActive, "RFQ not settled");
        require(state.optionContract == msg.sender, "Invalid handler");

        LoanRequest storage request = loanRequests[quotationId];
        require(!request.isSettled, "Already settled");

        // Calculate fee on the winning premium
        uint256 premiumAfterOptionFactoryFee = state.currentBestPriceOrReserve - state.feeCollected;
        uint256 feeAmount = (premiumAfterOptionFactoryFee * fee) / 10000;
        uint256 netPremium = premiumAfterOptionFactoryFee - feeAmount;

        // Mark as settled (Effect)
        request.isSettled = true;

        // Store the actual option contract address (Effect)
        request.settledOptionContract = settledOptionContract;

        // Update state tracking (Effect)
        totalLockedCollateral[request.collateralToken] -= request.collateralAmount;

        // External interactions last
        if (netPremium > 0) {
            IERC20(request.settlementToken).safeTransfer(request.requester, netPremium);
        }

        // Emit fee collection event
        if (feeAmount > 0) {
            emit FeeCollected(quotationId, feeAmount);
        }

        // Transfer collateral to handler (Interaction)
        IERC20(request.collateralToken).safeTransfer(msg.sender, request.collateralAmount);

        return (request.requester, state.currentBestPriceOrReserve, request.collateralToken, request.collateralAmount);
    }

    /**
     * @notice Cancel a loan request if RFQ hasn't been settled
     * @param quotationId The ID of the loan request to cancel
     */
    function cancelLoan(uint256 quotationId) external nonReentrant {
        LoanRequest storage request = loanRequests[quotationId];
        require(msg.sender == request.requester, "Not requester");
        require(!request.isSettled, "Already settled");

        // Update state first (Effects)
        request.isSettled = true;
        totalLockedCollateral[request.collateralToken] -= request.collateralAmount;

        // Then external interactions
        OptionFactory(optionFactory).cancelQuotation(quotationId);
        IERC20(request.collateralToken).safeTransfer(request.requester, request.collateralAmount);
    }

    /**
     * @notice Settle a quotation early if a satisfactory offer is received
     * @param quotationId The ID of the quotation to settle
     * @param offerAmount The amount of the offer
     * @param nonce The nonce used in the offer
     * @param offeror The address of the offeror
     */
    function settleQuotationEarly(uint256 quotationId, uint256 offerAmount, uint64 nonce, address offeror) external {
        LoanRequest storage request = loanRequests[quotationId];
        require(msg.sender == request.requester, "Not requester");
        require(!request.isSettled, "Already settled");

        OptionFactory(optionFactory).settleQuotationEarly(quotationId, offerAmount, nonce, offeror);
    }

    /**
     * @notice Set the fee rate
     * @param _fee New fee in basis points
     */
    function setFee(uint256 _fee) external onlyOwner {
        require(_fee <= MAX_FEE, "Fee exceeds maximum");
        fee = _fee;
    }

    /**
     * @notice Rescue any tokens accidentally sent to this contract
     * @param token The token to rescue
     * @param amount The amount to rescue
     */
    function rescueToken(address token, uint256 amount) external nonReentrant onlyOwner {
        uint256 lockedAmount = totalLockedCollateral[token];
        uint256 balance = IERC20(token).balanceOf(address(this));

        require(balance >= lockedAmount + amount, "Cannot rescue collateral needed for active loans");

        IERC20(token).safeTransfer(owner(), amount);
    }

    // Helper functions

    function _createSingleElementArray(uint256 element) internal pure returns (uint256[] memory) {
        uint256[] memory arr = new uint256[](1);
        arr[0] = element;
        return arr;
    }
}

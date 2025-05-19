// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "./BaseOption.sol";
import "./PhysicallySettledCallOption.sol";
import "lib/openzeppelin-contracts/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import "lib/openzeppelin-contracts/contracts/proxy/Clones.sol";
import "./PhysicallySettledCallOptionLoanCoordinator.sol";

/**
 * @title PhysicallySettledCallOptionLoanHandler
 * @notice Handles settlement of loans by creating physically settled call options
 * @dev Created by OptionFactory when RFQ is settled. Main responsibilities:
 * 1. Retrieve collateral from coordinator
 * 2. Create new physically settled call option contract
 * 3. Initialize option with:
 *    - Borrower as option buyer (can reclaim collateral by paying strike)
 *    - Lender as option seller (keeps collateral if option expires unexercised)
 *    - Collateral moved to option contract
 *
 * Economic Model:
 * - Borrower deposits collateral and sets strike price
 * - Lenders compete to offer best loan amount
 * - Loan amount = (collateral * strike) - option premium - lending cost
 * - Fees (taken from loan amount):
 *   - configurable fee to OptionFactory, currently 6bps
 *   - configurable fee to Coordinator capped at 10bps
 */
contract PhysicallySettledCallOptionLoanHandler is BaseOption {
    using SafeERC20 for IERC20;
    using Clones for address;

    address public actualPhysicallySettledCallOption;

    // Events
    /**
     * @notice Event emitted when loan is settled and option created
     * @param coordinator Address of loan coordinator
     * @param requester Original borrower who deposited collateral
     * @param finalOption Address of created call option contract
     * @param collateralToken Token used as collateral (e.g. WETH)
     * @param settlementToken Token used for loan (e.g. USDC)
     * @param collateralAmount Amount of collateral
     * @param settlementAmount Final loan amount (after fees)
     * @param quotationId Reference ID of original loan request
     */
    event LoanSettled(
        address indexed coordinator,
        address indexed requester,
        address indexed finalOption,
        address collateralToken,
        address settlementToken,
        uint256 collateralAmount,
        uint256 settlementAmount,
        uint256 quotationId
    );

    // Option type bit layout: 0xABCD
    // A: 4 (Loan Handler) - bits 12-15
    // B: 1 (Quote collateral - Settlement token) - bits 8-11
    // C: 1 (Physical settlement) - bits 4-7
    // D: 0 (Call) - bits 0-3
    function optionType() public pure override returns (uint256) {
        return (4 << OPTION_STRUCTURE_SHIFT) // Loan handler type
            | (1 << COLLATERAL_CURRENCY_SHIFT) // Quote collateral (Settlement token)
            | (1 << SETTLEMENT_METHOD_SHIFT) // Physical settlement
            | 0; // Call style
    }

    /**
     * @notice Initializes the loan handler and creates the final physically settled call option.
     * @dev Expects the extraOptionData to be encoded as:
     *      abi.encode(
     *          address coordinator,          // Address of the PhysicallySettledCallOptionLoanCoordinator
     *          address finalImplementation,  // Address of the PhysicallySettledCallOption implementation
     *          uint256 collateralAmount,    // Amount of collateral to be used
     *          uint256 quotationId          // ID of the quotation in the coordinator
     *      )
     * @param params The option parameters from the factory, including:
     *        - collateralToken: The settlement token address (e.g. USDC)
     *        - chainlinkPriceFeed: The price feed for the collateral asset
     *        - buyer: The original requester who deposited collateral
     *        - seller: The winning bidder who offered settlement tokens
     */
    function initialize(OptionParams memory params) public override {
        require(actualPhysicallySettledCallOption == address(0), "Already initialized");

        // Decode extra option data
        (address coordinator, uint256 quotationId) = abi.decode(params.extraOptionData, (address, uint256));

        address finalImplementation = PhysicallySettledCallOptionLoanCoordinator(coordinator).callOptionImplementation();

        // Create and initialize the final physically settled call option
        address finalOption = finalImplementation.clone();

        // Call coordinator to handle settlement
        // This will:
        // 1. Verify this handler was created by the factory for the correct RFQ
        // 2. Transfer USDC to requester (minus fees)
        // 3. Transfer WETH to this contract
        (address requester, uint256 settlementAmount, address collateralToken, uint256 collateralAmount) =
            PhysicallySettledCallOptionLoanCoordinator(coordinator).handleSettlement(quotationId, finalOption);

        // Store the actual implementation's deployed proxy address
        actualPhysicallySettledCallOption = finalOption;

        // Approve collateral transfer to final option
        IERC20(collateralToken).approve(finalOption, collateralAmount);

        // Initialize final option with normalized parameters
        BaseOption(finalOption).initialize(
            BaseOption.OptionParams({
                collateralToken: collateralToken,
                chainlinkPriceFeed: params.chainlinkPriceFeed,
                historicalTWAPConsumer: params.historicalTWAPConsumer,
                buyer: requester, // Original requester from coordinator
                seller: params.buyer, // Winning bidder from RFQ
                strikes: params.strikes,
                expiryTimestamp: params.expiryTimestamp,
                twapPeriod: params.twapPeriod,
                numContracts: collateralAmount,
                rescueAddress: params.rescueAddress,
                factoryAddress: params.factoryAddress,
                collateralAmount: collateralAmount,
                extraOptionData: abi.encode(params.collateralToken)
            })
        );

        emit LoanSettled(
            coordinator,
            requester,
            finalOption,
            collateralToken,
            params.collateralToken,
            collateralAmount,
            settlementAmount,
            quotationId
        );
    }

    /**
     * @notice Validates the option parameters
     * @dev Ensures that exactly one strike price is provided
     *      This is used by both the loan handler and the final option
     * @param _strikes An array of strike prices
     */
    function validateParams(uint256[] memory _strikes) public pure override {
        require(_strikes.length == 1, "Loan handler must have exactly one strike price");
    }

    /**
     * @notice Calculates the required collateral for the option
     * @dev For the loan handler, this always returns 0 since collateral (settlement token)
     *      is handled through the RFQ process. This ensures the factory doesn't try to
     *      transfer any tokens during initialization.
     */
    function calculateRequiredCollateral(uint256[] memory, uint256) public pure override returns (uint256) {
        return 0;
    }

    // Override functions that should not be available for the loan handler
    function split(uint256) external pure override returns (address) {
        revert("Loan handler cannot be split");
    }

    function transfer(bool, address) external pure override {
        revert("Loan handler cannot be transferred");
    }

    /**
     * @dev Overrides the internal settlement attempt.
     *      Loan handler does not have option settlement, so will never revert for rescueERC20
     */
    function _attemptSettlement(address) internal pure override {
        return;
    }
}

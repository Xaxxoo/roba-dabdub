// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "./interfaces/IUserWallet.sol";

/**
 * @title CheeseVault
 * @notice Stablecoin vault for bill payments with role-based access control
 * @dev Users deposit USDC, backend processes payments, treasurer withdraws processed funds
 */
contract CheeseVault is ReentrancyGuard, Pausable, AccessControl {
    // ========== STATE VARIABLES ==========

    // Roles
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");
    bytes32 public constant TREASURER_ROLE = keccak256("TREASURER_ROLE");

    // Token
    IERC20 public immutable usdc;

    // Payment tracking
    uint256 public availableProcessedPayments;
    uint256 public totalPaymentsProcessed;

    // Fee tracking
    uint256 public availableFees;
    uint256 public totalFeesCollected;
    uint256 public feeAmount; // Flat fee per transaction
    uint256 public constant MAX_FEE = 5e6; // $5 in USDC (6 decimals)

    // Settings
    uint256 public minDeposit; // Minimum deposit amount

    // ========== EVENTS ==========

    event Deposit(address indexed user, uint256 amount, uint256 newBalance);

    event Withdrawal(address indexed user, uint256 amount, uint256 remainingBalance);

    event PaymentProcessed(
        address indexed userWallet,
        bytes32 indexed paymentId,
        uint256 paymentAmount,
        uint256 feeAmount,
        uint256 remainingBalance
    );

    event PaymentRefunded(
        address indexed userWallet, bytes32 indexed paymentId, uint256 refundAmount, uint256 newBalance
    );

    event VaultFundsWithdrawn(
        address indexed treasurer, address indexed to, uint256 paymentsAmount, uint256 feesAmount, uint256 totalAmount
    );

    event FeeUpdated(uint256 oldFee, uint256 newFee);

    event MinDepositUpdated(uint256 oldMinDeposit, uint256 newMinDeposit);

    event EmergencyWithdrawal(address indexed user, uint256 amount);

    // ========== CONSTRUCTOR ==========

    /**
     * @notice Initialize the vault with USDC address and initial settings
     * @param _usdc Address of USDC token contract
     * @param _feeAmount Initial flat fee amount (must be <= MAX_FEE)
     * @param _minDeposit Minimum deposit amount
     */
    constructor(address _usdc, uint256 _feeAmount, uint256 _minDeposit) {
        require(_usdc != address(0), "Invalid USDC address");
        require(_feeAmount <= MAX_FEE, "Fee exceeds maximum");

        usdc = IERC20(_usdc);
        feeAmount = _feeAmount;
        minDeposit = _minDeposit;

        // Grant deployer the default admin role (can assign other roles)
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
    }

    // ========== OPERATOR FUNCTIONS ==========

    /**
     * @notice Process a payment (pulls USDC from UserWallet automatically)
     * @param userWallet Address of the UserWallet contract
     * @param paymentAmount Amount for the actual payment (excluding fee)
     * @param paymentId Unique identifier for this payment
     */
    function processPayment(address userWallet, uint256 paymentAmount, bytes32 paymentId)
        external
        onlyRole(OPERATOR_ROLE)
        nonReentrant
        whenNotPaused
    {
        require(paymentAmount > 0, "Payment amount must be greater than 0");
        require(userWallet != address(0), "Invalid wallet address");

        // Update payment tracking
        availableProcessedPayments += paymentAmount;
        totalPaymentsProcessed += paymentAmount;

        // Update fee tracking
        availableFees += feeAmount;
        totalFeesCollected += feeAmount;

        // Call UserWallet to transfer funds to vault
        // This will transfer paymentAmount + feeAmount to this vault
        uint256 totalAmount = IUserWallet(userWallet).transferToVault(paymentAmount);

        // Verify we received the funds
        // The totalAmount should equal paymentAmount + feeAmount
        require(totalAmount == paymentAmount + feeAmount, "Incorrect amount transferred");

        emit PaymentProcessed(userWallet, paymentId, paymentAmount, feeAmount, 0);
    }

    // ========== ADMIN FUNCTIONS ==========

    /**
     * @notice Refund a failed payment to user's wallet
     * @param userWallet Address of the UserWallet contract
     * @param paymentAmount Original payment amount (excluding fee)
     * @param refundFee Whether to refund the fee as well
     * @param paymentId Payment identifier for tracking
     */
    function refundPayment(address userWallet, uint256 paymentAmount, bool refundFee, bytes32 paymentId)
        external
        onlyRole(ADMIN_ROLE)
        nonReentrant
        whenNotPaused
    {
        require(paymentAmount > 0, "Refund amount must be greater than 0");
        require(userWallet != address(0), "Invalid wallet address");

        uint256 refundAmount = paymentAmount;

        // Refund payment amount
        require(availableProcessedPayments >= paymentAmount, "Insufficient processed payments to refund");
        availableProcessedPayments -= paymentAmount;

        // Optionally refund fee
        if (refundFee) {
            require(availableFees >= feeAmount, "Insufficient fees to refund");
            availableFees -= feeAmount;
            refundAmount += feeAmount;
        }

        // Send USDC back to UserWallet
        require(usdc.transfer(userWallet, refundAmount), "Refund transfer failed");

        emit PaymentRefunded(userWallet, paymentId, refundAmount, 0);
    }

    /**
     * @notice Update the flat fee amount
     * @param newFee New fee amount (must be <= MAX_FEE)
     */
    function setFee(uint256 newFee) external onlyRole(ADMIN_ROLE) {
        require(newFee <= MAX_FEE, "Fee exceeds maximum");

        uint256 oldFee = feeAmount;
        feeAmount = newFee;

        emit FeeUpdated(oldFee, newFee);
    }

    /**
     * @notice Update the minimum deposit amount
     * @param newMinDeposit New minimum deposit amount
     */
    function setMinDeposit(uint256 newMinDeposit) external onlyRole(ADMIN_ROLE) {
        uint256 oldMinDeposit = minDeposit;
        minDeposit = newMinDeposit;

        emit MinDepositUpdated(oldMinDeposit, newMinDeposit);
    }

    /**
     * @notice Pause the contract (emergency stop)
     */
    function pause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _pause();
    }

    /**
     * @notice Unpause the contract
     */
    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _unpause();
    }

    // ========== TREASURER FUNCTIONS ==========

    /**
     * @notice Withdraw processed payments and fees from vault
     * @param to Address to send the funds to
     */
    function withdrawVaultFunds(address to) external onlyRole(TREASURER_ROLE) nonReentrant {
        require(to != address(0), "Invalid recipient address");

        uint256 paymentsToWithdraw = availableProcessedPayments;
        uint256 feesToWithdraw = availableFees;
        uint256 totalToWithdraw = paymentsToWithdraw + feesToWithdraw;

        require(totalToWithdraw > 0, "No funds available to withdraw");

        // Update available amounts
        availableProcessedPayments = 0;
        availableFees = 0;

        // Transfer USDC to recipient
        require(usdc.transfer(to, totalToWithdraw), "USDC transfer failed");

        emit VaultFundsWithdrawn(msg.sender, to, paymentsToWithdraw, feesToWithdraw, totalToWithdraw);
    }

    // ========== VIEW FUNCTIONS ==========

    /**
     * @notice Get available funds that can be withdrawn by treasurer
     * @return payments Available processed payments
     * @return fees Available fees
     * @return total Total available for withdrawal
     */
    function getAvailableWithdrawal() external view returns (uint256 payments, uint256 fees, uint256 total) {
        payments = availableProcessedPayments;
        fees = availableFees;
        total = payments + fees;
    }

    /**
     * @notice Verify vault accounting is correct
     * @return isValid True if vault balance >= available withdrawals
     */
    function verifyVaultAccounting() external view returns (bool isValid) {
        uint256 vaultBalance = usdc.balanceOf(address(this));
        uint256 requiredBalance = availableProcessedPayments + availableFees;
        return vaultBalance >= requiredBalance;
    }
}

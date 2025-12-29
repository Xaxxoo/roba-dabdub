// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "./interfaces/ICheeseVault.sol";

/**
 * @title UserWallet
 * @notice Individual wallet contract for each user to hold USDC
 * @dev Controlled by backend for payments, user can set owner for recovery
 */
contract UserWallet is ReentrancyGuard {
    // ========== STATE VARIABLES ==========

    address public backend;
    address public owner; // User's recovery address
    ICheeseVault public vault;
    IERC20 public immutable usdc;

    // ========== EVENTS ==========

    event TransferredToVault(uint256 paymentAmount, uint256 feeAmount, uint256 totalAmount, uint256 timestamp);

    event Withdrawal(address indexed recipient, uint256 amount, uint256 timestamp);

    event OwnerUpdated(address indexed oldOwner, address indexed newOwner);

    event EmergencyWithdrawal(uint256 amount, uint256 timestamp);

    // ========== MODIFIERS ==========

    modifier onlyBackend() {
        require(msg.sender == backend, "Only backend");
        _;
    }

    modifier onlyOwner() {
        require(msg.sender == owner, "Only owner");
        require(owner != address(0), "Owner not set");
        _;
    }

    modifier onlyBackendOrOwner() {
        require(msg.sender == backend || msg.sender == owner, "Not authorized");
        _;
    }

    modifier onlyBackendOrVault() {
        require(msg.sender == backend || msg.sender == address(vault), "Not authorized");
        _;
    }

    // ========== CONSTRUCTOR ==========

    constructor(address _backend, address _vault, address _usdc, address _owner) {
        require(_backend != address(0), "Invalid backend");
        require(_vault != address(0), "Invalid vault");
        require(_usdc != address(0), "Invalid USDC");

        backend = _backend;
        vault = ICheeseVault(_vault);
        usdc = IERC20(_usdc);
        owner = _owner; // initially address(0)
    }

    // ========== VIEW FUNCTIONS ==========

    /**
     * @notice Get USDC balance in this wallet
     * @return Current USDC balance
     */
    function getBalance() external view returns (uint256) {
        return usdc.balanceOf(address(this));
    }

    // ========== USER/BACKEND FUNCTIONS ==========

    /**
     * @notice Transfer USDC to vault for bill payment (includes fee automatically)
     * @param paymentAmount The bill amount (fee will be added)
     * @return totalAmount Total amount transferred (payment + fee)
     */
    function transferToVault(uint256 paymentAmount)
        external
        onlyBackendOrVault
        nonReentrant
        returns (uint256 totalAmount)
    {
        require(paymentAmount > 0, "Payment amount must be > 0");

        // Get current fee from vault
        uint256 feeAmount = vault.feeAmount();
        totalAmount = paymentAmount + feeAmount;

        // Check sufficient balance
        require(usdc.balanceOf(address(this)) >= totalAmount, "Insufficient balance");

        // Transfer to vault
        require(usdc.transfer(address(vault), totalAmount), "Transfer to vault failed");

        emit TransferredToVault(paymentAmount, feeAmount, totalAmount, block.timestamp);
    }

    /**
     * @notice Withdraw USDC from wallet
     * @param amount Amount to withdraw
     * @param recipient Address to receive USDC
     */
    function withdraw(uint256 amount, address recipient) external onlyBackendOrOwner nonReentrant {
        require(amount > 0, "Amount must be > 0");
        require(recipient != address(0), "Invalid recipient");
        require(usdc.balanceOf(address(this)) >= amount, "Insufficient balance");

        require(usdc.transfer(recipient, amount), "Withdrawal failed");

        emit Withdrawal(recipient, amount, block.timestamp);
    }

    /**
     * @notice Emergency withdraw all funds (only owner)
     * @dev Safety mechanism if backend is compromised
     */
    function emergencyWithdraw() external onlyOwner nonReentrant {
        uint256 balance = usdc.balanceOf(address(this));
        require(balance > 0, "No balance to withdraw");

        require(usdc.transfer(owner, balance), "Emergency withdrawal failed");

        emit EmergencyWithdrawal(balance, block.timestamp);
    }

    // ========== ADMIN FUNCTIONS ==========

    /**
     * @notice Set or update owner address
     * @param newOwner New owner address
     */
    function setOwner(address newOwner) external onlyBackend {
        address oldOwner = owner;
        owner = newOwner;

        emit OwnerUpdated(oldOwner, newOwner);
    }
}

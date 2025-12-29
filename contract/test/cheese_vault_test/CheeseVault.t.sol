// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../../src/CheeseVault.sol";
import "../../src/UserWallet.sol";
import "../../src/UserWalletFactory.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

// Mock USDC token for testing
contract MockUSDC is ERC20 {
    constructor() ERC20("USD Coin", "USDC") {
        _mint(msg.sender, 1000000 * 10 ** 6); // Mint 1M USDC
    }

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract CheeseVaultTest is Test {
    CheeseVault public vault;
    UserWalletFactory public factory;
    MockUSDC public usdc;

    // Test addresses
    address public owner;
    address public admin;
    address public operator;
    address public treasurer;
    address public user1;
    address public user2;

    // User wallets
    address public user1Wallet;
    address public user2Wallet;

    // Constants
    uint256 constant INITIAL_FEE = 0.5e6; // $0.50
    uint256 constant MIN_DEPOSIT = 1e6; // $1
    uint256 constant MAX_FEE = 5e6; // $5

    // Events to test
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

    function setUp() public {
        // Setup addresses
        owner = address(this);
        admin = makeAddr("admin");
        operator = makeAddr("operator");
        treasurer = makeAddr("treasurer");
        user1 = makeAddr("user1");
        user2 = makeAddr("user2");

        // Deploy mock USDC
        usdc = new MockUSDC();

        // Deploy vault
        vault = new CheeseVault(address(usdc), INITIAL_FEE, MIN_DEPOSIT);

        // Deploy factory
        factory = new UserWalletFactory(
            operator, // backend is operator
            address(vault),
            address(usdc)
        );

        // Assign roles
        vault.grantRole(vault.ADMIN_ROLE(), admin);
        vault.grantRole(vault.OPERATOR_ROLE(), operator);
        vault.grantRole(vault.TREASURER_ROLE(), treasurer);

        // Create user wallets
        vm.startPrank(operator);
        user1Wallet = factory.createWallet("user1@example.com");
        user2Wallet = factory.createWallet("user2@example.com");
        vm.stopPrank();

        // Give users some USDC and send to their wallets
        usdc.mint(user1, 1000e6);
        usdc.mint(user2, 1000e6);

        vm.prank(user1);
        usdc.transfer(user1Wallet, 500e6);

        vm.prank(user2);
        usdc.transfer(user2Wallet, 500e6);
    }

    // ========== DEPLOYMENT TESTS ==========

    function test_Deployment() public view {
        assertEq(address(vault.usdc()), address(usdc));
        assertEq(vault.feeAmount(), INITIAL_FEE);
        assertEq(vault.minDeposit(), MIN_DEPOSIT);
        assertEq(vault.MAX_FEE(), MAX_FEE);

        // Check roles
        assertTrue(vault.hasRole(vault.DEFAULT_ADMIN_ROLE(), owner));
        assertTrue(vault.hasRole(vault.ADMIN_ROLE(), admin));
        assertTrue(vault.hasRole(vault.OPERATOR_ROLE(), operator));
        assertTrue(vault.hasRole(vault.TREASURER_ROLE(), treasurer));
    }

    function test_RevertWhen_DeploymentWithInvalidUSDC() public {
        vm.expectRevert("Invalid USDC address");
        new CheeseVault(address(0), INITIAL_FEE, MIN_DEPOSIT);
    }

    function test_RevertWhen_DeploymentWithFeeExceedingMax() public {
        vm.expectRevert("Fee exceeds maximum");
        new CheeseVault(address(usdc), MAX_FEE + 1, MIN_DEPOSIT);
    }

    // ========== PROCESS PAYMENT TESTS ==========

    function test_ProcessPayment() public {
        uint256 paymentAmount = 50e6;
        bytes32 paymentId = keccak256("payment-001");

        // Just call processPayment - it handles everything!
        vm.prank(operator);
        vault.processPayment(user1Wallet, paymentAmount, paymentId);

        // Verify
        assertEq(vault.availableProcessedPayments(), paymentAmount);
        assertEq(vault.totalPaymentsProcessed(), paymentAmount);
        assertEq(vault.availableFees(), INITIAL_FEE);
        assertEq(vault.totalFeesCollected(), INITIAL_FEE);
    }

    function test_MultiplePayments() public {
        // First payment
        vm.prank(operator);
        UserWallet(payable(user1Wallet)).transferToVault(50e6);

        vm.prank(operator);
        vault.processPayment(user1Wallet, 50e6, keccak256("payment-001"));

        // Second payment
        vm.prank(operator);
        UserWallet(payable(user1Wallet)).transferToVault(30e6);

        vm.prank(operator);
        vault.processPayment(user1Wallet, 30e6, keccak256("payment-002"));

        // Verify cumulative tracking
        assertEq(vault.availableProcessedPayments(), 80e6);
        assertEq(vault.totalPaymentsProcessed(), 80e6);
        assertEq(vault.availableFees(), INITIAL_FEE * 2);
        assertEq(vault.totalFeesCollected(), INITIAL_FEE * 2);
    }

    function test_RevertWhen_ProcessPaymentNotOperator() public {
        vm.prank(user1);
        vm.expectRevert();
        vault.processPayment(user1Wallet, 50e6, keccak256("payment-001"));
    }

    function test_RevertWhen_ProcessPaymentZeroAmount() public {
        vm.prank(operator);
        vm.expectRevert("Payment amount must be greater than 0");
        vault.processPayment(user1Wallet, 0, keccak256("payment-001"));
    }

    function test_RevertWhen_ProcessPaymentInvalidWallet() public {
        vm.prank(operator);
        vm.expectRevert("Invalid wallet address");
        vault.processPayment(address(0), 50e6, keccak256("payment-001"));
    }

    // ========== REFUND PAYMENT TESTS ==========

    function test_RefundPaymentWithoutFee() public {
        // Process payment first
        vm.prank(operator);
        UserWallet(payable(user1Wallet)).transferToVault(50e6);

        bytes32 paymentId = keccak256("payment-001");
        vm.prank(operator);
        vault.processPayment(user1Wallet, 50e6, paymentId);

        uint256 user1WalletBalanceBefore = usdc.balanceOf(user1Wallet);

        // Refund without fee
        vm.prank(admin);
        vm.expectEmit(true, true, true, true);
        emit PaymentRefunded(user1Wallet, paymentId, 50e6, 0);

        vault.refundPayment(user1Wallet, 50e6, false, paymentId);

        assertEq(usdc.balanceOf(user1Wallet), user1WalletBalanceBefore + 50e6);
        assertEq(vault.availableProcessedPayments(), 0);
        assertEq(vault.totalPaymentsProcessed(), 50e6); // Cumulative doesn't change
    }

    function test_RefundPaymentWithFee() public {
        // Process payment
        vm.prank(operator);
        UserWallet(payable(user1Wallet)).transferToVault(50e6);

        bytes32 paymentId = keccak256("payment-001");
        vm.prank(operator);
        vault.processPayment(user1Wallet, 50e6, paymentId);

        uint256 user1WalletBalanceBefore = usdc.balanceOf(user1Wallet);

        // Refund with fee
        vm.prank(admin);
        vault.refundPayment(user1Wallet, 50e6, true, paymentId);

        uint256 totalRefund = 50e6 + INITIAL_FEE;
        assertEq(usdc.balanceOf(user1Wallet), user1WalletBalanceBefore + totalRefund);
        assertEq(vault.availableProcessedPayments(), 0);
        assertEq(vault.availableFees(), 0);
        assertEq(vault.totalPaymentsProcessed(), 50e6);
        assertEq(vault.totalFeesCollected(), INITIAL_FEE);
    }

    function test_RevertWhen_RefundPaymentNotAdmin() public {
        vm.prank(user1);
        vm.expectRevert();
        vault.refundPayment(user1Wallet, 50e6, false, keccak256("payment-001"));
    }

    function test_RevertWhen_RefundPaymentInsufficientProcessedPayments() public {
        vm.prank(admin);
        vm.expectRevert("Insufficient processed payments to refund");
        vault.refundPayment(user1Wallet, 50e6, false, keccak256("payment-001"));
    }

    // ========== WITHDRAW VAULT FUNDS TESTS ==========

    function test_WithdrawVaultFunds() public {
        // Process payment
        vm.prank(operator);
        UserWallet(payable(user1Wallet)).transferToVault(50e6);

        vm.prank(operator);
        vault.processPayment(user1Wallet, 50e6, keccak256("payment-001"));

        // Withdraw vault funds
        address recipient = makeAddr("recipient");

        vm.prank(treasurer);
        vm.expectEmit(true, true, true, true);
        emit VaultFundsWithdrawn(treasurer, recipient, 50e6, INITIAL_FEE, 50e6 + INITIAL_FEE);

        vault.withdrawVaultFunds(recipient);

        assertEq(vault.availableProcessedPayments(), 0);
        assertEq(vault.availableFees(), 0);
        assertEq(usdc.balanceOf(recipient), 50e6 + INITIAL_FEE);
    }

    function test_WithdrawVaultFundsMultiplePayments() public {
        // Process multiple payments
        vm.startPrank(operator);
        UserWallet(payable(user1Wallet)).transferToVault(50e6);
        vault.processPayment(user1Wallet, 50e6, keccak256("payment-001"));

        UserWallet(payable(user1Wallet)).transferToVault(30e6);
        vault.processPayment(user1Wallet, 30e6, keccak256("payment-002"));
        vm.stopPrank();

        // Withdraw
        address recipient = makeAddr("recipient");
        vm.prank(treasurer);
        vault.withdrawVaultFunds(recipient);

        uint256 expectedTotal = 80e6 + (INITIAL_FEE * 2);
        assertEq(usdc.balanceOf(recipient), expectedTotal);
    }

    function test_RevertWhen_WithdrawVaultFundsNotTreasurer() public {
        vm.prank(user1);
        vm.expectRevert();
        vault.withdrawVaultFunds(user1);
    }

    function test_RevertWhen_WithdrawVaultFundsToZeroAddress() public {
        vm.prank(treasurer);
        vm.expectRevert("Invalid recipient address");
        vault.withdrawVaultFunds(address(0));
    }

    function test_RevertWhen_WithdrawVaultFundsWhenEmpty() public {
        vm.prank(treasurer);
        vm.expectRevert("No funds available to withdraw");
        vault.withdrawVaultFunds(makeAddr("recipient"));
    }

    // ========== ADMIN FUNCTIONS TESTS ==========

    function test_SetFee() public {
        uint256 newFee = 1e6; // $1

        vm.prank(admin);
        vault.setFee(newFee);

        assertEq(vault.feeAmount(), newFee);
    }

    function test_RevertWhen_SetFeeExceedingMax() public {
        vm.prank(admin);
        vm.expectRevert("Fee exceeds maximum");
        vault.setFee(MAX_FEE + 1);
    }

    function test_RevertWhen_SetFeeNotAdmin() public {
        vm.prank(user1);
        vm.expectRevert();
        vault.setFee(1e6);
    }

    function test_SetMinDeposit() public {
        uint256 newMinDeposit = 10e6; // $10

        vm.prank(admin);
        vault.setMinDeposit(newMinDeposit);

        assertEq(vault.minDeposit(), newMinDeposit);
    }

    function test_RevertWhen_SetMinDepositNotAdmin() public {
        vm.prank(user1);
        vm.expectRevert();
        vault.setMinDeposit(10e6);
    }

    function test_Pause() public {
        vault.pause();
        assertTrue(vault.paused());
    }

    function test_Unpause() public {
        vault.pause();
        vault.unpause();
        assertFalse(vault.paused());
    }

    function test_RevertWhen_PauseNotOwner() public {
        vm.prank(user1);
        vm.expectRevert();
        vault.pause();
    }

    // ========== VIEW FUNCTIONS TESTS ==========

    function test_GetAvailableWithdrawal() public {
        // Process payment
        vm.prank(operator);
        UserWallet(payable(user1Wallet)).transferToVault(50e6);

        vm.prank(operator);
        vault.processPayment(user1Wallet, 50e6, keccak256("payment-001"));

        (uint256 payments, uint256 fees, uint256 total) = vault.getAvailableWithdrawal();

        assertEq(payments, 50e6);
        assertEq(fees, INITIAL_FEE);
        assertEq(total, 50e6 + INITIAL_FEE);
    }

    function test_VerifyVaultAccounting() public {
        assertTrue(vault.verifyVaultAccounting());

        // Process payment
        vm.prank(operator);
        UserWallet(payable(user1Wallet)).transferToVault(50e6);

        vm.prank(operator);
        vault.processPayment(user1Wallet, 50e6, keccak256("payment-001"));

        assertTrue(vault.verifyVaultAccounting());

        // Withdraw
        vm.prank(treasurer);
        vault.withdrawVaultFunds(makeAddr("recipient"));

        assertTrue(vault.verifyVaultAccounting());
    }

    // ========== INTEGRATION TESTS ==========

    function test_CompleteUserJourney() public {
        // 1. User pays a bill
        vm.prank(operator);
        UserWallet(payable(user1Wallet)).transferToVault(100e6);

        vm.prank(operator);
        vault.processPayment(user1Wallet, 100e6, keccak256("bill-electricity"));

        // 2. Payment fails, admin refunds
        vm.prank(admin);
        vault.refundPayment(user1Wallet, 100e6, true, keccak256("bill-electricity"));

        // 3. User pays another bill successfully
        vm.prank(operator);
        UserWallet(payable(user1Wallet)).transferToVault(50e6);

        vm.prank(operator);
        vault.processPayment(user1Wallet, 50e6, keccak256("bill-water"));

        // 4. Treasurer withdraws processed funds
        address companyWallet = makeAddr("company");
        vm.prank(treasurer);
        vault.withdrawVaultFunds(companyWallet);

        assertEq(usdc.balanceOf(companyWallet), 50e6 + INITIAL_FEE);
    }

    function test_MultipleUsersScenario() public {
        // User 1 pays
        vm.prank(operator);
        UserWallet(payable(user1Wallet)).transferToVault(50e6);

        vm.prank(operator);
        vault.processPayment(user1Wallet, 50e6, keccak256("user1-payment"));

        // User 2 pays
        vm.prank(operator);
        UserWallet(payable(user2Wallet)).transferToVault(100e6);

        vm.prank(operator);
        vault.processPayment(user2Wallet, 100e6, keccak256("user2-payment"));

        // Verify total tracking
        assertEq(vault.totalPaymentsProcessed(), 150e6);
        assertEq(vault.totalFeesCollected(), INITIAL_FEE * 2);

        // Vault accounting still valid
        assertTrue(vault.verifyVaultAccounting());
    }
}

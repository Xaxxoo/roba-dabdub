// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../../src/CheeseVault.sol";
import "../../src/UserWallet.sol";
import "../../src/UserWalletFactory.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

// Mock USDC for fuzz testing
contract MockUSDC is ERC20 {
    constructor() ERC20("USD Coin", "USDC") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/**
 * @title CheeseVault Fuzz Tests
 * @notice Property-based testing using fuzzing
 * @dev Run with: forge test --match-path test/CheeseVault.fuzz.t.sol -vv
 */
contract CheeseVaultFuzzTest is Test {
    CheeseVault public vault;
    UserWalletFactory public factory;
    MockUSDC public usdc;

    address public owner;
    address public admin;
    address public operator;
    address public treasurer;

    uint256 constant INITIAL_FEE = 0.5e6;
    uint256 constant MIN_DEPOSIT = 1e6;
    uint256 constant MAX_FEE = 5e6;

    function setUp() public {
        owner = address(this);
        admin = makeAddr("admin");
        operator = makeAddr("operator");
        treasurer = makeAddr("treasurer");

        usdc = new MockUSDC();

        vault = new CheeseVault(address(usdc), INITIAL_FEE, MIN_DEPOSIT);

        factory = new UserWalletFactory(operator, address(vault), address(usdc));

        vault.grantRole(vault.ADMIN_ROLE(), admin);
        vault.grantRole(vault.OPERATOR_ROLE(), operator);
        vault.grantRole(vault.TREASURER_ROLE(), treasurer);
    }

    // ========== PROCESS PAYMENT FUZZ TESTS ==========

    /// @notice Processing payment always deducts correct amount
    function testFuzz_ProcessPayment(address user, uint256 paymentAmount) public {
        vm.assume(user != address(0));
        vm.assume(user != address(vault));
        vm.assume(user != address(factory));

        // Bound to reasonable amounts
        paymentAmount = bound(paymentAmount, 1e6, 1_000_000e6); // $1 to $1M

        // Create user wallet
        string memory userId = vm.toString(user);
        vm.prank(operator);
        address userWallet = factory.createWallet(userId);

        // Fund wallet with exact amount needed (payment + fee)
        uint256 totalNeeded = paymentAmount + INITIAL_FEE;
        usdc.mint(userWallet, totalNeeded);

        // Process payment (internally calls transferToVault)
        vm.prank(operator);
        vault.processPayment(userWallet, paymentAmount, keccak256("payment"));

        // Verify
        assertEq(vault.availableProcessedPayments(), paymentAmount);
        assertEq(vault.availableFees(), INITIAL_FEE);
        assertEq(vault.totalPaymentsProcessed(), paymentAmount);
        assertEq(vault.totalFeesCollected(), INITIAL_FEE);
    }

    /// @notice Multiple payments accumulate correctly
    function testFuzz_MultiplePayments(uint256 payment1, uint256 payment2, uint8 numUsers) public {
        // Bound inputs to reasonable values
        payment1 = bound(payment1, 1e6, 100_000e6); // $1 to $100K
        payment2 = bound(payment2, 1e6, 100_000e6); // $1 to $100K
        numUsers = uint8(bound(numUsers, 1, 5)); // 1 to 5 users

        uint256 totalPayments = 0;
        uint256 totalFees = 0;

        for (uint256 i = 0; i < numUsers; i++) {
            // Create wallet
            string memory userId = string(abi.encodePacked("user", vm.toString(i)));
            vm.prank(operator);
            address userWallet = factory.createWallet(userId);

            // First payment - fund wallet with exact amount
            usdc.mint(userWallet, payment1 + INITIAL_FEE);
            vm.prank(operator);
            vault.processPayment(userWallet, payment1, keccak256(abi.encode("payment1", i)));
            totalPayments += payment1;
            totalFees += INITIAL_FEE;

            // Second payment - fund wallet again
            usdc.mint(userWallet, payment2 + INITIAL_FEE);
            vm.prank(operator);
            vault.processPayment(userWallet, payment2, keccak256(abi.encode("payment2", i)));
            totalPayments += payment2;
            totalFees += INITIAL_FEE;
        }

        // Verify
        assertEq(vault.totalPaymentsProcessed(), totalPayments);
        assertEq(vault.totalFeesCollected(), totalFees);
        assertEq(vault.availableProcessedPayments(), totalPayments);
        assertEq(vault.availableFees(), totalFees);
    }

    // ========== REFUND FUZZ TESTS ==========

    /// @notice Refund always restores correct balance
    function testFuzz_RefundPayment(uint256 paymentAmount) public {
        paymentAmount = bound(paymentAmount, 1e6, 1_000_000e6);

        // Setup
        vm.prank(operator);
        address userWallet = factory.createWallet("user@example.com");

        // Fund and process payment
        usdc.mint(userWallet, paymentAmount + INITIAL_FEE);

        vm.prank(operator);
        vault.processPayment(userWallet, paymentAmount, keccak256("payment"));

        uint256 walletBalanceBefore = usdc.balanceOf(userWallet);

        // Refund without fee
        vm.prank(admin);
        vault.refundPayment(userWallet, paymentAmount, false, keccak256("payment"));

        // Verify
        assertEq(usdc.balanceOf(userWallet), walletBalanceBefore + paymentAmount);
        assertEq(vault.availableProcessedPayments(), 0);
        assertEq(vault.totalPaymentsProcessed(), paymentAmount); // Cumulative doesn't change
    }

    /// @notice Refund with fee restores full amount
    function testFuzz_RefundPaymentWithFee(uint256 paymentAmount) public {
        paymentAmount = bound(paymentAmount, 1e6, 1_000_000e6);

        // Setup
        vm.prank(operator);
        address userWallet = factory.createWallet("user@example.com");

        // Fund and process payment
        usdc.mint(userWallet, paymentAmount + INITIAL_FEE);

        vm.prank(operator);
        vault.processPayment(userWallet, paymentAmount, keccak256("payment"));

        uint256 walletBalanceBefore = usdc.balanceOf(userWallet);

        // Refund with fee
        vm.prank(admin);
        vault.refundPayment(userWallet, paymentAmount, true, keccak256("payment"));

        // Should receive payment + fee back
        assertEq(usdc.balanceOf(userWallet), walletBalanceBefore + paymentAmount + INITIAL_FEE);
        assertEq(vault.availableProcessedPayments(), 0);
        assertEq(vault.availableFees(), 0);
        assertEq(vault.totalPaymentsProcessed(), paymentAmount);
        assertEq(vault.totalFeesCollected(), INITIAL_FEE);
    }

    // ========== VAULT WITHDRAWAL FUZZ TESTS ==========

    /// @notice Treasurer can withdraw all available funds
    function testFuzz_WithdrawVaultFunds(uint256 paymentAmount, address recipient) public {
        vm.assume(recipient != address(0));
        vm.assume(recipient != address(vault));
        paymentAmount = bound(paymentAmount, 1e6, 1_000_000e6);

        // Setup
        vm.prank(operator);
        address userWallet = factory.createWallet("user@example.com");

        // Fund and process payment
        usdc.mint(userWallet, paymentAmount + INITIAL_FEE);

        vm.prank(operator);
        vault.processPayment(userWallet, paymentAmount, keccak256("payment"));

        // Withdraw
        vm.prank(treasurer);
        vault.withdrawVaultFunds(recipient);

        // Verify
        assertEq(usdc.balanceOf(recipient), paymentAmount + INITIAL_FEE);
        assertEq(vault.availableProcessedPayments(), 0);
        assertEq(vault.availableFees(), 0);
    }

    // ========== INVARIANT TESTS ==========

    /// @notice Total payments processed should never decrease
    function testFuzz_TotalPaymentsNeverDecrease(uint256 payment1, uint256 payment2) public {
        payment1 = bound(payment1, 1e6, 500_000e6);
        payment2 = bound(payment2, 1e6, 500_000e6);

        // Setup
        vm.prank(operator);
        address userWallet = factory.createWallet("user@example.com");

        // First payment
        usdc.mint(userWallet, payment1 + INITIAL_FEE);
        vm.prank(operator);
        vault.processPayment(userWallet, payment1, keccak256("payment1"));

        uint256 totalAfterFirst = vault.totalPaymentsProcessed();

        // Second payment
        usdc.mint(userWallet, payment2 + INITIAL_FEE);
        vm.prank(operator);
        vault.processPayment(userWallet, payment2, keccak256("payment2"));

        uint256 totalAfterSecond = vault.totalPaymentsProcessed();

        // Total should only increase
        assertGe(totalAfterSecond, totalAfterFirst);
        assertEq(totalAfterSecond, payment1 + payment2);
    }

    /// @notice Vault accounting always valid
    function testFuzz_VaultAccountingAlwaysValid(uint256 payment1, uint256 payment2, uint256 payment3) public {
        payment1 = bound(payment1, 1e6, 300_000e6);
        payment2 = bound(payment2, 1e6, 300_000e6);
        payment3 = bound(payment3, 1e6, 300_000e6);

        // Create wallets
        vm.prank(operator);
        address wallet1 = factory.createWallet("user1@example.com");
        vm.prank(operator);
        address wallet2 = factory.createWallet("user2@example.com");
        vm.prank(operator);
        address wallet3 = factory.createWallet("user3@example.com");

        // Process payments
        usdc.mint(wallet1, payment1 + INITIAL_FEE);
        vm.prank(operator);
        vault.processPayment(wallet1, payment1, keccak256("payment1"));
        assertTrue(vault.verifyVaultAccounting());

        usdc.mint(wallet2, payment2 + INITIAL_FEE);
        vm.prank(operator);
        vault.processPayment(wallet2, payment2, keccak256("payment2"));
        assertTrue(vault.verifyVaultAccounting());

        usdc.mint(wallet3, payment3 + INITIAL_FEE);
        vm.prank(operator);
        vault.processPayment(wallet3, payment3, keccak256("payment3"));
        assertTrue(vault.verifyVaultAccounting());

        // After withdrawal
        vm.prank(treasurer);
        vault.withdrawVaultFunds(makeAddr("recipient"));
        assertTrue(vault.verifyVaultAccounting());
    }

    // ========== FEE UPDATE FUZZ TESTS ==========

    /// @notice Admin can set any fee <= MAX_FEE
    function testFuzz_SetFee(uint256 newFee) public {
        newFee = bound(newFee, 0, MAX_FEE);

        vm.prank(admin);
        vault.setFee(newFee);

        assertEq(vault.feeAmount(), newFee);
    }

    /// @notice Setting fee above MAX_FEE always reverts
    function testFuzz_RevertWhen_SetFeeAboveMax(uint256 newFee) public {
        vm.assume(newFee > MAX_FEE);
        newFee = bound(newFee, MAX_FEE + 1, type(uint128).max); // Bound to reasonable max

        vm.prank(admin);
        vm.expectRevert("Fee exceeds maximum");
        vault.setFee(newFee);
    }

    // ========== MIN DEPOSIT FUZZ TESTS ==========

    /// @notice Admin can set any minimum deposit
    function testFuzz_SetMinDeposit(uint256 newMinDeposit) public {
        newMinDeposit = bound(newMinDeposit, 0, 1000e6); // Up to $1000

        vm.prank(admin);
        vault.setMinDeposit(newMinDeposit);

        assertEq(vault.minDeposit(), newMinDeposit);
    }

    /// @notice Fee updates apply to new payments
    function testFuzz_FeeUpdateApplies(uint256 newFee, uint256 paymentAmount) public {
        newFee = bound(newFee, 0.1e6, MAX_FEE); // $0.10 to $5
        paymentAmount = bound(paymentAmount, 1e6, 100_000e6);

        // Update fee
        vm.prank(admin);
        vault.setFee(newFee);

        // Create wallet and process payment
        vm.prank(operator);
        address userWallet = factory.createWallet("user@example.com");

        usdc.mint(userWallet, paymentAmount + newFee);
        vm.prank(operator);
        vault.processPayment(userWallet, paymentAmount, keccak256("payment"));

        // Verify new fee was used
        assertEq(vault.availableFees(), newFee);
        assertEq(vault.totalFeesCollected(), newFee);
    }
}

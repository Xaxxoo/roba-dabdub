// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/UserWallet.sol";
import "../src/CheeseVault.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

// Mock USDC
contract MockUSDC is ERC20 {
    constructor() ERC20("USD Coin", "USDC") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract UserWalletTest is Test {
    UserWallet public userWallet;
    MockUSDC public usdc;
    CheeseVault public vault;

    address public backend;
    address public owner;
    address public user;
    address public treasurer;

    uint256 constant INITIAL_FEE = 0.5e6;
    uint256 constant MIN_DEPOSIT = 1e6;

    event TransferredToVault(uint256 paymentAmount, uint256 feeAmount, uint256 totalAmount, uint256 timestamp);

    event Withdrawal(address indexed recipient, uint256 amount, uint256 timestamp);

    event OwnerUpdated(address indexed oldOwner, address indexed newOwner);

    event EmergencyWithdrawal(uint256 amount, uint256 timestamp);

    function setUp() public {
        backend = makeAddr("backend");
        owner = makeAddr("owner");
        user = makeAddr("user");
        treasurer = makeAddr("treasurer");

        // Deploy USDC
        usdc = new MockUSDC();

        // Deploy vault
        vault = new CheeseVault(address(usdc), INITIAL_FEE, MIN_DEPOSIT);

        // Deploy user wallet
        userWallet = new UserWallet(
            backend,
            address(vault),
            address(usdc),
            address(0) // No owner initially
        );

        // Setup vault roles
        vault.grantRole(vault.OPERATOR_ROLE(), backend);
        vault.grantRole(vault.TREASURER_ROLE(), treasurer);

        // Mint USDC to user for testing
        usdc.mint(user, 1000e6);
    }

    // ========== DEPLOYMENT TESTS ==========

    function test_Deployment() public view {
        assertEq(userWallet.backend(), backend);
        assertEq(address(userWallet.vault()), address(vault));
        assertEq(address(userWallet.usdc()), address(usdc));
        assertEq(userWallet.owner(), address(0));
    }

    function test_RevertWhen_DeployWithInvalidBackend() public {
        vm.expectRevert("Invalid backend");
        new UserWallet(address(0), address(vault), address(usdc), owner);
    }

    function test_RevertWhen_DeployWithInvalidVault() public {
        vm.expectRevert("Invalid vault");
        new UserWallet(backend, address(0), address(usdc), owner);
    }

    function test_RevertWhen_DeployWithInvalidUSDC() public {
        vm.expectRevert("Invalid USDC");
        new UserWallet(backend, address(vault), address(0), owner);
    }

    // ========== GET BALANCE TESTS ==========

    function test_GetBalance() public {
        assertEq(userWallet.getBalance(), 0);

        // Send USDC to wallet
        vm.prank(user);
        usdc.transfer(address(userWallet), 100e6);

        assertEq(userWallet.getBalance(), 100e6);
    }

    // ========== TRANSFER TO VAULT TESTS ==========

    function test_TransferToVault() public {
        // Setup: user sends USDC to their wallet
        vm.prank(user);
        usdc.transfer(address(userWallet), 100e6);

        uint256 paymentAmount = 50e6;
        uint256 expectedFee = INITIAL_FEE;
        uint256 expectedTotal = paymentAmount + expectedFee;

        // Backend calls transferToVault
        vm.prank(backend);
        vm.expectEmit(true, true, true, true);
        emit TransferredToVault(paymentAmount, expectedFee, expectedTotal, block.timestamp);

        uint256 totalTransferred = userWallet.transferToVault(paymentAmount);

        // Verify
        assertEq(totalTransferred, expectedTotal);
        assertEq(userWallet.getBalance(), 100e6 - expectedTotal);
        assertEq(usdc.balanceOf(address(vault)), expectedTotal);
    }

    function test_TransferToVaultWithUpdatedFee() public {
        // Admin updates fee
        vm.prank(address(this)); // We're the owner
        vault.grantRole(vault.ADMIN_ROLE(), address(this));
        vault.setFee(1e6); // Update to $1

        // Setup
        vm.prank(user);
        usdc.transfer(address(userWallet), 100e6);

        uint256 paymentAmount = 50e6;

        // Transfer should use new fee
        vm.prank(backend);
        uint256 totalTransferred = userWallet.transferToVault(paymentAmount);

        assertEq(totalTransferred, 51e6); // 50 + 1 (new fee)
    }

    function test_RevertWhen_TransferToVaultNotBackend() public {
        vm.prank(user);
        usdc.transfer(address(userWallet), 100e6);

        vm.prank(user);
        vm.expectRevert("Not authorized");
        userWallet.transferToVault(50e6);
    }

    function test_RevertWhen_TransferToVaultZeroAmount() public {
        vm.prank(backend);
        vm.expectRevert("Payment amount must be > 0");
        userWallet.transferToVault(0);
    }

    function test_RevertWhen_TransferToVaultInsufficientBalance() public {
        vm.prank(user);
        usdc.transfer(address(userWallet), 10e6);

        vm.prank(backend);
        vm.expectRevert("Insufficient balance");
        userWallet.transferToVault(50e6); // Needs 50.5 but only has 10
    }

    // ========== WITHDRAW TESTS ==========

    function test_WithdrawByBackend() public {
        // Setup
        vm.prank(user);
        usdc.transfer(address(userWallet), 100e6);

        address recipient = makeAddr("recipient");
        uint256 withdrawAmount = 50e6;

        vm.prank(backend);
        vm.expectEmit(true, true, true, true);
        emit Withdrawal(recipient, withdrawAmount, block.timestamp);

        userWallet.withdraw(withdrawAmount, recipient);

        assertEq(usdc.balanceOf(recipient), withdrawAmount);
        assertEq(userWallet.getBalance(), 50e6);
    }

    function test_WithdrawByOwner() public {
        // Set owner
        vm.prank(backend);
        userWallet.setOwner(owner);

        // Setup
        vm.prank(user);
        usdc.transfer(address(userWallet), 100e6);

        address recipient = makeAddr("recipient");

        vm.prank(owner);
        userWallet.withdraw(50e6, recipient);

        assertEq(usdc.balanceOf(recipient), 50e6);
    }

    function test_RevertWhen_WithdrawNotAuthorized() public {
        vm.prank(user);
        usdc.transfer(address(userWallet), 100e6);

        vm.prank(user);
        vm.expectRevert("Not authorized");
        userWallet.withdraw(50e6, user);
    }

    function test_RevertWhen_WithdrawZeroAmount() public {
        vm.prank(backend);
        vm.expectRevert("Amount must be > 0");
        userWallet.withdraw(0, user);
    }

    function test_RevertWhen_WithdrawToZeroAddress() public {
        vm.prank(backend);
        vm.expectRevert("Invalid recipient");
        userWallet.withdraw(50e6, address(0));
    }

    function test_RevertWhen_WithdrawInsufficientBalance() public {
        vm.prank(user);
        usdc.transfer(address(userWallet), 10e6);

        vm.prank(backend);
        vm.expectRevert("Insufficient balance");
        userWallet.withdraw(50e6, user);
    }

    // ========== EMERGENCY WITHDRAW TESTS ==========

    function test_EmergencyWithdraw() public {
        // Set owner
        vm.prank(backend);
        userWallet.setOwner(owner);

        // Setup
        vm.prank(user);
        usdc.transfer(address(userWallet), 100e6);

        vm.prank(owner);
        vm.expectEmit(true, true, true, true);
        emit EmergencyWithdrawal(100e6, block.timestamp);

        userWallet.emergencyWithdraw();

        assertEq(usdc.balanceOf(owner), 100e6);
        assertEq(userWallet.getBalance(), 0);
    }

    function test_RevertWhen_EmergencyWithdrawNotOwner() public {
        vm.prank(backend);
        userWallet.setOwner(owner);

        vm.prank(user);
        vm.expectRevert("Only owner");
        userWallet.emergencyWithdraw();
    }

    function test_RevertWhen_EmergencyWithdrawOwnerNotSet() public {
        vm.prank(user);
        vm.expectRevert("Only owner");
        userWallet.emergencyWithdraw();
    }

    function test_RevertWhen_EmergencyWithdrawZeroBalance() public {
        vm.prank(backend);
        userWallet.setOwner(owner);

        vm.prank(owner);
        vm.expectRevert("No balance to withdraw");
        userWallet.emergencyWithdraw();
    }

    // ========== SET OWNER TESTS ==========

    function test_SetOwner() public {
        vm.prank(backend);
        vm.expectEmit(true, true, true, true);
        emit OwnerUpdated(address(0), owner);

        userWallet.setOwner(owner);

        assertEq(userWallet.owner(), owner);
    }

    function test_UpdateOwner() public {
        vm.prank(backend);
        userWallet.setOwner(owner);

        address newOwner = makeAddr("newOwner");

        vm.prank(backend);
        vm.expectEmit(true, true, true, true);
        emit OwnerUpdated(owner, newOwner);

        userWallet.setOwner(newOwner);

        assertEq(userWallet.owner(), newOwner);
    }

    function test_RevertWhen_SetOwnerNotBackend() public {
        vm.prank(user);
        vm.expectRevert("Only backend");
        userWallet.setOwner(owner);
    }

    // ========== INTEGRATION TESTS ==========

    function test_CompletePaymentFlow() public {
        // 1. User deposits USDC to their wallet
        vm.prank(user);
        usdc.transfer(address(userWallet), 100e6);

        assertEq(userWallet.getBalance(), 100e6);

        // 2. Backend processes payment
        uint256 paymentAmount = 50e6;

        vm.prank(backend);
        userWallet.transferToVault(paymentAmount);

        // 3. Verify balances
        assertEq(userWallet.getBalance(), 100e6 - 50e6 - INITIAL_FEE);
        assertEq(usdc.balanceOf(address(vault)), 50e6 + INITIAL_FEE);

        // 4. User withdraws remaining
        address recipient = makeAddr("recipient");
        uint256 remaining = userWallet.getBalance();

        vm.prank(backend);
        userWallet.withdraw(remaining, recipient);

        assertEq(usdc.balanceOf(recipient), remaining);
        assertEq(userWallet.getBalance(), 0);
    }
}

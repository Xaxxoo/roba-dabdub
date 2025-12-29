// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../../src/CheeseVault.sol";
import "../../src/UserWallet.sol";
import "../../src/UserWalletFactory.sol";

// Extended IERC20 interface with decimals
interface IERC20Extended is IERC20 {
    function decimals() external view returns (uint8);
}

/**
 * @title CheeseVault Fork Tests
 * @notice Tests using real USDC on Polygon fork
 * @dev Run with: forge test --match-path test/CheeseVault.fork.t.sol --fork-url $POLYGON_RPC_URL -vv
 */
contract CheeseVaultForkTest is Test {
    CheeseVault public vault;
    UserWalletFactory public factory;
    IERC20Extended public usdc;

    // Real Polygon USDC address
    address constant USDC_ADDRESS = 0x3c499c542cEF5E3811e1192ce70d8cC03d5c3359;

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

    function setUp() public {
        // Create a fork of Polygon mainnet
        string memory rpcUrl = vm.envString("POLYGON_RPC_URL");
        vm.createSelectFork(rpcUrl);

        // Setup addresses
        owner = address(this);
        admin = makeAddr("admin");
        operator = makeAddr("operator");
        treasurer = makeAddr("treasurer");
        user1 = makeAddr("user1");
        user2 = makeAddr("user2");

        // Get real USDC contract
        usdc = IERC20Extended(USDC_ADDRESS);

        // Deploy vault with real USDC
        vault = new CheeseVault(USDC_ADDRESS, INITIAL_FEE, MIN_DEPOSIT);

        // Deploy factory
        factory = new UserWalletFactory(operator, address(vault), USDC_ADDRESS);

        // Assign roles
        vault.grantRole(vault.ADMIN_ROLE(), admin);
        vault.grantRole(vault.OPERATOR_ROLE(), operator);
        vault.grantRole(vault.TREASURER_ROLE(), treasurer);

        // Create user wallets
        vm.startPrank(operator);
        user1Wallet = factory.createWallet("user1@example.com");
        user2Wallet = factory.createWallet("user2@example.com");
        vm.stopPrank();

        // Fund user wallets with real USDC
        deal(USDC_ADDRESS, user1Wallet, 1000e6);
        deal(USDC_ADDRESS, user2Wallet, 1000e6);
    }

    // ========== FORK TESTS ==========

    function test_Fork_RealUSDCProcessPayment() public {
        // Transfer to vault
        vm.prank(operator);
        UserWallet(payable(user1Wallet)).transferToVault(100e6);

        vm.prank(operator);
        vault.processPayment(user1Wallet, 100e6, keccak256("payment-001"));

        assertEq(vault.availableProcessedPayments(), 100e6);
        assertEq(vault.availableFees(), INITIAL_FEE);
    }

    function test_Fork_CompleteFlow() public {
        // User pays bill
        vm.prank(operator);
        UserWallet(payable(user1Wallet)).transferToVault(100e6);

        vm.prank(operator);
        vault.processPayment(user1Wallet, 100e6, keccak256("bill-001"));

        // Treasurer withdraws
        address recipient = makeAddr("recipient");
        vm.prank(treasurer);
        vault.withdrawVaultFunds(recipient);

        // Verify recipient got real USDC
        assertEq(usdc.balanceOf(recipient), 100e6 + INITIAL_FEE);
    }

    function test_Fork_USDCDecimalsCorrect() public view {
        // Verify we're using the right decimals
        assertEq(usdc.decimals(), 6);
    }

    function test_Fork_MultipleUsersRealUSDC() public {
        // User 1 pays
        vm.prank(operator);
        UserWallet(payable(user1Wallet)).transferToVault(100e6);

        vm.prank(operator);
        vault.processPayment(user1Wallet, 100e6, keccak256("user1-payment"));

        // User 2 pays
        vm.prank(operator);
        UserWallet(payable(user2Wallet)).transferToVault(200e6);

        vm.prank(operator);
        vault.processPayment(user2Wallet, 200e6, keccak256("user2-payment"));

        // Verify vault totals
        assertEq(vault.totalPaymentsProcessed(), 300e6);
        assertEq(vault.totalFeesCollected(), INITIAL_FEE * 2);
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/UserWalletFactory.sol";
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

contract UserWalletFactoryTest is Test {
    UserWalletFactory public factory;
    MockUSDC public usdc;
    CheeseVault public vault;

    address public owner;
    address public backend;

    uint256 constant INITIAL_FEE = 0.5e6;
    uint256 constant MIN_DEPOSIT = 1e6;

    event WalletCreated(bytes32 indexed userIdHash, address indexed wallet, uint256 timestamp);

    event BackendUpdated(address indexed oldBackend, address indexed newBackend);

    event VaultUpdated(address indexed oldVault, address indexed newVault);

    function setUp() public {
        owner = address(this);
        backend = makeAddr("backend");

        // Deploy USDC
        usdc = new MockUSDC();

        // Deploy vault
        vault = new CheeseVault(address(usdc), INITIAL_FEE, MIN_DEPOSIT);

        // Deploy factory
        factory = new UserWalletFactory(backend, address(vault), address(usdc));
    }

    // ========== DEPLOYMENT TESTS ==========

    function test_Deployment() public view {
        assertEq(factory.backend(), backend);
        assertEq(factory.vault(), address(vault));
        assertEq(factory.usdc(), address(usdc));
        assertEq(factory.totalWallets(), 0);
    }

    function test_RevertWhen_DeployWithInvalidBackend() public {
        vm.expectRevert("Invalid backend");
        new UserWalletFactory(address(0), address(vault), address(usdc));
    }

    function test_RevertWhen_DeployWithInvalidVault() public {
        vm.expectRevert("Invalid vault");
        new UserWalletFactory(backend, address(0), address(usdc));
    }

    function test_RevertWhen_DeployWithInvalidUSDC() public {
        vm.expectRevert("Invalid USDC");
        new UserWalletFactory(backend, address(vault), address(0));
    }

    // ========== CREATE WALLET TESTS ==========

    function test_CreateWallet() public {
        string memory userId = "user@example.com";

        vm.prank(backend);
        address wallet = factory.createWallet(userId);

        assertTrue(wallet != address(0));
        assertEq(factory.getWallet(userId), wallet);
        assertTrue(factory.hasWallet(userId));
        assertTrue(factory.isWallet(wallet));
        assertEq(factory.totalWallets(), 1);
        assertEq(factory.getWalletAtIndex(0), wallet);
    }

    function test_CreateMultipleWallets() public {
        vm.startPrank(backend);

        address wallet1 = factory.createWallet("user1@example.com");
        address wallet2 = factory.createWallet("user2@example.com");
        address wallet3 = factory.createWallet("user3@example.com");

        vm.stopPrank();

        assertEq(factory.totalWallets(), 3);
        assertTrue(wallet1 != wallet2);
        assertTrue(wallet2 != wallet3);
        assertTrue(wallet1 != wallet3);

        assertEq(factory.getWallet("user1@example.com"), wallet1);
        assertEq(factory.getWallet("user2@example.com"), wallet2);
        assertEq(factory.getWallet("user3@example.com"), wallet3);
    }

    function test_RevertWhen_CreateWalletNotBackend() public {
        vm.prank(makeAddr("unauthorized"));
        vm.expectRevert("Only backend");
        factory.createWallet("user@example.com");
    }

    function test_RevertWhen_CreateWalletAlreadyExists() public {
        vm.startPrank(backend);

        factory.createWallet("user@example.com");

        vm.expectRevert("Wallet already exists");
        factory.createWallet("user@example.com");

        vm.stopPrank();
    }

    function test_RevertWhen_CreateWalletEmptyUserId() public {
        vm.prank(backend);
        vm.expectRevert("Invalid userId");
        factory.createWallet("");
    }

    function test_RevertWhen_CreateWalletWhenPaused() public {
        factory.pause();

        vm.prank(backend);
        vm.expectRevert();
        factory.createWallet("user@example.com");
    }

    // ========== GET WALLET TESTS ==========

    function test_GetWallet() public {
        vm.prank(backend);
        address wallet = factory.createWallet("user@example.com");

        assertEq(factory.getWallet("user@example.com"), wallet);
    }

    function test_GetWalletNonExistent() public view {
        assertEq(factory.getWallet("nonexistent@example.com"), address(0));
    }

    // ========== HAS WALLET TESTS ==========

    function test_HasWallet() public {
        assertFalse(factory.hasWallet("user@example.com"));

        vm.prank(backend);
        factory.createWallet("user@example.com");

        assertTrue(factory.hasWallet("user@example.com"));
    }

    // ========== GET WALLET AT INDEX TESTS ==========

    function test_GetWalletAtIndex() public {
        vm.startPrank(backend);

        address wallet1 = factory.createWallet("user1@example.com");
        address wallet2 = factory.createWallet("user2@example.com");

        vm.stopPrank();

        assertEq(factory.getWalletAtIndex(0), wallet1);
        assertEq(factory.getWalletAtIndex(1), wallet2);
    }

    function test_RevertWhen_GetWalletAtIndexOutOfBounds() public {
        vm.expectRevert("Index out of bounds");
        factory.getWalletAtIndex(0);
    }

    // ========== UPDATE BACKEND TESTS ==========

    function test_UpdateBackend() public {
        address newBackend = makeAddr("newBackend");

        vm.expectEmit(true, true, true, true);
        emit BackendUpdated(backend, newBackend);

        factory.updateBackend(newBackend);

        assertEq(factory.backend(), newBackend);
    }

    function test_RevertWhen_UpdateBackendNotOwner() public {
        vm.prank(makeAddr("unauthorized"));
        vm.expectRevert();
        factory.updateBackend(makeAddr("newBackend"));
    }

    function test_RevertWhen_UpdateBackendToZeroAddress() public {
        vm.expectRevert("Invalid backend");
        factory.updateBackend(address(0));
    }

    // ========== UPDATE VAULT TESTS ==========

    function test_UpdateVault() public {
        address newVault = makeAddr("newVault");

        vm.expectEmit(true, true, true, true);
        emit VaultUpdated(address(vault), newVault);

        factory.updateVault(newVault);

        assertEq(factory.vault(), newVault);
    }

    function test_RevertWhen_UpdateVaultNotOwner() public {
        vm.prank(makeAddr("unauthorized"));
        vm.expectRevert();
        factory.updateVault(makeAddr("newVault"));
    }

    function test_RevertWhen_UpdateVaultToZeroAddress() public {
        vm.expectRevert("Invalid vault");
        factory.updateVault(address(0));
    }

    // ========== PAUSE/UNPAUSE TESTS ==========

    function test_Pause() public {
        factory.pause();
        assertTrue(factory.paused());
    }

    function test_Unpause() public {
        factory.pause();
        factory.unpause();
        assertFalse(factory.paused());
    }

    function test_RevertWhen_PauseNotOwner() public {
        vm.prank(makeAddr("unauthorized"));
        vm.expectRevert();
        factory.pause();
    }

    function test_RevertWhen_UnpauseNotOwner() public {
        factory.pause();

        vm.prank(makeAddr("unauthorized"));
        vm.expectRevert();
        factory.unpause();
    }

    // ========== INTEGRATION TESTS ==========

    function test_CreateWalletAndVerifyProperties() public {
        vm.prank(backend);
        address walletAddress = factory.createWallet("user@example.com");

        UserWallet wallet = UserWallet(payable(walletAddress));

        // Verify wallet properties
        assertEq(wallet.backend(), backend);
        assertEq(address(wallet.vault()), address(vault));
        assertEq(address(wallet.usdc()), address(usdc));
        assertEq(wallet.owner(), address(0));
        assertEq(wallet.getBalance(), 0);
    }

    function test_MultipleUsersCompleteFlow() public {
        // Create wallets for 3 users
        vm.startPrank(backend);
        address wallet1 = factory.createWallet("user1@example.com");
        address wallet2 = factory.createWallet("user2@example.com");
        address wallet3 = factory.createWallet("user3@example.com");
        vm.stopPrank();

        // Verify all different
        assertTrue(wallet1 != wallet2);
        assertTrue(wallet2 != wallet3);

        // Verify factory tracking
        assertEq(factory.totalWallets(), 3);
        assertTrue(factory.isWallet(wallet1));
        assertTrue(factory.isWallet(wallet2));
        assertTrue(factory.isWallet(wallet3));

        // Verify retrieval
        assertEq(factory.getWallet("user1@example.com"), wallet1);
        assertEq(factory.getWallet("user2@example.com"), wallet2);
        assertEq(factory.getWallet("user3@example.com"), wallet3);
    }
}

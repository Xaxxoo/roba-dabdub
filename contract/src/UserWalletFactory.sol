// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "./UserWallet.sol";

/**
 * @title UserWalletFactory
 * @notice Factory contract to deploy and manage UserWallet contracts
 * @dev One factory manages all user wallets
 */
contract UserWalletFactory is Ownable, Pausable {
    // ========== STATE VARIABLES ==========

    address public backend;
    address public vault;
    address public usdc;

    // Mappings
    mapping(bytes32 => address) public userWallets; // userIdHash => wallet address
    mapping(address => bool) public isWallet; // Quick check if address is a user wallet

    // Array for iteration
    address[] public allWallets;

    // Counter
    uint256 public totalWallets;

    // ========== EVENTS ==========

    event WalletCreated(bytes32 indexed userIdHash, address indexed wallet, uint256 timestamp);

    event BackendUpdated(address indexed oldBackend, address indexed newBackend);

    event VaultUpdated(address indexed oldVault, address indexed newVault);

    // ========== MODIFIERS ==========

    modifier onlyBackend() {
        require(msg.sender == backend, "Only backend");
        _;
    }

    // ========== CONSTRUCTOR ==========

    constructor(address _backend, address _vault, address _usdc) Ownable(msg.sender) {
        require(_backend != address(0), "Invalid backend");
        require(_vault != address(0), "Invalid vault");
        require(_usdc != address(0), "Invalid USDC");

        backend = _backend;
        vault = _vault;
        usdc = _usdc;
    }

    // ========== FACTORY FUNCTIONS ==========

    /**
     * @notice Create a new UserWallet for a user
     * @param userId Unique user identifier (email)
     * @return wallet Address of created wallet
     */
    function createWallet(string memory userId) external onlyBackend whenNotPaused returns (address wallet) {
        bytes32 userIdHash = keccak256(abi.encodePacked(userId));

        require(userWallets[userIdHash] == address(0), "Wallet already exists");
        require(bytes(userId).length > 0, "Invalid userId");

        // Deploy new UserWallet
        UserWallet newWallet = new UserWallet(
            backend,
            vault,
            usdc,
            address(0) // No owner initially
        );

        wallet = address(newWallet);

        // Store mappings
        userWallets[userIdHash] = wallet;
        isWallet[wallet] = true;
        allWallets.push(wallet);
        totalWallets++;

        emit WalletCreated(userIdHash, wallet, block.timestamp);
    }

    // ========== VIEW FUNCTIONS ==========

    /**
     * @notice Get wallet address for a user
     * @param userId User identifier
     * @return Wallet address (address(0) if doesn't exist)
     */
    function getWallet(string memory userId) external view returns (address) {
        bytes32 userIdHash = keccak256(abi.encodePacked(userId));
        return userWallets[userIdHash];
    }

    /**
     * @notice Check if user has a wallet
     * @param userId User identifier
     * @return true if wallet exists
     */
    function hasWallet(string memory userId) external view returns (bool) {
        bytes32 userIdHash = keccak256(abi.encodePacked(userId));
        return userWallets[userIdHash] != address(0);
    }

    /**
     * @notice Get total number of wallets created
     * @return Total wallet count
     */
    function getTotalWallets() external view returns (uint256) {
        return totalWallets;
    }

    /**
     * @notice Get wallet at specific index
     * @param index Array index
     * @return Wallet address
     */
    function getWalletAtIndex(uint256 index) external view returns (address) {
        require(index < allWallets.length, "Index out of bounds");
        return allWallets[index];
    }

    // ========== ADMIN FUNCTIONS ==========

    /**
     * @notice Update backend address
     * @param newBackend New backend operator address
     */
    function updateBackend(address newBackend) external onlyOwner {
        require(newBackend != address(0), "Invalid backend");

        address oldBackend = backend;
        backend = newBackend;

        emit BackendUpdated(oldBackend, newBackend);
    }

    /**
     * @notice Update vault address
     * @param newVault New CheeseVault address
     */
    function updateVault(address newVault) external onlyOwner {
        require(newVault != address(0), "Invalid vault");

        address oldVault = vault;
        vault = newVault;

        emit VaultUpdated(oldVault, newVault);
    }

    /**
     * @notice Pause wallet creation
     */
    function pause() external onlyOwner {
        _pause();
    }

    /**
     * @notice Unpause wallet creation
     */
    function unpause() external onlyOwner {
        _unpause();
    }
}

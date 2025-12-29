// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "../src/CheeseVault.sol";

contract DeployCheeseVault is Script {
    // Chain IDs
    uint256 constant POLYGON_MAINNET = 137;
    uint256 constant POLYGON_AMOY = 80002;

    // USDC addresses
    address constant USDC_POLYGON_MAINNET = 0x3c499c542cEF5E3811e1192ce70d8cC03d5c3359;
    address constant USDC_POLYGON_AMOY = 0x41E94Eb019C0762f9Bfcf9Fb1E58725BfB0e7582;

    function run() external {
        // Load environment variables
        uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");

        // Automatically detect network from chain ID
        uint256 chainId = block.chainid;
        bool isTestnet;
        address usdcAddress;
        string memory networkName;

        if (chainId == POLYGON_AMOY) {
            isTestnet = true;
            usdcAddress = USDC_POLYGON_AMOY;
            networkName = "Polygon Amoy Testnet";
        } else if (chainId == POLYGON_MAINNET) {
            isTestnet = false;
            usdcAddress = USDC_POLYGON_MAINNET;
            networkName = "Polygon Mainnet";
        } else {
            revert(string(abi.encodePacked("Unsupported chain ID: ", vm.toString(chainId))));
        }

        // Configuration
        uint256 initialFee = 0.5e6; // $0.50
        uint256 minDeposit = 1e6; // $1.00

        address deployer = vm.addr(deployerPrivateKey);

        console.log("==========================================");
        console.log("Deploying to:", networkName);
        console.log("Chain ID:", chainId);
        console.log("USDC address:", usdcAddress);
        console.log("Deployer:", deployer);
        console.log("==========================================");

        vm.startBroadcast(deployerPrivateKey);

        // Deploy CheeseVault
        CheeseVault vault = new CheeseVault(usdcAddress, initialFee, minDeposit);

        // If testnet, grant all roles to deployer for testing
        if (isTestnet) {
            console.log("TESTNET: Granting all roles to deployer for testing...");
            vault.grantRole(vault.ADMIN_ROLE(), deployer);
            vault.grantRole(vault.OPERATOR_ROLE(), deployer);
            vault.grantRole(vault.TREASURER_ROLE(), deployer);
        }

        vm.stopBroadcast();

        // Log deployment info
        console.log("");
        console.log("==========================================");
        console.log("CheeseVault Deployment Summary");
        console.log("==========================================");
        console.log("Contract deployed to:", address(vault));
        console.log("Network:", networkName);
        console.log("Chain ID:", chainId);
        console.log("USDC address:", usdcAddress);
        console.log("Initial fee (wei):", initialFee);
        console.log("Initial fee (USDC):", initialFee / 1e6);
        console.log("Min deposit (wei):", minDeposit);
        console.log("Min deposit (USDC):", minDeposit / 1e6);
        console.log("Deployer (owner):", deployer);
        console.log("");

        if (isTestnet) {
            console.log("Roles assigned to deployer:");
            console.log("- DEFAULT_ADMIN_ROLE: true (automatic)");
            console.log("- ADMIN_ROLE: true");
            console.log("- OPERATOR_ROLE: true");
            console.log("- TREASURER_ROLE: true");
        } else {
            console.log("WARNING: MAINNET DEPLOYMENT");
            console.log("No roles assigned automatically");
            console.log("You need to manually assign roles using:");
            console.log("- vault.grantRole(ADMIN_ROLE, <admin_address>)");
            console.log("- vault.grantRole(OPERATOR_ROLE, <operator_address>)");
            console.log("- vault.grantRole(TREASURER_ROLE, <treasurer_address>)");
        }
        console.log("==========================================");
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "../src/CheeseVault.sol";
import "../src/UserWalletFactory.sol";

contract DeployAll is Script {
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
        console.log("CheeseVault Deployment");
        console.log("==========================================");
        console.log("Deploying to:", networkName);
        console.log("Chain ID:", chainId);
        console.log("USDC address:", usdcAddress);
        console.log("Deployer:", deployer);
        console.log("==========================================");
        console.log("");

        vm.startBroadcast(deployerPrivateKey);

        // 1. Deploy CheeseVault
        console.log("Deploying CheeseVault...");
        CheeseVault vault = new CheeseVault(usdcAddress, initialFee, minDeposit);
        console.log("CheeseVault deployed at:", address(vault));
        console.log("");

        // 2. Deploy UserWalletFactory
        console.log("Deploying UserWalletFactory...");
        UserWalletFactory factory = new UserWalletFactory(
            deployer, // backend (deployer for testnet)
            address(vault),
            usdcAddress
        );
        console.log("UserWalletFactory deployed at:", address(factory));
        console.log("");

        // 3. If testnet, grant all roles to deployer for testing
        if (isTestnet) {
            console.log("TESTNET: Granting roles to deployer for testing...");
            vault.grantRole(vault.ADMIN_ROLE(), deployer);
            vault.grantRole(vault.OPERATOR_ROLE(), deployer);
            vault.grantRole(vault.TREASURER_ROLE(), deployer);
            console.log("Roles granted!");
            console.log("");
        }

        vm.stopBroadcast();

        // Log deployment summary
        console.log("==========================================");
        console.log("Deployment Summary");
        console.log("==========================================");
        console.log("Network:", networkName);
        console.log("Chain ID:", chainId);
        console.log("");
        console.log("Deployed Contracts:");
        console.log("- CheeseVault:", address(vault));
        console.log("- UserWalletFactory:", address(factory));
        console.log("");
        console.log("Configuration:");
        console.log("- USDC address:", usdcAddress);
        console.log("- Initial fee:", initialFee / 1e6, "USDC");
        console.log("- Min deposit:", minDeposit / 1e6, "USDC");
        console.log("- Deployer (owner):", deployer);
        console.log("");

        if (isTestnet) {
            console.log("Testnet Roles (all granted to deployer):");
            console.log("- DEFAULT_ADMIN_ROLE: deployer");
            console.log("- ADMIN_ROLE: deployer");
            console.log("- OPERATOR_ROLE: deployer");
            console.log("- TREASURER_ROLE: deployer");
            console.log("");
            console.log("Factory backend: deployer");
        } else {
            console.log("MAINNET WARNING:");
            console.log("- No roles assigned automatically");
            console.log("- Factory backend set to deployer");
            console.log("");
            console.log("You need to manually:");
            console.log("1. Grant vault roles:");
            console.log("   - vault.grantRole(ADMIN_ROLE, <admin_address>)");
            console.log("   - vault.grantRole(OPERATOR_ROLE, <operator_address>)");
            console.log("   - vault.grantRole(TREASURER_ROLE, <treasurer_address>)");
            console.log("2. Update factory backend if needed:");
            console.log("   - factory.updateBackend(<backend_address>)");
        }

        console.log("==========================================");
    }
}

# CheeseVault

A stablecoin payment system that allows users to fund accounts with USDC and pay bills in local currencies.

## Overview

CheeseVault is a smart contract system built on Polygon that manages user deposits in USDC and processes bill payments with configurable fees. Each user gets their own wallet contract for holding funds, and the backend handles fiat conversion off-chain.

### Architecture

- **UserWallet**: Individual wallet contract for each user to hold USDC
- **UserWalletFactory**: Deploys and manages UserWallet contracts
- **CheeseVault**: Processes payments, manages fees, and tracks vault funds

## Setup

### Prerequisites

- [Foundry](https://book.getfoundry.sh/getting-started/installation)

### Installation
```bash
# Clone the repository
git clone <repository-url>
cd cheese

# Install dependencies
forge install

# Copy environment variables
cp .env.example .env
```

### Environment Variables

Configure your `.env` file:
```bash
DEPLOYER_PRIVATE_KEY=your_private_key
POLYGON_AMOY_RPC_URL=https://rpc-amoy.polygon.technology
POLYGON_RPC_URL=https://polygon-rpc.com
POLYGONSCAN_API_KEY=your_polygonscan_api_key

# USDC Addresses
USDC_ADDRESS_AMOY=0x41E94Eb019C0762f9Bfcf9Fb1E58725BfB0e7582
USDC_ADDRESS_MAINNET=0x3c499c542cEF5E3811e1192ce70d8cC03d5c3359
```

### Build
```bash
forge build
```

### Test
```bash
# Run all tests
forge test

# Run tests with verbosity
forge test -vv

# Run specific test file
forge test --match-path test/CheeseVault.t.sol -vv

# Run fuzz tests
forge test --match-path test/CheeseVault.fuzz.t.sol --fuzz-runs 10000

# Run fork tests
forge test --match-path test/CheeseVault.fork.t.sol --fork-url $POLYGON_AMOY_RPC_URL
```

### Deploy
```bash
# Deploy to Amoy testnet
forge script script/DeployAll.s.sol:DeployAll \
  --rpc-url $POLYGON_AMOY_RPC_URL \
  --broadcast \
  --verify \
  -vvvv

# Deploy to Polygon mainnet
forge script script/DeployAll.s.sol:DeployAll \
  --rpc-url $POLYGON_RPC_URL \
  --broadcast \
  --verify \
  -vvvv
```

## Deployed Contracts (Amoy Testnet)

- **CheeseVault**: `0x3D391efD7a2112fa537E273aD3B2F21F14B57863`
- **UserWalletFactory**: `0xdeC9Da462AC872B148a44735FbB0364df4A8bb15`
- **USDC**: `0x41E94Eb019C0762f9Bfcf9Fb1E58725BfB0e7582`

**Network**: Polygon Amoy Testnet (Chain ID: 80002)

**Explorer**: [Amoy Polygonscan](https://amoy.polygonscan.com/)

## Documentation

See [Integration Guide](./docs/integration-guide.md) for detailed API documentation.

## Project Structure
```
cheese/
├── src/
│   ├── CheeseVault.sol           # Main vault contract
│   ├── UserWallet.sol            # Individual user wallet
│   ├── UserWalletFactory.sol     # Factory for creating wallets
│   └── interfaces/
│       ├── ICheeseVault.sol      # Vault interface
│       └── IUserWallet.sol       # Wallet interface
├── test/
│   ├── CheeseVault.t.sol         # Unit tests
│   ├── CheeseVault.fork.t.sol    # Fork tests
│   ├── CheeseVault.fuzz.t.sol    # Fuzz tests
│   ├── UserWallet.t.sol          # Wallet tests
│   └── UserWalletFactory.t.sol   # Factory tests
├── script/
│   └── DeployAll.s.sol           # Deployment script
└── docs/
    └── integration-guide.md       # Integration documentation
```

## License

MIT
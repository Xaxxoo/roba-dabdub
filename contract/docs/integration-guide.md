# Integration Guide

This guide documents the external functions for integrating with the CheeseVault system.

## Contract Addresses (Amoy Testnet)

- **CheeseVault**: `0x3D391efD7a2112fa537E273aD3B2F21F14B57863`
- **UserWalletFactory**: `0xdeC9Da462AC872B148a44735FbB0364df4A8bb15`
- **USDC Token**: `0x41E94Eb019C0762f9Bfcf9Fb1E58725BfB0e7582`

---

## UserWalletFactory

Factory contract for creating and managing user wallets.

### createWallet

**Purpose**: Create a new wallet for a user

**Who can call**: Backend operator only

**Parameters**:
- `userId` (string): Unique user identifier (e.g., email, user ID)

**Returns**: Address of the newly created wallet

**Usage**: Call this when a new user signs up to create their personal wallet contract.

---

### getWallet

**Purpose**: Retrieve wallet address for a user

**Who can call**: Anyone

**Parameters**:
- `userId` (string): User identifier used during wallet creation

**Returns**: Wallet address (returns `address(0)` if wallet doesn't exist)

**Usage**: Use this to check if a user has a wallet and get their wallet address.

---

### hasWallet

**Purpose**: Check if a user has a wallet

**Who can call**: Anyone

**Parameters**:
- `userId` (string): User identifier

**Returns**: `true` if wallet exists, `false` otherwise

**Usage**: Quick check before creating a wallet to avoid duplicates.

---

### getTotalWallets

**Purpose**: Get total number of wallets created

**Who can call**: Anyone

**Returns**: Total wallet count

**Usage**: Analytics and monitoring.

---

### updateBackend

**Purpose**: Change the backend operator address

**Who can call**: Contract owner only

**Parameters**:
- `newBackend` (address): New backend operator address

**Usage**: Use if backend private key needs to be rotated.

---

### updateVault

**Purpose**: Update the CheeseVault address

**Who can call**: Contract owner only

**Parameters**:
- `newVault` (address): New vault contract address

**Usage**: Use if vault contract needs to be upgraded.

---

## UserWallet

Individual wallet contract for each user to hold USDC.

### getBalance

**Purpose**: Get USDC balance in wallet

**Who can call**: Anyone

**Returns**: Current USDC balance in the wallet

**Usage**: Display user's available balance in the app.

---

### transferToVault

**Purpose**: Transfer USDC to vault for bill payment (automatically includes fee)

**Who can call**: Backend operator or Vault contract

**Parameters**:
- `paymentAmount` (uint256): Bill amount in USDC (6 decimals, e.g., 50e6 = $50)

**Returns**: Total amount transferred (payment + fee)

**Usage**: Called automatically by CheeseVault's `processPayment` function. Backend should not call this directly.

---

### withdraw

**Purpose**: Withdraw USDC from wallet to external address

**Who can call**: Backend operator or wallet owner

**Parameters**:
- `amount` (uint256): Amount to withdraw (6 decimals)
- `recipient` (address): Address to receive the USDC

**Usage**: When user requests withdrawal to their personal wallet.

---

### emergencyWithdraw

**Purpose**: Emergency withdrawal of all funds (safety mechanism)

**Who can call**: Wallet owner only

**Returns**: Sends all USDC to the owner address

**Usage**: User can recover funds if backend is compromised (requires owner to be set first).

---

### setOwner

**Purpose**: Set or update the wallet owner address

**Who can call**: Backend operator only

**Parameters**:
- `newOwner` (address): New owner address

**Usage**: Allow users to set a recovery address or transition to self-custody.

---

## CheeseVault

Main vault contract that processes payments and manages funds.

### processPayment

**Purpose**: Process a bill payment (pulls funds from user wallet automatically)

**Who can call**: Backend operator only

**Parameters**:
- `userWallet` (address): Address of the user's wallet contract
- `paymentAmount` (uint256): Bill amount in USDC (6 decimals)
- `paymentId` (bytes32): Unique payment identifier for tracking

**Usage**: Backend calls this when processing a bill payment. This function automatically calls the user wallet's `transferToVault` to pull the payment amount plus fee.

---

### refundPayment

**Purpose**: Refund a failed payment to user's wallet

**Who can call**: Admin only

**Parameters**:
- `userWallet` (address): User's wallet address
- `paymentAmount` (uint256): Amount to refund (6 decimals)
- `refundFee` (bool): Whether to also refund the fee
- `paymentId` (bytes32): Original payment identifier

**Usage**: When a payment fails off-chain (e.g., payment processor error), admin can refund the user.

---

### withdrawVaultFunds

**Purpose**: Withdraw processed payments and collected fees

**Who can call**: Treasurer only

**Parameters**:
- `to` (address): Address to receive the funds

**Usage**: Treasurer withdraws accumulated payments and fees to company wallet for business operations.

---

### setFee

**Purpose**: Update the transaction fee amount

**Who can call**: Admin only

**Parameters**:
- `newFee` (uint256): New fee amount in USDC (max $5, 6 decimals)

**Usage**: Adjust fee based on operational costs or business needs.

---

### setMinDeposit

**Purpose**: Update the minimum deposit requirement

**Who can call**: Admin only

**Parameters**:
- `newMinDeposit` (uint256): New minimum deposit in USDC (6 decimals)

**Usage**: Adjust minimum deposit threshold for business rules.

---

### pause / unpause

**Purpose**: Emergency pause/unpause all vault operations

**Who can call**: Contract owner only

**Usage**: Emergency stop in case of security incident or critical bug.

---

### getAvailableWithdrawal

**Purpose**: Get amounts available for withdrawal by treasurer

**Who can call**: Anyone

**Returns**: 
- `payments` (uint256): Available processed payments
- `fees` (uint256): Available collected fees
- `total` (uint256): Total available (payments + fees)

**Usage**: Check how much the treasurer can withdraw.

---

### verifyVaultAccounting

**Purpose**: Verify vault's accounting integrity

**Who can call**: Anyone

**Returns**: `true` if vault balance matches accounting, `false` if mismatch

**Usage**: Health check to ensure vault's internal accounting matches actual USDC balance.

---

## Roles & Access Control

### CheeseVault Roles

- **DEFAULT_ADMIN_ROLE**: Owner/deployer, can assign other roles and pause contract
- **ADMIN_ROLE**: Can set fees, minimum deposit, and process refunds
- **OPERATOR_ROLE**: Can process payments (backend wallet)
- **TREASURER_ROLE**: Can withdraw vault funds

### UserWalletFactory Roles

- **Owner**: Contract deployer, can update backend and vault addresses
- **Backend**: Can create wallets (operator role)

### UserWallet Access

- **Backend**: Can transfer to vault, withdraw, set owner
- **Owner**: Can withdraw, emergency withdraw (if set)
- **Vault**: Can pull funds via transferToVault

---

## Typical Integration Flow

### 1. User Signs Up
```
Backend → UserWalletFactory.createWallet(email)
Response: userWalletAddress
Store: email → userWalletAddress mapping
```

### 2. User Deposits USDC
```
User → Sends USDC to their userWalletAddress (from any wallet)
Backend → Listens for USDC transfer events
Backend → Updates database balance
```

### 3. User Pays Bill
```
User → Clicks "Pay Bill" in app
Backend → CheeseVault.processPayment(userWalletAddress, amount, billId)
  ↳ Internally calls userWallet.transferToVault()
  ↳ Deducts amount + fee from wallet
  ↳ Updates vault accounting
Backend → Pays actual bill via payment processor
Backend → Updates database
```

### 4. User Withdraws
```
User → Requests withdrawal
Backend → UserWallet.withdraw(amount, userExternalWallet)
User → Receives USDC in their external wallet
```

### 5. Treasurer Withdraws Company Funds
```
Treasurer → CheeseVault.withdrawVaultFunds(companyWallet)
Company receives all processed payments + fees
```

---

## Error Handling

All functions revert with descriptive error messages on failure. Common errors:

- `"Only backend"`: Caller is not authorized
- `"Insufficient balance"`: Not enough USDC in wallet
- `"Invalid wallet address"`: Zero address or invalid input
- `"Payment amount must be greater than 0"`: Invalid payment amount
- `"Fee exceeds maximum"`: Fee above $5 limit
- `"Wallet already exists"`: Attempting to create duplicate wallet

---

## Events

### UserWalletFactory Events

- `WalletCreated(bytes32 userIdHash, address wallet, uint256 timestamp)`: New wallet created
- `BackendUpdated(address oldBackend, address newBackend)`: Backend address changed
- `VaultUpdated(address oldVault, address newVault)`: Vault address changed

### UserWallet Events

- `TransferredToVault(uint256 paymentAmount, uint256 feeAmount, uint256 totalAmount, uint256 timestamp)`: Funds sent to vault
- `Withdrawal(address recipient, uint256 amount, uint256 timestamp)`: USDC withdrawn
- `OwnerUpdated(address oldOwner, address newOwner)`: Owner changed
- `EmergencyWithdrawal(uint256 amount, uint256 timestamp)`: Emergency withdrawal executed

### CheeseVault Events

- `PaymentProcessed(address userWallet, bytes32 paymentId, uint256 paymentAmount, uint256 feeAmount, uint256 remainingBalance)`: Payment processed
- `PaymentRefunded(address userWallet, bytes32 paymentId, uint256 refundAmount, uint256 newBalance)`: Payment refunded
- `VaultFundsWithdrawn(address treasurer, address to, uint256 paymentsAmount, uint256 feesAmount, uint256 totalAmount)`: Vault funds withdrawn
- `FeeUpdated(uint256 oldFee, uint256 newFee)`: Fee changed
- `MinDepositUpdated(uint256 oldMinDeposit, uint256 newMinDeposit)`: Minimum deposit changed
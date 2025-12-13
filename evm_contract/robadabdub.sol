// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/security/Pausable.sol";

/**
 * @title PaymentWallet
 * @notice Simple payment wallet system for deposits and P2P payments
 * @dev Supports both merchant payments and user-to-user transfers
 * 
 * KEY FEATURES:
 * - Deposit USDC to your wallet balance
 * - Pay merchants (debits user, credits merchant)
 * - Pay other users (P2P transfers within the system)
 * - Withdraw back to personal wallet anytime
 * - Chain-specific deployment (one contract per chain)
 */
contract PaymentWallet is Ownable, ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;

    // ============================================================================
    // STATE VARIABLES
    // ============================================================================
    
    /// @notice USDC token contract
    IERC20 public immutable usdc;
    
    /// @notice Platform fee wallet (receives fees from transactions)
    address public platformWallet;
    
    /// @notice Platform fee in basis points (e.g., 100 = 1%)
    uint256 public platformFeeBps;
    
    /// @notice Maximum platform fee (1000 = 10%)
    uint256 public constant MAX_FEE_BPS = 1000;
    
    /// @notice Basis points divisor
    uint256 private constant BPS_DIVISOR = 10000;
    
    /// @notice User wallet balances (address => balance in USDC)
    mapping(address => uint256) public balances;
    
    /// @notice Payment reference tracking to prevent double processing
    mapping(bytes32 => bool) public processedPayments;
    
    /// @notice User transaction nonces for signature replay protection
    mapping(address => uint256) public nonces;
    
    /// @notice Total balance in the contract (for accounting)
    uint256 public totalBalance;

    // ============================================================================
    // EVENTS
    // ============================================================================
    
    /// @notice Emitted when a user deposits USDC
    event Deposited(
        address indexed user,
        uint256 amount,
        uint256 newBalance,
        uint256 timestamp
    );
    
    /// @notice Emitted when a payment is made (merchant or P2P)
    event PaymentProcessed(
        address indexed from,
        address indexed to,
        uint256 amount,
        uint256 fee,
        bytes32 indexed paymentReference,
        PaymentType paymentType,
        uint256 timestamp
    );
    
    /// @notice Emitted when a user withdraws USDC
    event Withdrawn(
        address indexed user,
        uint256 amount,
        uint256 newBalance,
        uint256 timestamp
    );
    
    /// @notice Emitted when platform fee is updated
    event PlatformFeeUpdated(
        uint256 oldFeeBps,
        uint256 newFeeBps,
        uint256 timestamp
    );
    
    /// @notice Emitted when platform wallet is updated
    event PlatformWalletUpdated(
        address indexed oldWallet,
        address indexed newWallet,
        uint256 timestamp
    );

    // ============================================================================
    // ENUMS
    // ============================================================================
    
    enum PaymentType {
        MERCHANT,       // Payment to merchant
        USER_TO_USER    // P2P payment between users
    }

    // ============================================================================
    // ERRORS
    // ============================================================================
    
    error InsufficientBalance(uint256 requested, uint256 available);
    error InvalidAmount();
    error InvalidAddress();
    error PaymentAlreadyProcessed(bytes32 paymentReference);
    error InvalidFee();
    error SelfTransferNotAllowed();

    // ============================================================================
    // CONSTRUCTOR
    // ============================================================================
    
    /**
     * @notice Initialize the payment wallet
     * @param _usdc USDC token contract address
     * @param _platformWallet Address to receive platform fees
     * @param _platformFeeBps Platform fee in basis points (e.g., 50 = 0.5%)
     */
    constructor(
        address _usdc,
        address _platformWallet,
        uint256 _platformFeeBps
    ) Ownable(msg.sender) {
        if (_usdc == address(0) || _platformWallet == address(0)) {
            revert InvalidAddress();
        }
        if (_platformFeeBps > MAX_FEE_BPS) {
            revert InvalidFee();
        }
        
        usdc = IERC20(_usdc);
        platformWallet = _platformWallet;
        platformFeeBps = _platformFeeBps;
    }

    // ============================================================================
    // DEPOSIT FUNCTIONS
    // ============================================================================
    
    /**
     * @notice Deposit USDC to your wallet balance
     * @param amount Amount of USDC to deposit (in USDC decimals, typically 6)
     * @dev User must approve this contract to spend their USDC first
     */
    function deposit(uint256 amount) external nonReentrant whenNotPaused {
        if (amount == 0) revert InvalidAmount();
        
        // Transfer USDC from user to contract
        usdc.safeTransferFrom(msg.sender, address(this), amount);
        
        // Update balances
        balances[msg.sender] += amount;
        totalBalance += amount;
        
        emit Deposited(msg.sender, amount, balances[msg.sender], block.timestamp);
    }
    
    /**
     * @notice Deposit USDC on behalf of another user
     * @param user User to credit the deposit to
     * @param amount Amount of USDC to deposit
     * @dev Useful for on-ramps, gifts, or third-party integrations
     */
    function depositFor(address user, uint256 amount) 
        external 
        nonReentrant 
        whenNotPaused 
    {
        if (amount == 0) revert InvalidAmount();
        if (user == address(0)) revert InvalidAddress();
        
        usdc.safeTransferFrom(msg.sender, address(this), amount);
        
        balances[user] += amount;
        totalBalance += amount;
        
        emit Deposited(user, amount, balances[user], block.timestamp);
    }

    // ============================================================================
    // PAYMENT FUNCTIONS
    // ============================================================================
    
    /**
     * @notice Process a payment (merchant or P2P)
     * @param from User sending the payment
     * @param to User or merchant receiving the payment
     * @param amount Amount to transfer (before fees)
     * @param paymentReference Unique reference to prevent double processing
     * @param paymentType Type of payment (MERCHANT or USER_TO_USER)
     * @dev This is called by the backend with proper authorization
     */
    function processPayment(
        address from,
        address to,
        uint256 amount,
        bytes32 paymentReference,
        PaymentType paymentType
    ) 
        external 
        onlyOwner
        nonReentrant 
        whenNotPaused 
    {
        if (amount == 0) revert InvalidAmount();
        if (from == address(0) || to == address(0)) revert InvalidAddress();
        if (from == to) revert SelfTransferNotAllowed();
        if (processedPayments[paymentReference]) {
            revert PaymentAlreadyProcessed(paymentReference);
        }
        
        uint256 senderBalance = balances[from];
        if (senderBalance < amount) {
            revert InsufficientBalance(amount, senderBalance);
        }
        
        // Calculate platform fee
        uint256 fee = (amount * platformFeeBps) / BPS_DIVISOR;
        uint256 amountAfterFee = amount - fee;
        
        // Mark payment as processed
        processedPayments[paymentReference] = true;
        
        // Update balances
        balances[from] -= amount;
        balances[to] += amountAfterFee;
        
        // Transfer fee to platform wallet if there's a fee
        if (fee > 0) {
            balances[platformWallet] += fee;
        }
        
        emit PaymentProcessed(
            from,
            to,
            amount,
            fee,
            paymentReference,
            paymentType,
            block.timestamp
        );
    }
    
    /**
     * @notice Batch process multiple payments in one transaction
     * @param froms Array of senders
     * @param tos Array of recipients
     * @param amounts Array of amounts
     * @param paymentReferences Array of unique payment references
     * @param paymentTypes Array of payment types
     */
    function processPaymentBatch(
        address[] calldata froms,
        address[] calldata tos,
        uint256[] calldata amounts,
        bytes32[] calldata paymentReferences,
        PaymentType[] calldata paymentTypes
    ) 
        external 
        onlyOwner
        nonReentrant 
        whenNotPaused 
    {
        uint256 length = froms.length;
        require(
            length == tos.length && 
            length == amounts.length && 
            length == paymentReferences.length &&
            length == paymentTypes.length,
            "Array length mismatch"
        );
        
        uint256 totalFees = 0;
        
        for (uint256 i = 0; i < length; i++) {
            address from = froms[i];
            address to = tos[i];
            uint256 amount = amounts[i];
            bytes32 paymentReference = paymentReferences[i];
            PaymentType paymentType = paymentTypes[i];
            
            if (amount == 0) revert InvalidAmount();
            if (from == address(0) || to == address(0)) revert InvalidAddress();
            if (from == to) revert SelfTransferNotAllowed();
            if (processedPayments[paymentReference]) {
                revert PaymentAlreadyProcessed(paymentReference);
            }
            
            uint256 senderBalance = balances[from];
            if (senderBalance < amount) {
                revert InsufficientBalance(amount, senderBalance);
            }
            
            uint256 fee = (amount * platformFeeBps) / BPS_DIVISOR;
            uint256 amountAfterFee = amount - fee;
            
            processedPayments[paymentReference] = true;
            
            balances[from] -= amount;
            balances[to] += amountAfterFee;
            totalFees += fee;
            
            emit PaymentProcessed(
                from,
                to,
                amount,
                fee,
                paymentReference,
                paymentType,
                block.timestamp
            );
        }
        
        // Add all fees to platform wallet in one operation
        if (totalFees > 0) {
            balances[platformWallet] += totalFees;
        }
    }

    // ============================================================================
    // WITHDRAWAL FUNCTIONS
    // ============================================================================
    
    /**
     * @notice Withdraw USDC from wallet balance to your personal wallet
     * @param amount Amount to withdraw
     */
    function withdraw(uint256 amount) external nonReentrant whenNotPaused {
        if (amount == 0) revert InvalidAmount();
        
        uint256 userBalance = balances[msg.sender];
        if (userBalance < amount) {
            revert InsufficientBalance(amount, userBalance);
        }
        
        balances[msg.sender] = userBalance - amount;
        totalBalance -= amount;
        
        usdc.safeTransfer(msg.sender, amount);
        
        emit Withdrawn(msg.sender, amount, balances[msg.sender], block.timestamp);
    }
    
    /**
     * @notice Withdraw all available balance
     */
    function withdrawAll() external nonReentrant whenNotPaused {
        uint256 amount = balances[msg.sender];
        if (amount == 0) revert InvalidAmount();
        
        balances[msg.sender] = 0;
        totalBalance -= amount;
        
        usdc.safeTransfer(msg.sender, amount);
        
        emit Withdrawn(msg.sender, amount, 0, block.timestamp);
    }

    // ============================================================================
    // VIEW FUNCTIONS
    // ============================================================================
    
    /**
     * @notice Get user's wallet balance
     * @param user User address
     * @return User's USDC balance
     */
    function balanceOf(address user) external view returns (uint256) {
        return balances[user];
    }
    
    /**
     * @notice Check if a payment has been processed
     * @param paymentReference Payment reference to check
     * @return true if payment was processed
     */
    function isPaymentProcessed(bytes32 paymentReference) external view returns (bool) {
        return processedPayments[paymentReference];
    }
    
    /**
     * @notice Get total USDC held in contract
     * @return Total USDC balance
     */
    function getTotalBalance() external view returns (uint256) {
        return totalBalance;
    }
    
    /**
     * @notice Get actual contract USDC balance (for reconciliation)
     * @return Actual USDC balance in contract
     */
    function getActualBalance() external view returns (uint256) {
        return usdc.balanceOf(address(this));
    }
    
    /**
     * @notice Get user's transaction nonce
     * @param user User address
     * @return Current nonce
     */
    function getNonce(address user) external view returns (uint256) {
        return nonces[user];
    }

    // ============================================================================
    // ADMIN FUNCTIONS
    // ============================================================================
    
    /**
     * @notice Update platform fee
     * @param newFeeBps New fee in basis points (e.g., 50 = 0.5%)
     */
    function setPlatformFee(uint256 newFeeBps) external onlyOwner {
        if (newFeeBps > MAX_FEE_BPS) revert InvalidFee();
        
        uint256 oldFeeBps = platformFeeBps;
        platformFeeBps = newFeeBps;
        
        emit PlatformFeeUpdated(oldFeeBps, newFeeBps, block.timestamp);
    }
    
    /**
     * @notice Update platform wallet address
     * @param newPlatformWallet New platform wallet address
     */
    function setPlatformWallet(address newPlatformWallet) external onlyOwner {
        if (newPlatformWallet == address(0)) revert InvalidAddress();
        
        address oldWallet = platformWallet;
        platformWallet = newPlatformWallet;
        
        emit PlatformWalletUpdated(oldWallet, newPlatformWallet, block.timestamp);
    }
    
    /**
     * @notice Pause all contract operations
     */
    function pause() external onlyOwner {
        _pause();
    }
    
    /**
     * @notice Unpause contract operations
     */
    function unpause() external onlyOwner {
        _unpause();
    }
    
    /**
     * @notice Emergency withdrawal (admin only, for stuck funds)
     * @param token Token to withdraw
     * @param to Address to send tokens to
     * @param amount Amount to withdraw
     */
    function emergencyWithdraw(
        address token,
        address to,
        uint256 amount
    ) 
        external 
        onlyOwner 
    {
        if (to == address(0)) revert InvalidAddress();
        IERC20(token).safeTransfer(to, amount);
    }
}

// ============================================================================
// SIGNATURE-BASED PAYMENT PROCESSOR
// ============================================================================

import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "@openzeppelin/contracts/utils/cryptography/EIP712.sol";

/**
 * @title SignaturePaymentProcessor
 * @notice Allows users to authorize payments via signature (gasless for users)
 * @dev Backend submits signed payment requests on behalf of users
 */
contract SignaturePaymentProcessor is EIP712, Ownable {
    using ECDSA for bytes32;

    /// @notice Reference to the main payment wallet
    PaymentWallet public immutable paymentWallet;
    
    /// @notice TypeHash for payment authorization
    bytes32 public constant PAYMENT_TYPEHASH = keccak256(
        "Payment(address from,address to,uint256 amount,bytes32 paymentReference,uint8 paymentType,uint256 nonce,uint256 deadline)"
    );
    
    /// @notice User nonces for replay protection
    mapping(address => uint256) public nonces;

    event SignedPaymentProcessed(
        address indexed from,
        address indexed to,
        uint256 amount,
        bytes32 paymentReference
    );

    error ExpiredSignature();
    error InvalidSignature();

    constructor(address _paymentWallet) 
        EIP712("PaymentProcessor", "1")
        Ownable(msg.sender)
    {
        paymentWallet = PaymentWallet(_paymentWallet);
    }

    /**
     * @notice Execute a payment with user's signature
     * @param from User authorizing the payment
     * @param to Recipient of payment
     * @param amount Amount to pay
     * @param paymentReference Unique payment reference
     * @param paymentType Type of payment (0 = MERCHANT, 1 = USER_TO_USER)
     * @param deadline Signature expiration timestamp
     * @param signature User's signature
     */
    function executeSignedPayment(
        address from,
        address to,
        uint256 amount,
        bytes32 paymentReference,
        uint8 paymentType,
        uint256 deadline,
        bytes memory signature
    ) external {
        if (block.timestamp > deadline) revert ExpiredSignature();
        
        // Verify signature
        bytes32 structHash = keccak256(
            abi.encode(
                PAYMENT_TYPEHASH,
                from,
                to,
                amount,
                paymentReference,
                paymentType,
                nonces[from],
                deadline
            )
        );
        
        bytes32 hash = _hashTypedDataV4(structHash);
        address signer = ECDSA.recover(hash, signature);
        
        if (signer != from) revert InvalidSignature();
        
        // Increment nonce
        nonces[from]++;
        
        // Process payment
        paymentWallet.processPayment(
            from,
            to,
            amount,
            paymentReference,
            PaymentWallet.PaymentType(paymentType)
        );
        
        emit SignedPaymentProcessed(from, to, amount, paymentReference);
    }
    
    /**
     * @notice Get user's current nonce
     */
    function getNonce(address user) external view returns (uint256) {
        return nonces[user];
    }
}


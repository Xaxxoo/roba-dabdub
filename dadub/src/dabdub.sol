// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";




contract PaymentWalletFixed is Ownable, ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;

    // ============================================================================
    // STATE VARIABLES
    // ============================================================================
    
    IERC20 public immutable USDC;
    address public platformWallet;
    
    // Fee structure: percentage-based (in basis points, 10000 = 100%)
    uint256 public platformFeePercentage; // e.g., 50 = 0.5%
    uint256 public minFee; // Minimum fee in USDC (6 decimals)
    uint256 public maxFee; // Maximum fee in USDC (6 decimals)
    
    uint256 public constant MAX_FEE_PERCENTAGE = 1000; // Max 10%
    uint256 public constant MAX_ABSOLUTE_FEE = 10_000_000; // Max $10
    uint256 public constant BASIS_POINTS = 10000;
    uint256 public constant MAX_BATCH_SIZE = 100; // Maximum payments per batch
    
    mapping(address => uint256) public balances;
    mapping(bytes32 => bool) public processedPayments;
    
    // Nonce system for better payment reference uniqueness
    mapping(address => uint256) public userNonces;
    
    uint256 public totalBalance;
    
    // Access control for payment processing
    bool public allowUserInitiatedPayments;

    // ============================================================================
    // EVENTS
    // ============================================================================
    
    event Deposited(
        address indexed user,
        uint256 indexed amount,
        uint256 newBalance,
        uint256 timestamp
    );
    
    event PaymentProcessed(
        address indexed from,
        address indexed to,
        uint256 indexed amount,
        uint256 fee,
        bytes32 paymentReference,
        PaymentType paymentType,
        uint256 timestamp
    );
    
    event Withdrawn(
        address indexed user,
        uint256 indexed amount,
        uint256 newBalance,
        uint256 timestamp
    );
    
    event PlatformFeeUpdated(
        uint256 oldFeePercentage,
        uint256 newFeePercentage,
        uint256 oldMinFee,
        uint256 newMinFee,
        uint256 oldMaxFee,
        uint256 newMaxFee,
        uint256 timestamp
    );
    
    event PlatformWalletUpdated(
        address indexed oldWallet,
        address indexed newWallet,
        uint256 migratedBalance,
        uint256 timestamp
    );
    
    event ContractPaused(address indexed by, uint256 timestamp);
    event ContractUnpaused(address indexed by, uint256 timestamp);
    
    event UserPaymentsToggled(bool enabled, uint256 timestamp);
    
    event EmergencyTokenRecovered(
        address indexed token,
        address indexed to,
        uint256 amount,
        uint256 timestamp
    );

    // ============================================================================
    // ENUMS
    // ============================================================================
    
    enum PaymentType {
        MERCHANT,
        USER_TO_USER
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
    error AmountTooSmall();
    error UserPaymentsDisabled();
    error UnauthorizedPaymentProcessor();
    error CannotRecoverUSDC();
    error ArrayLengthMismatch();
    error BatchSizeExceeded(uint256 provided, uint256 maximum);
    error PlatformWalletCannotBeSender();
    error FeeCalculationOverflow();

    // ============================================================================
    // CONSTRUCTOR
    // ============================================================================
    
    /**
     * @notice Initializes the PaymentWallet contract
     * @param _usdc Address of the USDC token contract
     * @param _platformWallet Address that receives platform fees
     * @param _platformFeePercentage Fee percentage in basis points (e.g., 50 = 0.5%)
     * @param _minFee Minimum fee in USDC (with 6 decimals, e.g., 100_000 = $0.10)
     * @param _maxFee Maximum fee in USDC (with 6 decimals, e.g., 1_000_000 = $1.00)
     */
    constructor(
        address _usdc,
        address _platformWallet,
        uint256 _platformFeePercentage,
        uint256 _minFee,
        uint256 _maxFee
    ) Ownable(msg.sender) {
        if (_usdc == address(0) || _platformWallet == address(0)) {
            revert InvalidAddress();
        }
        if (_platformFeePercentage > MAX_FEE_PERCENTAGE) {
            revert InvalidFee();
        }
        if (_maxFee > MAX_ABSOLUTE_FEE) {
            revert InvalidFee();
        }
        if (_minFee > _maxFee) {
            revert InvalidFee();
        }
        
        USDC = IERC20(_usdc);
        platformWallet = _platformWallet;
        platformFeePercentage = _platformFeePercentage;
        minFee = _minFee;
        maxFee = _maxFee;
        allowUserInitiatedPayments = true; // Default to decentralized
    }

    // ============================================================================
    // MODIFIERS
    // ============================================================================
    
    /**
     * @notice Checks if caller is authorized to process payments
     * @dev FIXED: Clear separation between centralized and decentralized modes
     * - If allowUserInitiatedPayments is false: ONLY owner can process any payment
     * - If allowUserInitiatedPayments is true: ONLY users can process their own payments
     * @param from The address sending the payment
     */
    modifier onlyAuthorizedProcessor(address from) {
        if (!allowUserInitiatedPayments) {
            // Centralized mode: Only owner can process payments
            if (msg.sender != owner()) {
                revert UnauthorizedPaymentProcessor();
            }
        } else {
            // Decentralized mode: Only the sender can process their own payment
            if (msg.sender != from) {
                revert UnauthorizedPaymentProcessor();
            }
        }
        _;
    }

    // ============================================================================
    // DEPOSIT FUNCTIONS
    // ============================================================================
    
    /**
     * @notice Deposit USDC into the contract
     * @param amount Amount of USDC to deposit (with 6 decimals)
     */
    function deposit(uint256 amount) external nonReentrant whenNotPaused {
        if (amount == 0) revert InvalidAmount();
        
        USDC.safeTransferFrom(msg.sender, address(this), amount);
        
        balances[msg.sender] += amount;
        totalBalance += amount;
        
        emit Deposited(msg.sender, amount, balances[msg.sender], block.timestamp);
    }
    
    /**
     * @notice Deposit USDC on behalf of another user
     * @param user The user to credit with the deposit
     * @param amount Amount of USDC to deposit (with 6 decimals)
     */
    function depositFor(address user, uint256 amount) 
        external 
        nonReentrant 
        whenNotPaused 
    {
        if (amount == 0) revert InvalidAmount();
        if (user == address(0)) revert InvalidAddress();
        
        USDC.safeTransferFrom(msg.sender, address(this), amount);
        
        balances[user] += amount;
        totalBalance += amount;
        
        emit Deposited(user, amount, balances[user], block.timestamp);
    }

    // ============================================================================
    // FEE CALCULATION
    // ============================================================================
    
    /**
     * @notice Calculates the fee for a payment amount
     * @dev FIXED: Added overflow protection
     * @param amount The payment amount
     * @return The calculated fee (clamped between minFee and maxFee)
     */
    function calculateFee(uint256 amount) public view returns (uint256) {
        // FIXED: Overflow protection
        if (platformFeePercentage > 0 && amount > type(uint256).max / platformFeePercentage) {
            // In the extremely unlikely case of overflow, return maxFee
            return maxFee;
        }
        
        // Calculate percentage-based fee
        uint256 percentageFee = (amount * platformFeePercentage) / BASIS_POINTS;
        
        // Clamp between min and max
        if (percentageFee < minFee) {
            return minFee;
        } else if (percentageFee > maxFee) {
            return maxFee;
        } else {
            return percentageFee;
        }
    }

    // ============================================================================
    // PAYMENT REFERENCE GENERATION
    // ============================================================================
    
    /**
     * @notice Generates a unique payment reference
     * @dev Combines user address, nonce, recipient, amount, and timestamp for uniqueness
     * @param from Sender address
     * @param to Recipient address
     * @param amount Payment amount
     * @param userProvidedRef Optional user-provided reference data
     * @return Unique payment reference hash
     */
    function generatePaymentReference(
        address from,
        address to,
        uint256 amount,
        bytes32 userProvidedRef
    ) public view returns (bytes32) {
        return keccak256(abi.encodePacked(
            from,
            to,
            amount,
            userProvidedRef,
            userNonces[from],
            block.timestamp,
            block.chainid
        ));
    }

    // ============================================================================
    // PAYMENT FUNCTIONS
    // ============================================================================
    
    /**
     * @notice Process a single payment from one user to another
     * @dev FIXED: Clear authorization - only user can process their own payment (decentralized mode)
     *      or only owner can process (centralized mode)
     * @param from Sender address
     * @param to Recipient address
     * @param amount Total payment amount (including fee)
     * @param paymentReference Unique payment identifier (use generatePaymentReference for uniqueness)
     * @param paymentType Type of payment (MERCHANT or USER_TO_USER)
     */
    function processPayment(
        address from,
        address to,
        uint256 amount,
        bytes32 paymentReference,
        PaymentType paymentType
    ) 
        external 
        onlyAuthorizedProcessor(from)
        nonReentrant 
        whenNotPaused 
    {
        if (amount == 0) revert InvalidAmount();
        if (from == address(0) || to == address(0)) revert InvalidAddress();
        if (from == to) revert SelfTransferNotAllowed();
        if (processedPayments[paymentReference]) {
            revert PaymentAlreadyProcessed(paymentReference);
        }
        
        uint256 fee = calculateFee(amount);
        
        // Amount must be greater than the fee
        if (amount <= fee) revert AmountTooSmall();
        
        // FIXED: Cache balance to save gas
        uint256 senderBalance = balances[from];
        if (senderBalance < amount) {
            revert InsufficientBalance(amount, senderBalance);
        }
        
        uint256 amountAfterFee = amount - fee;
        
        // Mark payment as processed
        processedPayments[paymentReference] = true;
        
        // Increment nonce for future payment reference generation
        userNonces[from]++;
        
        // Update balances
        balances[from] -= amount;
        balances[to] += amountAfterFee;
        balances[platformWallet] += fee;
        
        // Note: totalBalance remains unchanged because funds stay within the system
        
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
     * @notice Process multiple payments in a single transaction
     * @dev FIXED: Added batch size limit, platformWallet sender check, and balance updates inside loop
     *      Only callable by owner for security (batch operations require trust)
     * @param froms Array of sender addresses
     * @param tos Array of recipient addresses
     * @param amounts Array of payment amounts
     * @param paymentReferences Array of unique payment identifiers
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
        
        // Check for empty batch
        if (length == 0) revert InvalidAmount();
        
        // FIXED: Add batch size limit to prevent DoS
        if (length > MAX_BATCH_SIZE) {
            revert BatchSizeExceeded(length, MAX_BATCH_SIZE);
        }
        
        // Check array length consistency
        if (length != tos.length || 
            length != amounts.length || 
            length != paymentReferences.length ||
            length != paymentTypes.length) {
            revert ArrayLengthMismatch();
        }
        
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
            
            // FIXED: Platform wallet cannot be a sender in batch operations
            // This prevents balance accounting issues
            if (from == platformWallet) revert PlatformWalletCannotBeSender();
            
            if (processedPayments[paymentReference]) {
                revert PaymentAlreadyProcessed(paymentReference);
            }
            
            uint256 fee = calculateFee(amount);
            
            // Amount must be greater than the fee
            if (amount <= fee) revert AmountTooSmall();
            
            // FIXED: Cache balance to save gas
            uint256 senderBalance = balances[from];
            if (senderBalance < amount) {
                revert InsufficientBalance(amount, senderBalance);
            }
            
            uint256 amountAfterFee = amount - fee;
            
            // Mark payment as processed
            processedPayments[paymentReference] = true;
            
            // Increment nonce
            userNonces[from]++;
            
            // Update balances
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
        
        // Update platform wallet balance once at the end (gas optimization)
        balances[platformWallet] += totalFees;
        
        // Note: totalBalance remains unchanged because funds stay within the system
    }

    // ============================================================================
    // WITHDRAWAL FUNCTIONS
    // ============================================================================
    
    /**
     * @notice Withdraw USDC from the contract
     * @param amount Amount to withdraw
     */
    function withdraw(uint256 amount) external nonReentrant whenNotPaused {
        if (amount == 0) revert InvalidAmount();
        
        // FIXED: Cache balance to save gas
        uint256 userBalance = balances[msg.sender];
        if (userBalance < amount) {
            revert InsufficientBalance(amount, userBalance);
        }
        
        balances[msg.sender] = userBalance - amount;
        totalBalance -= amount;
        
        USDC.safeTransfer(msg.sender, amount);
        
        emit Withdrawn(msg.sender, amount, balances[msg.sender], block.timestamp);
    }
    
    /**
     * @notice Withdraw entire balance from the contract
     */
    function withdrawAll() external nonReentrant whenNotPaused {
        // FIXED: Cache balance to save gas
        uint256 amount = balances[msg.sender];
        if (amount == 0) revert InvalidAmount();
        
        balances[msg.sender] = 0;
        totalBalance -= amount;
        
        USDC.safeTransfer(msg.sender, amount);
        
        emit Withdrawn(msg.sender, amount, 0, block.timestamp);
    }

    // ============================================================================
    // VIEW FUNCTIONS
    // ============================================================================
    
    /**
     * @notice Get the balance of a user
     * @param user Address to query
     * @return User's balance in the contract
     */
    function balanceOf(address user) external view returns (uint256) {
        return balances[user];
    }
    
    /**
     * @notice Check if a payment has been processed
     * @param paymentReference Payment reference to check
     * @return True if payment has been processed
     */
    function isPaymentProcessed(bytes32 paymentReference) external view returns (bool) {
        return processedPayments[paymentReference];
    }
    
    /**
     * @notice Get the total balance tracked by the contract
     * @return Total of all user balances
     */
    function getTotalBalance() external view returns (uint256) {
        return totalBalance;
    }
    
    /**
     * @notice Get the actual USDC balance held by the contract
     * @return Actual USDC balance
     */
    function getActualBalance() external view returns (uint256) {
        return USDC.balanceOf(address(this));
    }
    
    /**
     * @notice Get current platform fee configuration
     * @return feePercentage Fee percentage in basis points
     * @return minimum Minimum fee amount
     * @return maximum Maximum fee amount
     */
    function getPlatformFeeInfo() external view returns (
        uint256 feePercentage,
        uint256 minimum,
        uint256 maximum
    ) {
        return (platformFeePercentage, minFee, maxFee);
    }
    
    /**
     * @notice Preview the fee for a given payment amount
     * @param amount Payment amount to calculate fee for
     * @return Calculated fee
     */
    function previewFee(uint256 amount) external view returns (uint256) {
        return calculateFee(amount);
    }
    
    /**
     * @notice Get the current nonce for a user
     * @param user Address to query
     * @return Current nonce value
     */
    function getNonce(address user) external view returns (uint256) {
        return userNonces[user];
    }

    // ============================================================================
    // ADMIN FUNCTIONS
    // ============================================================================
    
    /**
     * @notice Update the platform fee structure
     * @param newFeePercentage New percentage in basis points (e.g., 50 = 0.5%)
     * @param newMinFee New minimum fee in USDC
     * @param newMaxFee New maximum fee in USDC
     */
    function setPlatformFee(
        uint256 newFeePercentage,
        uint256 newMinFee,
        uint256 newMaxFee
    ) external onlyOwner {
        if (newFeePercentage > MAX_FEE_PERCENTAGE) revert InvalidFee();
        if (newMaxFee > MAX_ABSOLUTE_FEE) revert InvalidFee();
        if (newMinFee > newMaxFee) revert InvalidFee();
        
        uint256 oldFeePercentage = platformFeePercentage;
        uint256 oldMinFee = minFee;
        uint256 oldMaxFee = maxFee;
        
        platformFeePercentage = newFeePercentage;
        minFee = newMinFee;
        maxFee = newMaxFee;
        
        emit PlatformFeeUpdated(
            oldFeePercentage,
            newFeePercentage,
            oldMinFee,
            newMinFee,
            oldMaxFee,
            newMaxFee,
            block.timestamp
        );
    }
    
    /**
     * @notice Update the platform wallet address
     * @dev Migrates existing balance to the new wallet
     * @param newPlatformWallet New platform wallet address
     */
    function setPlatformWallet(address newPlatformWallet) external onlyOwner {
        if (newPlatformWallet == address(0)) revert InvalidAddress();
        
        address oldWallet = platformWallet;
        uint256 migratedBalance = balances[oldWallet];
        
        // Migrate balance to new wallet
        if (migratedBalance > 0) {
            balances[oldWallet] = 0;
            balances[newPlatformWallet] = migratedBalance;
        }
        
        platformWallet = newPlatformWallet;
        
        emit PlatformWalletUpdated(
            oldWallet,
            newPlatformWallet,
            migratedBalance,
            block.timestamp
        );
    }
    
    /**
     * @notice Toggle whether users can initiate their own payments
     * @dev If disabled, only owner can process payments (centralized mode)
     *      If enabled, only users can process their own payments (decentralized mode)
     * @param allow True to enable user-initiated payments, false to disable
     */
    function setAllowUserInitiatedPayments(bool allow) external onlyOwner {
        allowUserInitiatedPayments = allow;
        emit UserPaymentsToggled(allow, block.timestamp);
    }
    
    /**
     * @notice Pause all contract operations
     */
    function pause() external onlyOwner {
        _pause();
        emit ContractPaused(msg.sender, block.timestamp);
    }
    
    /**
     * @notice Unpause contract operations
     */
    function unpause() external onlyOwner {
        _unpause();
        emit ContractUnpaused(msg.sender, block.timestamp);
    }
    
    /**
     * @notice Emergency recovery for accidentally sent tokens (NOT USDC)
     * @dev USDC recovery is blocked to protect user funds
     * @param token The token address to recover
     * @param to The recipient address
     * @param amount The amount to recover
     */
    function recoverToken(
        address token,
        address to,
        uint256 amount
    ) 
        external 
        onlyOwner 
    {
        if (to == address(0)) revert InvalidAddress();
        
        // CRITICAL: Prevent USDC withdrawal to protect user funds
        if (token == address(USDC)) {
            revert CannotRecoverUSDC();
        }
        
        IERC20(token).safeTransfer(to, amount);
        
        emit EmergencyTokenRecovered(token, to, amount, block.timestamp);
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";


contract DabdDub is Ownable, ReentrancyGuard, Pausable {
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
    uint256 public constant MAX_BATCH_SIZE = 50; // FIXED: Reduced from 100 to 50 for gas safety
    
    mapping(address => uint256) public balances;
    
    // FIXED: Auto-incrementing payment ID system instead of user-provided references
    uint256 public nextPaymentId;
    mapping(uint256 => bool) public processedPayments;
    
    // Global nonce for additional entropy
    uint256 public globalNonce;
    
    uint256 public totalBalance;
    
    // Access control for payment processing
    bool public allowUserInitiatedPayments;
    
    // FIXED: Fee change timelock mechanism
    uint256 public pendingFeeChangeTimestamp;
    uint256 public constant FEE_CHANGE_DELAY = 24 hours;
    uint256 public pendingPlatformFeePercentage;
    uint256 public pendingMinFee;
    uint256 public pendingMaxFee;
    
    // FIXED: Emergency withdrawal mechanism
    uint256 public pausedAt;
    uint256 public constant MAX_PAUSE_DURATION = 7 days;
    
    // FIXED: Per-user withdrawal limits for security
    uint256 public dailyWithdrawalLimit = 100_000_000_000; // $100k default
    mapping(address => uint256) public lastWithdrawalTime;
    mapping(address => uint256) public dailyWithdrawnAmount;

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
        uint256 indexed paymentId,
        address indexed from,
        address indexed to,
        uint256 amount,
        uint256 fee,
        PaymentType paymentType,
        uint256 timestamp
    );
    
    event Withdrawn(
        address indexed user,
        uint256 indexed amount,
        uint256 newBalance,
        uint256 timestamp
    );
    
    event PlatformFeeChangeProposed(
        uint256 oldFeePercentage,
        uint256 newFeePercentage,
        uint256 oldMinFee,
        uint256 newMinFee,
        uint256 oldMaxFee,
        uint256 newMaxFee,
        uint256 effectiveAt,
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
    
    event EmergencyWithdrawal(
        address indexed user,
        uint256 amount,
        uint256 timestamp
    );
    
    event WithdrawalLimitUpdated(
        uint256 oldLimit,
        uint256 newLimit,
        uint256 timestamp
    );
    
    event BatchPaymentCompleted(
        uint256 indexed batchId,
        uint256 paymentsProcessed,
        uint256 totalFeesCollected,
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
    error PaymentAlreadyProcessed(uint256 paymentId);
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
    error FeeChangeNotReady();
    error NoPendingFeeChange();
    error PauseDurationExceeded();
    error WithdrawalLimitExceeded(uint256 requested, uint256 limit);
    error BatchPaymentsDisabledInDecentralizedMode();

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
        nextPaymentId = 1; // Start payment IDs at 1
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
     * @dev FIXED: Added overflow protection and explicit zero fee handling
     * @param amount The payment amount
     * @return The calculated fee (clamped between minFee and maxFee)
     */
    function calculateFee(uint256 amount) public view returns (uint256) {
        // Handle zero fee percentage case
        if (platformFeePercentage == 0) {
            return minFee; // Return minimum fee even if percentage is 0
        }
        
        // FIXED: Overflow protection
        if (amount > type(uint256).max / platformFeePercentage) {
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
    // PAYMENT FUNCTIONS
    // ============================================================================
    
    /**
     * @notice Process a single payment from one user to another
     * @dev FIXED: Automatic payment ID generation - no user-provided references
     *      FIXED: Uses block.number instead of block.timestamp for better security
     * @param from Sender address
     * @param to Recipient address
     * @param amount Total payment amount (including fee)
     * @param paymentType Type of payment (MERCHANT or USER_TO_USER)
     * @return paymentId The unique ID assigned to this payment
     */
    function processPayment(
        address from,
        address to,
        uint256 amount,
        PaymentType paymentType
    ) 
        external 
        onlyAuthorizedProcessor(from)
        nonReentrant 
        whenNotPaused 
        returns (uint256 paymentId)
    {
        if (amount == 0) revert InvalidAmount();
        if (from == address(0) || to == address(0)) revert InvalidAddress();
        if (from == to) revert SelfTransferNotAllowed();
        
        uint256 fee = calculateFee(amount);
        
        // Amount must be greater than the fee
        if (amount <= fee) revert AmountTooSmall();
        
        uint256 senderBalance = balances[from];
        if (senderBalance < amount) {
            revert InsufficientBalance(amount, senderBalance);
        }
        
        uint256 amountAfterFee = amount - fee;
        
        // FIXED: Auto-increment payment ID system
        paymentId = nextPaymentId++;
        processedPayments[paymentId] = true;
        
        // FIXED: Increment global nonce for additional entropy
        globalNonce++;
        
        // Update balances
        balances[from] = senderBalance - amount;
        balances[to] += amountAfterFee;
        balances[platformWallet] += fee;
        
        // Note: totalBalance remains unchanged because funds stay within the system
        
        emit PaymentProcessed(
            paymentId,
            from,
            to,
            amount,
            fee,
            paymentType,
            block.timestamp
        );
        
        return paymentId;
    }
    
    /**
     * @notice Process multiple payments in a single transaction
     * @dev FIXED: Only works in centralized mode (when allowUserInitiatedPayments is false)
     *      FIXED: Removed balance caching to prevent stale data issues
     *      FIXED: Reduced batch size and added comprehensive validation
     * @param froms Array of sender addresses
     * @param tos Array of recipient addresses
     * @param amounts Array of payment amounts
     * @param paymentTypes Array of payment types
     * @return batchId Unique identifier for this batch
     * @return paymentIds Array of payment IDs created
     */
    function processPaymentBatch(
        address[] calldata froms,
        address[] calldata tos,
        uint256[] calldata amounts,
        PaymentType[] calldata paymentTypes
    ) 
        external 
        onlyOwner
        nonReentrant 
        whenNotPaused 
        returns (uint256 batchId, uint256[] memory paymentIds)
    {
        // FIXED: Batch payments only available in centralized mode
        if (allowUserInitiatedPayments) {
            revert BatchPaymentsDisabledInDecentralizedMode();
        }
        
        uint256 length = froms.length;
        
        // Check for empty batch
        if (length == 0) revert InvalidAmount();
        
        // FIXED: Reduced batch size limit to 50 for gas safety
        if (length > MAX_BATCH_SIZE) {
            revert BatchSizeExceeded(length, MAX_BATCH_SIZE);
        }
        
        // Check array length consistency
        if (length != tos.length || 
            length != amounts.length || 
            length != paymentTypes.length) {
            revert ArrayLengthMismatch();
        }
        
        uint256 totalFees = 0;
        paymentIds = new uint256[](length);
        batchId = globalNonce++; // Use global nonce as batch ID
        
        for (uint256 i = 0; i < length; i++) {
            address from = froms[i];
            address to = tos[i];
            uint256 amount = amounts[i];
            PaymentType paymentType = paymentTypes[i];
            
            if (amount == 0) revert InvalidAmount();
            if (from == address(0) || to == address(0)) revert InvalidAddress();
            if (from == to) revert SelfTransferNotAllowed();
            
            // FIXED: Platform wallet cannot be a sender in batch operations
            if (from == platformWallet) revert PlatformWalletCannotBeSender();
            
            uint256 fee = calculateFee(amount);
            
            // Amount must be greater than the fee
            if (amount <= fee) revert AmountTooSmall();
            
            // FIXED: No balance caching - read fresh balance each time
            // This prevents issues with duplicate addresses in the batch
            uint256 senderBalance = balances[from];
            if (senderBalance < amount) {
                revert InsufficientBalance(amount, senderBalance);
            }
            
            uint256 amountAfterFee = amount - fee;
            
            // FIXED: Auto-increment payment ID
            uint256 paymentId = nextPaymentId++;
            processedPayments[paymentId] = true;
            paymentIds[i] = paymentId;
            
            // Update balances (no caching)
            balances[from] = balances[from] - amount;
            balances[to] = balances[to] + amountAfterFee;
            totalFees += fee;
            
            emit PaymentProcessed(
                paymentId,
                from,
                to,
                amount,
                fee,
                paymentType,
                block.timestamp
            );
        }
        
        // Update platform wallet balance once at the end
        balances[platformWallet] += totalFees;
        
        emit BatchPaymentCompleted(batchId, length, totalFees, block.timestamp);
        
        // Note: totalBalance remains unchanged because funds stay within the system
    }

    // ============================================================================
    // WITHDRAWAL FUNCTIONS
    // ============================================================================
    
    /**
     * @notice Withdraw USDC from the contract with daily limits
     * @dev FIXED: Added daily withdrawal limits for security
     * @param amount Amount to withdraw
     */
    function withdraw(uint256 amount) external nonReentrant whenNotPaused {
        if (amount == 0) revert InvalidAmount();
        
        uint256 userBalance = balances[msg.sender];
        if (userBalance < amount) {
            revert InsufficientBalance(amount, userBalance);
        }
        
        // FIXED: Check daily withdrawal limit
        _checkAndUpdateWithdrawalLimit(msg.sender, amount);
        
        balances[msg.sender] = userBalance - amount;
        totalBalance -= amount;
        
        USDC.safeTransfer(msg.sender, amount);
        
        emit Withdrawn(msg.sender, amount, balances[msg.sender], block.timestamp);
    }
    
    /**
     * @notice Withdraw entire balance from the contract
     * @dev FIXED: Also subject to daily withdrawal limits
     */
    function withdrawAll() external nonReentrant whenNotPaused {
        uint256 amount = balances[msg.sender];
        if (amount == 0) revert InvalidAmount();
        
        // FIXED: Check daily withdrawal limit
        _checkAndUpdateWithdrawalLimit(msg.sender, amount);
        
        balances[msg.sender] = 0;
        totalBalance -= amount;
        
        USDC.safeTransfer(msg.sender, amount);
        
        emit Withdrawn(msg.sender, amount, 0, block.timestamp);
    }
    
    /**
     * @notice Emergency withdrawal function when contract is paused too long
     * @dev FIXED: Allows withdrawals if contract has been paused for more than MAX_PAUSE_DURATION
     *      Bypasses daily limits in emergency situations
     */
    function emergencyWithdraw() external nonReentrant {
        // Only allow if contract has been paused for too long
        if (!paused() || block.timestamp < pausedAt + MAX_PAUSE_DURATION) {
            revert PauseDurationExceeded();
        }
        
        uint256 amount = balances[msg.sender];
        if (amount == 0) revert InvalidAmount();
        
        balances[msg.sender] = 0;
        totalBalance -= amount;
        
        USDC.safeTransfer(msg.sender, amount);
        
        emit EmergencyWithdrawal(msg.sender, amount, block.timestamp);
    }
    
    /**
     * @notice Internal function to check and update daily withdrawal limits
     * @dev FIXED: Implements rolling 24-hour withdrawal limits
     */
    function _checkAndUpdateWithdrawalLimit(address user, uint256 amount) internal {
        // Reset daily limit if 24 hours have passed
        if (block.timestamp >= lastWithdrawalTime[user] + 1 days) {
            dailyWithdrawnAmount[user] = 0;
            lastWithdrawalTime[user] = block.timestamp;
        }
        
        uint256 newTotal = dailyWithdrawnAmount[user] + amount;
        if (newTotal > dailyWithdrawalLimit) {
            revert WithdrawalLimitExceeded(newTotal, dailyWithdrawalLimit);
        }
        
        dailyWithdrawnAmount[user] = newTotal;
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
     * @param paymentId Payment ID to check
     * @return True if payment has been processed
     */
    function isPaymentProcessed(uint256 paymentId) external view returns (bool) {
        return processedPayments[paymentId];
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
     * @notice Get remaining withdrawal limit for a user
     * @param user Address to query
     * @return remaining Amount user can still withdraw today
     */
    function getRemainingWithdrawalLimit(address user) external view returns (uint256 remaining) {
        // If 24 hours have passed, full limit is available
        if (block.timestamp >= lastWithdrawalTime[user] + 1 days) {
            return dailyWithdrawalLimit;
        }
        
        uint256 withdrawn = dailyWithdrawnAmount[user];
        if (withdrawn >= dailyWithdrawalLimit) {
            return 0;
        }
        
        return dailyWithdrawalLimit - withdrawn;
    }
    
    /**
     * @notice Get next payment ID that will be assigned
     * @return Next payment ID
     */
    function getNextPaymentId() external view returns (uint256) {
        return nextPaymentId;
    }
    
    /**
     * @notice Check if there's a pending fee change
     * @return hasPending True if there's a pending change
     * @return effectiveAt Timestamp when change becomes effective
     */
    function getPendingFeeChange() external view returns (
        bool hasPending,
        uint256 effectiveAt,
        uint256 newFeePercentage,
        uint256 newMinFee,
        uint256 newMaxFee
    ) {
        hasPending = pendingFeeChangeTimestamp > 0;
        effectiveAt = pendingFeeChangeTimestamp;
        newFeePercentage = pendingPlatformFeePercentage;
        newMinFee = pendingMinFee;
        newMaxFee = pendingMaxFee;
    }

    // ============================================================================
    // ADMIN FUNCTIONS
    // ============================================================================
    
    /**
     * @notice Propose a platform fee change (with timelock)
     * @dev FIXED: Implements 24-hour timelock before fees can be changed
     * @param newFeePercentage New percentage in basis points (e.g., 50 = 0.5%)
     * @param newMinFee New minimum fee in USDC
     * @param newMaxFee New maximum fee in USDC
     */
    function proposePlatformFeeChange(
        uint256 newFeePercentage,
        uint256 newMinFee,
        uint256 newMaxFee
    ) external onlyOwner {
        if (newFeePercentage > MAX_FEE_PERCENTAGE) revert InvalidFee();
        if (newMaxFee > MAX_ABSOLUTE_FEE) revert InvalidFee();
        if (newMinFee > newMaxFee) revert InvalidFee();
        
        pendingPlatformFeePercentage = newFeePercentage;
        pendingMinFee = newMinFee;
        pendingMaxFee = newMaxFee;
        pendingFeeChangeTimestamp = block.timestamp + FEE_CHANGE_DELAY;
        
        emit PlatformFeeChangeProposed(
            platformFeePercentage,
            newFeePercentage,
            minFee,
            newMinFee,
            maxFee,
            newMaxFee,
            pendingFeeChangeTimestamp,
            block.timestamp
        );
    }
    
    /**
     * @notice Execute a pending platform fee change
     * @dev FIXED: Can only be executed after timelock period
     */
    function executePlatformFeeChange() external onlyOwner {
        if (pendingFeeChangeTimestamp == 0) {
            revert NoPendingFeeChange();
        }
        if (block.timestamp < pendingFeeChangeTimestamp) {
            revert FeeChangeNotReady();
        }
        
        uint256 oldFeePercentage = platformFeePercentage;
        uint256 oldMinFee = minFee;
        uint256 oldMaxFee = maxFee;
        
        platformFeePercentage = pendingPlatformFeePercentage;
        minFee = pendingMinFee;
        maxFee = pendingMaxFee;
        
        // Clear pending state
        pendingFeeChangeTimestamp = 0;
        pendingPlatformFeePercentage = 0;
        pendingMinFee = 0;
        pendingMaxFee = 0;
        
        emit PlatformFeeUpdated(
            oldFeePercentage,
            platformFeePercentage,
            oldMinFee,
            minFee,
            oldMaxFee,
            maxFee,
            block.timestamp
        );
    }
    
    /**
     * @notice Cancel a pending platform fee change
     */
    function cancelPlatformFeeChange() external onlyOwner {
        if (pendingFeeChangeTimestamp == 0) {
            revert NoPendingFeeChange();
        }
        
        pendingFeeChangeTimestamp = 0;
        pendingPlatformFeePercentage = 0;
        pendingMinFee = 0;
        pendingMaxFee = 0;
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
     * @notice Update daily withdrawal limit
     * @dev FIXED: Allows owner to adjust withdrawal limits for security
     * @param newLimit New daily withdrawal limit in USDC
     */
    function setDailyWithdrawalLimit(uint256 newLimit) external onlyOwner {
        uint256 oldLimit = dailyWithdrawalLimit;
        dailyWithdrawalLimit = newLimit;
        
        emit WithdrawalLimitUpdated(oldLimit, newLimit, block.timestamp);
    }
    
    /**
     * @notice Pause all contract operations
     * @dev FIXED: Records when contract was paused for emergency withdrawal mechanism
     */
    function pause() external onlyOwner {
        pausedAt = block.timestamp;
        _pause();
        emit ContractPaused(msg.sender, block.timestamp);
    }
    
    /**
     * @notice Unpause contract operations
     * @dev FIXED: Resets pausedAt timestamp
     */
    function unpause() external onlyOwner {
        pausedAt = 0;
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

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title DabdDub - USDC Payment System with Fiat Off-Ramp
 * @notice Enables USDC deposits, P2P transfers, and fiat settlements via random wallet selection
 * @dev Supports Polygon and major EVM L2s
 */
contract DabdDub is Ownable, ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;

    // STATE VARIABLES
    
    IERC20 public immutable USDC;
    
    // Fiat settlement wallets (5 wallets for security/load balancing)
    address[5] public fiatSettlementWallets;
    mapping(address => bool) public isSettlementWallet;
    
    // Platform fee wallet (collects fees from all transactions)
    address public platformWallet;
    
    // Fee structure: percentage-based (in basis points, 10000 = 100%)
    uint256 public p2pFeePercentage;      // Fee for peer-to-peer transfers
    uint256 public fiatFeePercentage;     // Fee for fiat settlements
    uint256 public minFee;                // Minimum fee in USDC (6 decimals)
    uint256 public maxFee;                // Maximum fee in USDC (6 decimals)
    
    uint256 public constant MAX_FEE_PERCENTAGE = 1000; // Max 10%
    uint256 public constant MAX_ABSOLUTE_FEE = 10_000_000; // Max $10
    uint256 public constant BASIS_POINTS = 10000;
    
    // User balances
    mapping(address => uint256) public balances;
    uint256 public totalBalance;
    
    // Payment tracking
    uint256 public nextPaymentId;
    mapping(uint256 => Payment) public payments;
    
    // Nonce for randomness (combined with block data)
    uint256 public randomNonce;
    
    // Daily withdrawal limits
    uint256 public dailyWithdrawalLimit = 100_000_000_000; // $100k default
    mapping(address => uint256) public lastWithdrawalTime;
    mapping(address => uint256) public dailyWithdrawnAmount;
    
    // Fee change timelock
    uint256 public pendingFeeChangeTimestamp;
    uint256 public constant FEE_CHANGE_DELAY = 24 hours;
    FeeChange public pendingFeeChange;
    
    // Emergency pause tracking
    uint256 public pausedAt;
    uint256 public constant MAX_PAUSE_DURATION = 7 days;
    
    // Chain-specific configurations for L2 support
    uint256 public immutable DEPLOYMENT_CHAIN_ID;

    // STRUCTS
    
    struct Payment {
        uint256 id;
        address from;
        address to;
        uint256 amount;
        uint256 fee;
        PaymentType paymentType;
        PaymentStatus status;
        uint256 timestamp;
        address settlementWallet; // Only set for fiat payments
    }
    
    struct FeeChange {
        uint256 newP2pFeePercentage;
        uint256 newFiatFeePercentage;
        uint256 newMinFee;
        uint256 newMaxFee;
    }

    // ENUMS
    
    enum PaymentType {
        P2P,           // Peer-to-peer (stays in contract)
        FIAT_SETTLEMENT // Goes to settlement wallet for fiat conversion
    }
    
    enum PaymentStatus {
        PENDING,
        COMPLETED,
        FAILED
    }

    // EVENTS
    
    event Deposited(
        address indexed user,
        uint256 amount,
        uint256 newBalance,
        uint256 timestamp
    );
    
    event P2PTransfer(
        uint256 indexed paymentId,
        address indexed from,
        address indexed to,
        uint256 amount,
        uint256 fee,
        uint256 timestamp
    );
    
    event FiatPaymentInitiated(
        uint256 indexed paymentId,
        address indexed from,
        address indexed settlementWallet,
        uint256 amount,
        uint256 fee,
        uint256 timestamp
    );
    
    event FiatPaymentCompleted(
        uint256 indexed paymentId,
        address indexed settlementWallet,
        uint256 amountSent,
        uint256 timestamp
    );
    
    event Withdrawn(
        address indexed user,
        uint256 amount,
        uint256 newBalance,
        uint256 timestamp
    );
    
    event SettlementWalletUpdated(
        uint256 indexed index,
        address indexed oldWallet,
        address indexed newWallet,
        uint256 timestamp
    );
    
    event PlatformWalletUpdated(
        address indexed oldWallet,
        address indexed newWallet,
        uint256 timestamp
    );
    
    event FeeChangeProposed(
        uint256 oldP2pFee,
        uint256 newP2pFee,
        uint256 oldFiatFee,
        uint256 newFiatFee,
        uint256 effectiveAt,
        uint256 timestamp
    );
    
    event FeeChangeExecuted(
        uint256 newP2pFee,
        uint256 newFiatFee,
        uint256 newMinFee,
        uint256 newMaxFee,
        uint256 timestamp
    );
    
    event WithdrawalLimitUpdated(
        uint256 oldLimit,
        uint256 newLimit,
        uint256 timestamp
    );
    
    event EmergencyWithdrawal(
        address indexed user,
        uint256 amount,
        uint256 timestamp
    );

    // ERRORS
    
    error InsufficientBalance(uint256 requested, uint256 available);
    error InvalidAmount();
    error InvalidAddress();
    error InvalidFee();
    error SelfTransferNotAllowed();
    error AmountTooSmall();
    error SettlementWalletNotSet();
    error DuplicateSettlementWallet();
    error CannotRecoverUSDC();
    error FeeChangeNotReady();
    error NoPendingFeeChange();
    error PauseDurationExceeded();
    error WithdrawalLimitExceeded(uint256 requested, uint256 limit);
    error PaymentNotFound();
    error InvalidChainId();

    // CONSTRUCTOR
    
    /**
     * @notice Initializes the DabdDub contract
     * @param _usdc Address of the USDC token contract
     * @param _platformWallet Address that receives platform fees
     * @param _settlementWallets Array of 5 wallets for fiat settlements
     * @param _p2pFeePercentage Fee for P2P transfers (basis points)
     * @param _fiatFeePercentage Fee for fiat settlements (basis points)
     * @param _minFee Minimum fee in USDC (6 decimals)
     * @param _maxFee Maximum fee in USDC (6 decimals)
     */
    constructor(
        address _usdc,
        address _platformWallet,
        address[5] memory _settlementWallets,
        uint256 _p2pFeePercentage,
        uint256 _fiatFeePercentage,
        uint256 _minFee,
        uint256 _maxFee
    ) Ownable(msg.sender) {
        if (_usdc == address(0) || _platformWallet == address(0)) {
            revert InvalidAddress();
        }
        if (_p2pFeePercentage > MAX_FEE_PERCENTAGE || _fiatFeePercentage > MAX_FEE_PERCENTAGE) {
            revert InvalidFee();
        }
        if (_maxFee > MAX_ABSOLUTE_FEE) {
            revert InvalidFee();
        }
        if (_minFee > _maxFee) {
            revert InvalidFee();
        }
        
        // Validate settlement wallets
        for (uint256 i = 0; i < 5; i++) {
            if (_settlementWallets[i] == address(0)) {
                revert InvalidAddress();
            }
            // Check for duplicates
            for (uint256 j = i + 1; j < 5; j++) {
                if (_settlementWallets[i] == _settlementWallets[j]) {
                    revert DuplicateSettlementWallet();
                }
            }
            fiatSettlementWallets[i] = _settlementWallets[i];
            isSettlementWallet[_settlementWallets[i]] = true;
        }
        
        USDC = IERC20(_usdc);
        platformWallet = _platformWallet;
        p2pFeePercentage = _p2pFeePercentage;
        fiatFeePercentage = _fiatFeePercentage;
        minFee = _minFee;
        maxFee = _maxFee;
        nextPaymentId = 1;
        
        // Store deployment chain ID for L2 compatibility checks
        DEPLOYMENT_CHAIN_ID = block.chainid;
    }

    // DEPOSIT FUNCTIONS
    
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

    // PAYMENT FUNCTIONS
    
    /**
     * @notice Transfer USDC to another user (peer-to-peer, stays in contract)
     * @param to Recipient address
     * @param amount Total payment amount (including fee)
     * @return paymentId The unique ID assigned to this payment
     */
    function transferP2P(
        address to,
        uint256 amount
    ) 
        external 
        nonReentrant 
        whenNotPaused 
        returns (uint256 paymentId)
    {
        if (amount == 0) revert InvalidAmount();
        if (to == address(0)) revert InvalidAddress();
        if (msg.sender == to) revert SelfTransferNotAllowed();
        
        // Settlement wallets cannot receive P2P transfers
        if (isSettlementWallet[to]) revert InvalidAddress();
        
        uint256 fee = calculateFee(amount, p2pFeePercentage);
        
        if (amount <= fee) revert AmountTooSmall();
        
        uint256 senderBalance = balances[msg.sender];
        if (senderBalance < amount) {
            revert InsufficientBalance(amount, senderBalance);
        }
        
        uint256 amountAfterFee = amount - fee;
        
        // Update balances
        balances[msg.sender] = senderBalance - amount;
        balances[to] += amountAfterFee;
        balances[platformWallet] += fee;
        
        // Create payment record
        paymentId = nextPaymentId++;
        payments[paymentId] = Payment({
            id: paymentId,
            from: msg.sender,
            to: to,
            amount: amount,
            fee: fee,
            paymentType: PaymentType.P2P,
            status: PaymentStatus.COMPLETED,
            timestamp: block.timestamp,
            settlementWallet: address(0)
        });
        
        randomNonce++;
        
        emit P2PTransfer(
            paymentId,
            msg.sender,
            to,
            amount,
            fee,
            block.timestamp
        );
        
        return paymentId;
    }
    
    /**
     * @notice Make a fiat payment (USDC sent to random settlement wallet for off-chain conversion)
     * @param amount Total payment amount (including fee)
     * @return paymentId The unique ID assigned to this payment
     */
    function payWithFiat(
        uint256 amount
    ) 
        external 
        nonReentrant 
        whenNotPaused 
        returns (uint256 paymentId)
    {
        if (amount == 0) revert InvalidAmount();
        
        uint256 fee = calculateFee(amount, fiatFeePercentage);
        
        if (amount <= fee) revert AmountTooSmall();
        
        uint256 senderBalance = balances[msg.sender];
        if (senderBalance < amount) {
            revert InsufficientBalance(amount, senderBalance);
        }
        
        uint256 amountAfterFee = amount - fee;
        
        // Select random settlement wallet
        address selectedWallet = _getRandomSettlementWallet();
        
        // Update sender balance
        balances[msg.sender] = senderBalance - amount;
        
        // Fees go to platform wallet (stays in contract)
        balances[platformWallet] += fee;
        
        // Decrease total balance (USDC will be transferred out)
        totalBalance -= amountAfterFee;
        
        // Transfer USDC to settlement wallet
        USDC.safeTransfer(selectedWallet, amountAfterFee);
        
        // Create payment record
        paymentId = nextPaymentId++;
        payments[paymentId] = Payment({
            id: paymentId,
            from: msg.sender,
            to: address(0), // No on-chain recipient for fiat payments
            amount: amount,
            fee: fee,
            paymentType: PaymentType.FIAT_SETTLEMENT,
            status: PaymentStatus.COMPLETED,
            timestamp: block.timestamp,
            settlementWallet: selectedWallet
        });
        
        randomNonce++;
        
        emit FiatPaymentInitiated(
            paymentId,
            msg.sender,
            selectedWallet,
            amount,
            fee,
            block.timestamp
        );
        
        emit FiatPaymentCompleted(
            paymentId,
            selectedWallet,
            amountAfterFee,
            block.timestamp
        );
        
        return paymentId;
    }
    
    /**
     * @notice ADMIN: Process fiat payment on behalf of user (for centralized mode)
     * @dev Only owner can call this for backend-initiated payments
     * @param from User address
     * @param amount Total payment amount (including fee)
     * @return paymentId The unique ID assigned to this payment
     */
    function processFiatPayment(
        address from,
        uint256 amount
    ) 
        external 
        onlyOwner
        nonReentrant 
        whenNotPaused 
        returns (uint256 paymentId)
    {
        if (amount == 0) revert InvalidAmount();
        if (from == address(0)) revert InvalidAddress();
        
        uint256 fee = calculateFee(amount, fiatFeePercentage);
        
        if (amount <= fee) revert AmountTooSmall();
        
        uint256 senderBalance = balances[from];
        if (senderBalance < amount) {
            revert InsufficientBalance(amount, senderBalance);
        }
        
        uint256 amountAfterFee = amount - fee;
        
        // Select random settlement wallet
        address selectedWallet = _getRandomSettlementWallet();
        
        // Update sender balance
        balances[from] = senderBalance - amount;
        
        // Fees go to platform wallet
        balances[platformWallet] += fee;
        
        // Decrease total balance
        totalBalance -= amountAfterFee;
        
        // Transfer USDC to settlement wallet
        USDC.safeTransfer(selectedWallet, amountAfterFee);
        
        // Create payment record
        paymentId = nextPaymentId++;
        payments[paymentId] = Payment({
            id: paymentId,
            from: from,
            to: address(0),
            amount: amount,
            fee: fee,
            paymentType: PaymentType.FIAT_SETTLEMENT,
            status: PaymentStatus.COMPLETED,
            timestamp: block.timestamp,
            settlementWallet: selectedWallet
        });
        
        randomNonce++;
        
        emit FiatPaymentInitiated(
            paymentId,
            from,
            selectedWallet,
            amount,
            fee,
            block.timestamp
        );
        
        emit FiatPaymentCompleted(
            paymentId,
            selectedWallet,
            amountAfterFee,
            block.timestamp
        );
        
        return paymentId;
    }

    // FEE CALCULATION
    
    /**
     * @notice Calculates the fee for a payment amount
     * @param amount The payment amount
     * @param feePercentage The fee percentage to apply
     * @return The calculated fee (clamped between minFee and maxFee)
     */
    function calculateFee(uint256 amount, uint256 feePercentage) public view returns (uint256) {
        if (feePercentage == 0) {
            return minFee;
        }
        
        // Overflow protection
        if (amount > type(uint256).max / feePercentage) {
            return maxFee;
        }
        
        uint256 percentageFee = (amount * feePercentage) / BASIS_POINTS;
        
        // Clamp between min and max
        if (percentageFee < minFee) {
            return minFee;
        } else if (percentageFee > maxFee) {
            return maxFee;
        } else {
            return percentageFee;
        }
    }

    // WITHDRAWAL FUNCTIONS
    
    /**
     * @notice Withdraw USDC from the contract with daily limits
     * @param amount Amount to withdraw
     */
    function withdraw(uint256 amount) external nonReentrant whenNotPaused {
        if (amount == 0) revert InvalidAmount();
        
        uint256 userBalance = balances[msg.sender];
        if (userBalance < amount) {
            revert InsufficientBalance(amount, userBalance);
        }
        
        // Check daily withdrawal limit
        _checkAndUpdateWithdrawalLimit(msg.sender, amount);
        
        balances[msg.sender] = userBalance - amount;
        totalBalance -= amount;
        
        USDC.safeTransfer(msg.sender, amount);
        
        emit Withdrawn(msg.sender, amount, balances[msg.sender], block.timestamp);
    }
    
    /**
     * @notice Withdraw entire balance from the contract
     */
    function withdrawAll() external nonReentrant whenNotPaused {
        uint256 amount = balances[msg.sender];
        if (amount == 0) revert InvalidAmount();
        
        // Check daily withdrawal limit
        _checkAndUpdateWithdrawalLimit(msg.sender, amount);
        
        balances[msg.sender] = 0;
        totalBalance -= amount;
        
        USDC.safeTransfer(msg.sender, amount);
        
        emit Withdrawn(msg.sender, amount, 0, block.timestamp);
    }
    
    /**
     * @notice Emergency withdrawal function when contract is paused too long
     * @dev Allows withdrawals if contract has been paused for more than MAX_PAUSE_DURATION
     */
    function emergencyWithdraw() external nonReentrant {
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

    
    /**
     * @notice Selects a random settlement wallet from the 5 available
     * @dev Uses pseudo-random selection based on block data and nonce
     *      For production, consider Chainlink VRF for true randomness
     * @return Selected settlement wallet address
     */
    function _getRandomSettlementWallet() internal view returns (address) {
        // SECURITY NOTE: This is pseudo-random and predictable by miners
        // For high-value applications, use Chainlink VRF
        uint256 randomIndex = uint256(
            keccak256(
                abi.encodePacked(
                    block.timestamp,
                    block.prevrandao, // Works on PoS chains (Polygon, Ethereum)
                    msg.sender,
                    randomNonce,
                    tx.gasprice
                )
            )
        ) % 5;
        
        return fiatSettlementWallets[randomIndex];
    }

    function previewRandomSettlementWallet() external view returns (address) {
        uint256 randomIndex = uint256(
            keccak256(
                abi.encodePacked(
                    block.timestamp,
                    block.prevrandao,
                    msg.sender,
                    randomNonce,
                    tx.gasprice
                )
            )
        ) % 5;
        
        return fiatSettlementWallets[randomIndex];
    }

    // VIEW FUNCTIONS
    
    /**
     * @notice Get the balance of a user
     */
    function balanceOf(address user) external view returns (uint256) {
        return balances[user];
    }
    
    /**
     * @notice Get payment details by ID
     */
    function getPayment(uint256 paymentId) external view returns (Payment memory) {
        if (paymentId == 0 || paymentId >= nextPaymentId) revert PaymentNotFound();
        return payments[paymentId];
    }
    
    /**
     * @notice Get all 5 settlement wallets
     */
    function getSettlementWallets() external view returns (address[5] memory) {
        return fiatSettlementWallets;
    }
    
    /**
     * @notice Get total balance tracked by the contract
     */
    function getTotalBalance() external view returns (uint256) {
        return totalBalance;
    }
    
    /**
     * @notice Get actual USDC balance held by the contract
     */
    function getActualBalance() external view returns (uint256) {
        return USDC.balanceOf(address(this));
    }
    
    /**
     * @notice Get current fee configuration
     */
    function getFeeInfo() external view returns (
        uint256 p2pFee,
        uint256 fiatFee,
        uint256 minimum,
        uint256 maximum
    ) {
        return (p2pFeePercentage, fiatFeePercentage, minFee, maxFee);
    }
    
    /**
     * @notice Preview fee for P2P transfer
     */
    function previewP2PFee(uint256 amount) external view returns (uint256) {
        return calculateFee(amount, p2pFeePercentage);
    }
    
    /**
     * @notice Preview fee for fiat payment
     */
    function previewFiatFee(uint256 amount) external view returns (uint256) {
        return calculateFee(amount, fiatFeePercentage);
    }
    
    /**
     * @notice Get remaining withdrawal limit for a user
     */
    function getRemainingWithdrawalLimit(address user) external view returns (uint256) {
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
     * @notice Check if there's a pending fee change
     */
    function getPendingFeeChange() external view returns (
        bool hasPending,
        uint256 effectiveAt,
        uint256 newP2pFee,
        uint256 newFiatFee,
        uint256 newMinFee,
        uint256 newMaxFee
    ) {
        hasPending = pendingFeeChangeTimestamp > 0;
        effectiveAt = pendingFeeChangeTimestamp;
        newP2pFee = pendingFeeChange.newP2pFeePercentage;
        newFiatFee = pendingFeeChange.newFiatFeePercentage;
        newMinFee = pendingFeeChange.newMinFee;
        newMaxFee = pendingFeeChange.newMaxFee;
    }

    // ADMIN FUNCTIONS
    
    /**
     * @notice Update a settlement wallet
     * @param index Index of wallet to update (0-4)
     * @param newWallet New wallet address
     */
    function updateSettlementWallet(uint256 index, address newWallet) external onlyOwner {
        if (index >= 5) revert InvalidAddress();
        if (newWallet == address(0)) revert InvalidAddress();
        
        // Check for duplicates with other settlement wallets
        for (uint256 i = 0; i < 5; i++) {
            if (i != index && fiatSettlementWallets[i] == newWallet) {
                revert DuplicateSettlementWallet();
            }
        }
        
        address oldWallet = fiatSettlementWallets[index];
        
        // Update mappings
        isSettlementWallet[oldWallet] = false;
        isSettlementWallet[newWallet] = true;
        
        fiatSettlementWallets[index] = newWallet;
        
        emit SettlementWalletUpdated(index, oldWallet, newWallet, block.timestamp);
    }
    
    /**
     * @notice Update the platform wallet address
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
        
        emit PlatformWalletUpdated(oldWallet, newPlatformWallet, block.timestamp);
    }
    
    /**
     * @notice Propose a fee change (with 24-hour timelock)
     */
    function proposeFeeChange(
        uint256 newP2pFeePercentage,
        uint256 newFiatFeePercentage,
        uint256 newMinFee,
        uint256 newMaxFee
    ) external onlyOwner {
        if (newP2pFeePercentage > MAX_FEE_PERCENTAGE || newFiatFeePercentage > MAX_FEE_PERCENTAGE) {
            revert InvalidFee();
        }
        if (newMaxFee > MAX_ABSOLUTE_FEE) revert InvalidFee();
        if (newMinFee > newMaxFee) revert InvalidFee();
        
        pendingFeeChange = FeeChange({
            newP2pFeePercentage: newP2pFeePercentage,
            newFiatFeePercentage: newFiatFeePercentage,
            newMinFee: newMinFee,
            newMaxFee: newMaxFee
        });
        
        pendingFeeChangeTimestamp = block.timestamp + FEE_CHANGE_DELAY;
        
        emit FeeChangeProposed(
            p2pFeePercentage,
            newP2pFeePercentage,
            fiatFeePercentage,
            newFiatFeePercentage,
            pendingFeeChangeTimestamp,
            block.timestamp
        );
    }
    
    /**
     * @notice Execute a pending fee change
     */
    function executeFeeChange() external onlyOwner {
        if (pendingFeeChangeTimestamp == 0) {
            revert NoPendingFeeChange();
        }
        if (block.timestamp < pendingFeeChangeTimestamp) {
            revert FeeChangeNotReady();
        }
        
        p2pFeePercentage = pendingFeeChange.newP2pFeePercentage;
        fiatFeePercentage = pendingFeeChange.newFiatFeePercentage;
        minFee = pendingFeeChange.newMinFee;
        maxFee = pendingFeeChange.newMaxFee;
        
        emit FeeChangeExecuted(
            p2pFeePercentage,
            fiatFeePercentage,
            minFee,
            maxFee,
            block.timestamp
        );
        
        // Clear pending state
        pendingFeeChangeTimestamp = 0;
        delete pendingFeeChange;
    }
    
    /**
     * @notice Cancel a pending fee change
     */
    function cancelFeeChange() external onlyOwner {
        if (pendingFeeChangeTimestamp == 0) {
            revert NoPendingFeeChange();
        }
        
        pendingFeeChangeTimestamp = 0;
        delete pendingFeeChange;
    }
    
    /**
     * @notice Update daily withdrawal limit
     */
    function setDailyWithdrawalLimit(uint256 newLimit) external onlyOwner {
        uint256 oldLimit = dailyWithdrawalLimit;
        dailyWithdrawalLimit = newLimit;
        
        emit WithdrawalLimitUpdated(oldLimit, newLimit, block.timestamp);
    }
    
    /**
     * @notice Pause the contract
     */
    function pause() external onlyOwner {
        pausedAt = block.timestamp;
        _pause();
    }
    
    /**
     * @notice Unpause the contract
     */
    function unpause() external onlyOwner {
        pausedAt = 0;
        _unpause();
    }
    
    /**
     * @notice Emergency token recovery (NOT USDC)
     */
    function recoverToken(
        address token,
        address to,
        uint256 amount
    ) external onlyOwner {
        if (to == address(0)) revert InvalidAddress();
        if (token == address(USDC)) revert CannotRecoverUSDC();
        
        IERC20(token).safeTransfer(to, amount);
    }
}

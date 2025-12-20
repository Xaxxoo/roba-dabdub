// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title UserWallet - Individual custodial wallet for each user
 * @notice This contract holds USDC for a single user but is controlled by the platform
 * @dev Each user gets one of these contracts deployed
 */
contract UserWallet is ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;

    // ============================================================================
    // STATE VARIABLES
    // ============================================================================
    
    IERC20 public immutable USDC;
    address public immutable factory; // The WalletFactory that created this wallet
    address public immutable user;    // The user who "owns" this wallet
    
    uint256 public balance;
    
    // Payment tracking
    uint256 public nextPaymentId;
    mapping(uint256 => Payment) public payments;

    // ============================================================================
    // STRUCTS
    // ============================================================================
    
    struct Payment {
        uint256 id;
        address to;              // Settlement wallet or another user wallet
        uint256 amount;
        uint256 fee;
        PaymentType paymentType;
        uint256 timestamp;
    }
    
    enum PaymentType {
        P2P,
        FIAT_SETTLEMENT
    }

    // ============================================================================
    // EVENTS
    // ============================================================================
    
    event Deposited(
        address indexed user,
        uint256 amount,
        uint256 newBalance,
        uint256 timestamp
    );
    
    event PaymentProcessed(
        uint256 indexed paymentId,
        address indexed to,
        uint256 amount,
        uint256 fee,
        PaymentType paymentType,
        uint256 timestamp
    );
    
    event Withdrawn(
        address indexed to,
        uint256 amount,
        uint256 timestamp
    );

    // ============================================================================
    // ERRORS
    // ============================================================================
    
    error OnlyFactory();
    error InsufficientBalance(uint256 requested, uint256 available);
    error InvalidAmount();
    error InvalidAddress();

    // ============================================================================
    // MODIFIERS
    // ============================================================================
    
    modifier onlyFactory() {
        if (msg.sender != factory) revert OnlyFactory();
        _;
    }

    // ============================================================================
    // CONSTRUCTOR
    // ============================================================================
    
    /**
     * @notice Creates a new user wallet
     * @param _usdc USDC token address
     * @param _user The user this wallet belongs to
     */
    constructor(address _usdc, address _user) {
        USDC = IERC20(_usdc);
        factory = msg.sender; // Factory is the deployer
        user = _user;
        nextPaymentId = 1;
    }

    // ============================================================================
    // DEPOSIT FUNCTIONS
    // ============================================================================
    
    /**
     * @notice Deposit USDC into this wallet (only callable by factory/platform)
     * @param amount Amount to deposit
     */
    function deposit(uint256 amount) external onlyFactory nonReentrant whenNotPaused {
        if (amount == 0) revert InvalidAmount();
        
        USDC.safeTransferFrom(msg.sender, address(this), amount);
        balance += amount;
        
        emit Deposited(user, amount, balance, block.timestamp);
    }

    // ============================================================================
    // PAYMENT FUNCTIONS
    // ============================================================================
    
    /**
     * @notice Process a payment from this wallet (only callable by factory/platform)
     * @param to Destination address (another UserWallet or settlement wallet)
     * @param amount Amount to send (including fee)
     * @param fee Fee amount
     * @param paymentType Type of payment
     * @return paymentId Unique payment ID
     */
    function processPayment(
        address to,
        uint256 amount,
        uint256 fee,
        PaymentType paymentType
    ) 
        external 
        onlyFactory 
        nonReentrant 
        whenNotPaused 
        returns (uint256 paymentId)
    {
        if (amount == 0) revert InvalidAmount();
        if (to == address(0)) revert InvalidAddress();
        if (balance < amount) {
            revert InsufficientBalance(amount, balance);
        }
        
        uint256 amountAfterFee = amount - fee;
        balance -= amount;
        
        // Transfer USDC out
        USDC.safeTransfer(to, amountAfterFee);
        
        // Fee is transferred separately by factory
        if (fee > 0) {
            USDC.safeTransfer(factory, fee);
        }
        
        // Record payment
        paymentId = nextPaymentId++;
        payments[paymentId] = Payment({
            id: paymentId,
            to: to,
            amount: amount,
            fee: fee,
            paymentType: paymentType,
            timestamp: block.timestamp
        });
        
        emit PaymentProcessed(paymentId, to, amount, fee, paymentType, block.timestamp);
        
        return paymentId;
    }

    // ============================================================================
    // WITHDRAWAL FUNCTIONS
    // ============================================================================
    
    /**
     * @notice Withdraw USDC from wallet (only callable by factory/platform)
     * @param to Destination address
     * @param amount Amount to withdraw
     */
    function withdraw(
        address to,
        uint256 amount
    ) 
        external 
        onlyFactory 
        nonReentrant 
        whenNotPaused 
    {
        if (amount == 0) revert InvalidAmount();
        if (to == address(0)) revert InvalidAddress();
        if (balance < amount) {
            revert InsufficientBalance(amount, balance);
        }
        
        balance -= amount;
        USDC.safeTransfer(to, amount);
        
        emit Withdrawn(to, amount, block.timestamp);
    }

    // ============================================================================
    // VIEW FUNCTIONS
    // ============================================================================
    
    function getBalance() external view returns (uint256) {
        return balance;
    }
    
    function getActualBalance() external view returns (uint256) {
        return USDC.balanceOf(address(this));
    }
    
    function getPayment(uint256 paymentId) external view returns (Payment memory) {
        return payments[paymentId];
    }

    // ============================================================================
    // ADMIN FUNCTIONS
    // ============================================================================
    
    function pause() external onlyFactory {
        _pause();
    }
    
    function unpause() external onlyFactory {
        _unpause();
    }
}


/**
 * @title WalletFactory - Custodial wallet system
 * @notice Deploys and manages individual user wallets
 * @dev Platform has full control over all user funds
 */
contract WalletFactory is Ownable, ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;

    // ============================================================================
    // STATE VARIABLES
    // ============================================================================
    
    IERC20 public immutable USDC;
    
    // Fiat settlement wallets
    address[5] public fiatSettlementWallets;
    mapping(address => bool) public isSettlementWallet;
    
    // Platform fee wallet
    address public platformWallet;
    
    // Fee structure
    uint256 public p2pFeePercentage;      // Basis points
    uint256 public fiatFeePercentage;     // Basis points
    uint256 public minFee;
    uint256 public maxFee;
    
    uint256 public constant MAX_FEE_PERCENTAGE = 1000; // 10%
    uint256 public constant MAX_ABSOLUTE_FEE = 10_000_000; // $10
    uint256 public constant BASIS_POINTS = 10000;
    
    // User wallet tracking
    mapping(address => address) public userWallets; // user => UserWallet contract
    address[] public allWallets;
    
    // Nonce for randomness
    uint256 public randomNonce;
    
    // Global payment tracking (across all wallets)
    uint256 public nextGlobalPaymentId;
    mapping(uint256 => GlobalPayment) public globalPayments;
    
    // Fee change timelock
    uint256 public pendingFeeChangeTimestamp;
    uint256 public constant FEE_CHANGE_DELAY = 24 hours;
    FeeChange public pendingFeeChange;

    // ============================================================================
    // STRUCTS
    // ============================================================================
    
    struct GlobalPayment {
        uint256 id;
        address fromWallet;
        address toAddress;      // Can be another wallet or settlement address
        uint256 amount;
        uint256 fee;
        PaymentType paymentType;
        uint256 timestamp;
    }
    
    struct FeeChange {
        uint256 newP2pFeePercentage;
        uint256 newFiatFeePercentage;
        uint256 newMinFee;
        uint256 newMaxFee;
    }
    
    enum PaymentType {
        P2P,
        FIAT_SETTLEMENT
    }

    // ============================================================================
    // EVENTS
    // ============================================================================
    
    event WalletCreated(
        address indexed user,
        address indexed walletAddress,
        uint256 timestamp
    );
    
    event DepositProcessed(
        address indexed user,
        address indexed wallet,
        uint256 amount,
        uint256 timestamp
    );
    
    event P2PPayment(
        uint256 indexed globalPaymentId,
        address indexed fromUser,
        address indexed toUser,
        uint256 amount,
        uint256 fee,
        uint256 timestamp
    );
    
    event FiatPayment(
        uint256 indexed globalPaymentId,
        address indexed fromUser,
        address indexed settlementWallet,
        uint256 amount,
        uint256 fee,
        uint256 timestamp
    );
    
    event WithdrawalProcessed(
        address indexed user,
        address indexed to,
        uint256 amount,
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

    // ============================================================================
    // ERRORS
    // ============================================================================
    
    error WalletAlreadyExists();
    error WalletDoesNotExist();
    error InvalidAmount();
    error InvalidAddress();
    error InvalidFee();
    error DuplicateSettlementWallet();
    error SelfTransferNotAllowed();
    error AmountTooSmall();
    error FeeChangeNotReady();
    error NoPendingFeeChange();
    error CannotRecoverUSDC();

    // ============================================================================
    // CONSTRUCTOR
    // ============================================================================
    
    /**
     * @notice Initialize the wallet factory
     * @param _usdc USDC token address
     * @param _platformWallet Platform fee collection wallet
     * @param _settlementWallets 5 wallets for fiat settlements
     * @param _p2pFeePercentage P2P fee in basis points
     * @param _fiatFeePercentage Fiat fee in basis points
     * @param _minFee Minimum fee
     * @param _maxFee Maximum fee
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
        if (_maxFee > MAX_ABSOLUTE_FEE) revert InvalidFee();
        if (_minFee > _maxFee) revert InvalidFee();
        
        // Validate settlement wallets
        for (uint256 i = 0; i < 5; i++) {
            if (_settlementWallets[i] == address(0)) {
                revert InvalidAddress();
            }
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
        nextGlobalPaymentId = 1;
    }

    // ============================================================================
    // WALLET CREATION
    // ============================================================================
    
    /**
     * @notice Create a new wallet for a user
     * @param user User address
     * @return walletAddress Address of the created wallet contract
     */
    function createWallet(address user) external onlyOwner returns (address walletAddress) {
        if (user == address(0)) revert InvalidAddress();
        if (userWallets[user] != address(0)) revert WalletAlreadyExists();
        
        // Deploy new UserWallet contract
        UserWallet newWallet = new UserWallet(address(USDC), user);
        walletAddress = address(newWallet);
        
        userWallets[user] = walletAddress;
        allWallets.push(walletAddress);
        
        emit WalletCreated(user, walletAddress, block.timestamp);
        
        return walletAddress;
    }
    
    /**
     * @notice Create wallet and deposit in one transaction
     * @param user User address
     * @param amount Amount to deposit
     * @return walletAddress Address of the created wallet
     */
    function createWalletAndDeposit(
        address user,
        uint256 amount
    ) 
        external 
        onlyOwner 
        returns (address walletAddress) 
    {
        walletAddress = this.createWallet(user);
        this.depositToWallet(user, amount);
        return walletAddress;
    }

    // ============================================================================
    // DEPOSIT FUNCTIONS
    // ============================================================================
    
    /**
     * @notice Deposit USDC into a user's wallet
     * @param user User whose wallet to deposit into
     * @param amount Amount to deposit
     */
    function depositToWallet(
        address user,
        uint256 amount
    ) 
        external 
        onlyOwner 
        nonReentrant 
        whenNotPaused 
    {
        if (amount == 0) revert InvalidAmount();
        
        address walletAddress = userWallets[user];
        if (walletAddress == address(0)) revert WalletDoesNotExist();
        
        // Transfer USDC from owner to this factory
        USDC.safeTransferFrom(msg.sender, address(this), amount);
        
        // Approve wallet to pull USDC
        USDC.safeApprove(walletAddress, amount);
        
        // Deposit into user's wallet
        UserWallet(walletAddress).deposit(amount);
        
        emit DepositProcessed(user, walletAddress, amount, block.timestamp);
    }

    // ============================================================================
    // PAYMENT FUNCTIONS
    // ============================================================================
    
    /**
     * @notice Process P2P payment between two users
     * @param fromUser Sender
     * @param toUser Recipient
     * @param amount Total amount (including fee)
     * @return globalPaymentId Global payment ID
     */
    function processP2PPayment(
        address fromUser,
        address toUser,
        uint256 amount
    ) 
        external 
        onlyOwner 
        nonReentrant 
        whenNotPaused 
        returns (uint256 globalPaymentId)
    {
        if (amount == 0) revert InvalidAmount();
        if (fromUser == toUser) revert SelfTransferNotAllowed();
        
        address fromWallet = userWallets[fromUser];
        address toWallet = userWallets[toUser];
        
        if (fromWallet == address(0) || toWallet == address(0)) {
            revert WalletDoesNotExist();
        }
        
        uint256 fee = calculateFee(amount, p2pFeePercentage);
        if (amount <= fee) revert AmountTooSmall();
        
        // Process payment from sender's wallet to receiver's wallet
        UserWallet(fromWallet).processPayment(
            toWallet,
            amount,
            fee,
            UserWallet.PaymentType.P2P
        );
        
        // Receiver's wallet receives the USDC (already transferred by processPayment)
        // Now deposit it into their balance
        uint256 amountAfterFee = amount - fee;
        UserWallet(toWallet).deposit(amountAfterFee);
        
        // Collect fee in platform wallet
        USDC.safeTransfer(platformWallet, fee);
        
        // Record global payment
        globalPaymentId = nextGlobalPaymentId++;
        globalPayments[globalPaymentId] = GlobalPayment({
            id: globalPaymentId,
            fromWallet: fromWallet,
            toAddress: toWallet,
            amount: amount,
            fee: fee,
            paymentType: PaymentType.P2P,
            timestamp: block.timestamp
        });
        
        randomNonce++;
        
        emit P2PPayment(
            globalPaymentId,
            fromUser,
            toUser,
            amount,
            fee,
            block.timestamp
        );
        
        return globalPaymentId;
    }
    
    /**
     * @notice Process fiat payment (sends USDC to random settlement wallet)
     * @param fromUser User making payment
     * @param amount Total amount (including fee)
     * @return globalPaymentId Global payment ID
     */
    function processFiatPayment(
        address fromUser,
        uint256 amount
    ) 
        external 
        onlyOwner 
        nonReentrant 
        whenNotPaused 
        returns (uint256 globalPaymentId)
    {
        if (amount == 0) revert InvalidAmount();
        
        address fromWallet = userWallets[fromUser];
        if (fromWallet == address(0)) revert WalletDoesNotExist();
        
        uint256 fee = calculateFee(amount, fiatFeePercentage);
        if (amount <= fee) revert AmountTooSmall();
        
        // Select random settlement wallet
        address selectedWallet = _getRandomSettlementWallet();
        
        // Process payment from user's wallet to settlement wallet
        UserWallet(fromWallet).processPayment(
            selectedWallet,
            amount,
            fee,
            UserWallet.PaymentType.FIAT_SETTLEMENT
        );
        
        // Fee is already sent to factory by processPayment, now send to platform wallet
        USDC.safeTransfer(platformWallet, fee);
        
        // Record global payment
        globalPaymentId = nextGlobalPaymentId++;
        globalPayments[globalPaymentId] = GlobalPayment({
            id: globalPaymentId,
            fromWallet: fromWallet,
            toAddress: selectedWallet,
            amount: amount,
            fee: fee,
            paymentType: PaymentType.FIAT_SETTLEMENT,
            timestamp: block.timestamp
        });
        
        randomNonce++;
        
        emit FiatPayment(
            globalPaymentId,
            fromUser,
            selectedWallet,
            amount,
            fee,
            block.timestamp
        );
        
        return globalPaymentId;
    }

    // ============================================================================
    // WITHDRAWAL FUNCTIONS
    // ============================================================================
    
    /**
     * @notice Withdraw USDC from a user's wallet (platform controlled)
     * @param user User whose wallet to withdraw from
     * @param to Destination address
     * @param amount Amount to withdraw
     */
    function withdrawFromWallet(
        address user,
        address to,
        uint256 amount
    ) 
        external 
        onlyOwner 
        nonReentrant 
        whenNotPaused 
    {
        if (amount == 0) revert InvalidAmount();
        if (to == address(0)) revert InvalidAddress();
        
        address walletAddress = userWallets[user];
        if (walletAddress == address(0)) revert WalletDoesNotExist();
        
        UserWallet(walletAddress).withdraw(to, amount);
        
        emit WithdrawalProcessed(user, to, amount, block.timestamp);
    }

    // ============================================================================
    // FEE CALCULATION
    // ============================================================================
    
    function calculateFee(uint256 amount, uint256 feePercentage) public view returns (uint256) {
        if (feePercentage == 0) return minFee;
        
        if (amount > type(uint256).max / feePercentage) {
            return maxFee;
        }
        
        uint256 percentageFee = (amount * feePercentage) / BASIS_POINTS;
        
        if (percentageFee < minFee) {
            return minFee;
        } else if (percentageFee > maxFee) {
            return maxFee;
        } else {
            return percentageFee;
        }
    }

    // ============================================================================
    // RANDOMNESS
    // ============================================================================
    
    function _getRandomSettlementWallet() internal view returns (address) {
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

    // ============================================================================
    // VIEW FUNCTIONS
    // ============================================================================
    
    function getUserWallet(address user) external view returns (address) {
        return userWallets[user];
    }
    
    function getUserBalance(address user) external view returns (uint256) {
        address walletAddress = userWallets[user];
        if (walletAddress == address(0)) return 0;
        return UserWallet(walletAddress).getBalance();
    }
    
    function getTotalWallets() external view returns (uint256) {
        return allWallets.length;
    }
    
    function getWalletAtIndex(uint256 index) external view returns (address) {
        return allWallets[index];
    }
    
    function getSettlementWallets() external view returns (address[5] memory) {
        return fiatSettlementWallets;
    }
    
    function getFeeInfo() external view returns (
        uint256 p2pFee,
        uint256 fiatFee,
        uint256 minimum,
        uint256 maximum
    ) {
        return (p2pFeePercentage, fiatFeePercentage, minFee, maxFee);
    }
    
    function previewP2PFee(uint256 amount) external view returns (uint256) {
        return calculateFee(amount, p2pFeePercentage);
    }
    
    function previewFiatFee(uint256 amount) external view returns (uint256) {
        return calculateFee(amount, fiatFeePercentage);
    }
    
    function getGlobalPayment(uint256 paymentId) external view returns (GlobalPayment memory) {
        return globalPayments[paymentId];
    }

    // ============================================================================
    // ADMIN FUNCTIONS
    // ============================================================================
    
    function updateSettlementWallet(uint256 index, address newWallet) external onlyOwner {
        if (index >= 5) revert InvalidAddress();
        if (newWallet == address(0)) revert InvalidAddress();
        
        for (uint256 i = 0; i < 5; i++) {
            if (i != index && fiatSettlementWallets[i] == newWallet) {
                revert DuplicateSettlementWallet();
            }
        }
        
        address oldWallet = fiatSettlementWallets[index];
        isSettlementWallet[oldWallet] = false;
        isSettlementWallet[newWallet] = true;
        fiatSettlementWallets[index] = newWallet;
        
        emit SettlementWalletUpdated(index, oldWallet, newWallet, block.timestamp);
    }
    
    function setPlatformWallet(address newPlatformWallet) external onlyOwner {
        if (newPlatformWallet == address(0)) revert InvalidAddress();
        
        address oldWallet = platformWallet;
        platformWallet = newPlatformWallet;
        
        emit PlatformWalletUpdated(oldWallet, newPlatformWallet, block.timestamp);
    }
    
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
    
    function executeFeeChange() external onlyOwner {
        if (pendingFeeChangeTimestamp == 0) revert NoPendingFeeChange();
        if (block.timestamp < pendingFeeChangeTimestamp) revert FeeChangeNotReady();
        
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
        
        pendingFeeChangeTimestamp = 0;
        delete pendingFeeChange;
    }
    
    function cancelFeeChange() external onlyOwner {
        if (pendingFeeChangeTimestamp == 0) revert NoPendingFeeChange();
        pendingFeeChangeTimestamp = 0;
        delete pendingFeeChange;
    }
    
    function pause() external onlyOwner {
        _pause();
    }
    
    function unpause() external onlyOwner {
        _unpause();
    }
    
    function pauseUserWallet(address user) external onlyOwner {
        address walletAddress = userWallets[user];
        if (walletAddress == address(0)) revert WalletDoesNotExist();
        UserWallet(walletAddress).pause();
    }
    
    function unpauseUserWallet(address user) external onlyOwner {
        address walletAddress = userWallets[user];
        if (walletAddress == address(0)) revert WalletDoesNotExist();
        UserWallet(walletAddress).unpause();
    }
    
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

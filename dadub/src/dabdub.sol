// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

contract PaymentWallet is Ownable, ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;

    // ============================================================================
    // STATE VARIABLES
    // ============================================================================
    
    IERC20 public immutable USDC;
    address public platformWallet;
    uint256 public platformFeeBps;
    uint256 public constant MAX_FEE_BPS = 1000;
    uint256 private constant BPS_DIVISOR = 10000;
    
    mapping(address => uint256) public balances;
    mapping(bytes32 => bool) public processedPayments;
    mapping(address => uint256) public nonces;
    
    uint256 public totalBalance;

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
        address indexed from,
        address indexed to,
        uint256 amount,
        uint256 fee,
        bytes32 indexed paymentReference,
        PaymentType paymentType,
        uint256 timestamp
    );
    
    event Withdrawn(
        address indexed user,
        uint256 amount,
        uint256 newBalance,
        uint256 timestamp
    );
    
    event PlatformFeeUpdated(
        uint256 oldFeeBps,
        uint256 newFeeBps,
        uint256 timestamp
    );
    
    event PlatformWalletUpdated(
        address indexed oldWallet,
        address indexed newWallet,
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

    // ============================================================================
    // CONSTRUCTOR
    // ============================================================================
    
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
        
        USDC = IERC20(_usdc);
        platformWallet = _platformWallet;
        platformFeeBps = _platformFeeBps;
    }

    // ============================================================================
    // DEPOSIT FUNCTIONS
    // ============================================================================
    
    function deposit(uint256 amount) external nonReentrant whenNotPaused {
        if (amount == 0) revert InvalidAmount();
        
        USDC.safeTransferFrom(msg.sender, address(this), amount);
        
        balances[msg.sender] += amount;
        totalBalance += amount;
        
        emit Deposited(msg.sender, amount, balances[msg.sender], block.timestamp);
    }
    
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
    // PAYMENT FUNCTIONS
    // ============================================================================
    
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
        
        uint256 fee = (amount * platformFeeBps) / BPS_DIVISOR;
        uint256 amountAfterFee = amount - fee;
        
        processedPayments[paymentReference] = true;
        
        balances[from] -= amount;
        balances[to] += amountAfterFee;
        
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
        
        if (totalFees > 0) {
            balances[platformWallet] += totalFees;
        }
    }

    // ============================================================================
    // WITHDRAWAL FUNCTIONS
    // ============================================================================
    
    function withdraw(uint256 amount) external nonReentrant whenNotPaused {
        if (amount == 0) revert InvalidAmount();
        
        uint256 userBalance = balances[msg.sender];
        if (userBalance < amount) {
            revert InsufficientBalance(amount, userBalance);
        }
        
        balances[msg.sender] = userBalance - amount;
        totalBalance -= amount;
        
        USDC.safeTransfer(msg.sender, amount);
        
        emit Withdrawn(msg.sender, amount, balances[msg.sender], block.timestamp);
    }
    
    function withdrawAll() external nonReentrant whenNotPaused {
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
    
    function balanceOf(address user) external view returns (uint256) {
        return balances[user];
    }
    
    function isPaymentProcessed(bytes32 paymentReference) external view returns (bool) {
        return processedPayments[paymentReference];
    }
    
    function getTotalBalance() external view returns (uint256) {
        return totalBalance;
    }
    
    function getActualBalance() external view returns (uint256) {
        return USDC.balanceOf(address(this));
    }
    
    function getNonce(address user) external view returns (uint256) {
        return nonces[user];
    }

    // ============================================================================
    // ADMIN FUNCTIONS
    // ============================================================================
    
    function setPlatformFee(uint256 newFeeBps) external onlyOwner {
        if (newFeeBps > MAX_FEE_BPS) revert InvalidFee();
        
        uint256 oldFeeBps = platformFeeBps;
        platformFeeBps = newFeeBps;
        
        emit PlatformFeeUpdated(oldFeeBps, newFeeBps, block.timestamp);
    }
    
    function setPlatformWallet(address newPlatformWallet) external onlyOwner {
        if (newPlatformWallet == address(0)) revert InvalidAddress();
        
        address oldWallet = platformWallet;
        platformWallet = newPlatformWallet;
        
        emit PlatformWalletUpdated(oldWallet, newPlatformWallet, block.timestamp);
    }
    
    function pause() external onlyOwner {
        _pause();
    }
    
    function unpause() external onlyOwner {
        _unpause();
    }
    
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
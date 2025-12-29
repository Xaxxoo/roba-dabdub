// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IUserWallet {
    function transferToVault(uint256 paymentAmount) external returns (uint256 totalAmount);
}

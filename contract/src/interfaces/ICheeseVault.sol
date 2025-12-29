// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface ICheeseVault {
    function feeAmount() external view returns (uint256);
    function processPayment(address userWallet, uint256 paymentAmount, bytes32 paymentId) external;
}

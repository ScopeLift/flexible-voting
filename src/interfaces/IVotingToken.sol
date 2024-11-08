// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @dev The interface that flexible voting-compatible voting tokens are expected to support.
interface IVotingToken {
  function transfer(address to, uint256 amount) external returns (bool);
  function transferFrom(address from, address to, uint256 amount) external returns (bool);
  function delegate(address delegatee) external;
  function getPastVotes(address account, uint256 blockNumber) external view returns (uint256);
}

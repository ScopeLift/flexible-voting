// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @dev The interface that flexible voting-compatible governors are expected to support.
interface IFractionalGovernor {
  function token() external view returns (address);
  function proposalSnapshot(uint256 proposalId) external view returns (uint256);
  function proposalDeadline(uint256 proposalId) external view returns (uint256);
  function castVoteWithReasonAndParams(
    uint256 proposalId,
    uint8 support,
    string calldata reason,
    bytes memory params
  ) external returns (uint256);
}

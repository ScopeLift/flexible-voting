// SPDX-License-Identifier: MIT
pragma solidity >=0.8.10;

import {Checkpoints} from "@openzeppelin/contracts/utils/structs/Checkpoints.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20Votes} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Votes.sol";
import {FlexVotingClient} from "src/FlexVotingClient.sol";

contract MockFlexVotingClient is FlexVotingClient {
  using Checkpoints for Checkpoints.Trace208;

  /// @notice The governance token held and lent by this pool.
  ERC20Votes public immutable TOKEN;

  /// @notice Map depositor to deposit amount.
  mapping(address => uint208) public deposits;

  constructor(address _governor) FlexVotingClient(_governor) {
    TOKEN = ERC20Votes(GOVERNOR.token());
    _selfDelegate();
  }

  function _rawBalanceOf(address _user) internal view override returns (uint208) {
    return deposits[_user];
  }

  function deposit(uint208 _amount) public {
    deposits[msg.sender] += _amount;

    FlexVotingClient._checkpointRawBalanceOf(msg.sender);

    FlexVotingClient.totalBalanceCheckpoints.push(
      SafeCast.toUint48(block.number),
      FlexVotingClient.totalBalanceCheckpoints.latest() + _amount
    );

    // Assumes revert on failure.
    TOKEN.transferFrom(msg.sender, address(this), _amount);
  }

  function withdraw(uint208 _amount) public {
    // Overflows & reverts if user does not have sufficient deposits.
    deposits[msg.sender] -= _amount;

    FlexVotingClient._checkpointRawBalanceOf(msg.sender);

    FlexVotingClient.totalBalanceCheckpoints.push(
      SafeCast.toUint48(block.number),
      FlexVotingClient.totalBalanceCheckpoints.latest() - _amount
    );

    TOKEN.transfer(msg.sender, _amount); // Assumes revert on failure.
  }
}

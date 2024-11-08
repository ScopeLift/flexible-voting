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
  mapping(address => uint256) public deposits;

  constructor(address _governor) FlexVotingClient(_governor) {
    TOKEN = ERC20Votes(GOVERNOR.token());
    _selfDelegate();
  }

  function _rawBalanceOf(address _user) internal view override returns (uint208) {
    return SafeCast.toUint208(TOKEN.balanceOf(_user));
  }

  function deposit(uint256 _amount) public {
    deposits[msg.sender] += _amount;

    FlexVotingClient._checkpointRawBalanceOf(msg.sender);

    FlexVotingClient.totalBalanceCheckpoints.push(
      SafeCast.toUint48(block.number),
      SafeCast.toUint208(TOKEN.balanceOf(address(this)))
    );

    // Assumes revert on failure.
    TOKEN.transferFrom(msg.sender, address(this), _amount);
  }

  function withdraw(uint256 _amount) public {
    // Overflows & reverts if user does not have sufficient deposits.
    deposits[msg.sender] -= _amount;

    FlexVotingClient._checkpointRawBalanceOf(msg.sender);

    FlexVotingClient.totalBalanceCheckpoints.push(
      SafeCast.toUint48(block.number),
      SafeCast.toUint208(TOKEN.balanceOf(address(this)))
    );

    TOKEN.transfer(msg.sender, _amount); // Assumes revert on failure.
  }
}

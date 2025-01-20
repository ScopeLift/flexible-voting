// SPDX-License-Identifier: MIT
pragma solidity >=0.8.10;

import {Checkpoints} from "@openzeppelin/contracts/utils/structs/Checkpoints.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20Votes} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Votes.sol";
import {IVotingToken} from "src/interfaces/IVotingToken.sol";
import {FlexVotingClient} from "src/FlexVotingClient.sol";
import {FlexVotingDelegatable} from "src/FlexVotingDelegatable.sol";

import {MockFlexVotingClient} from "test/MockFlexVotingClient.sol";

contract MockFlexVotingDelegatableClient is MockFlexVotingClient, FlexVotingDelegatable {
  constructor(address _governor) MockFlexVotingClient(_governor) {}

  function _checkpointRawBalanceOf(
    address _user,
    int256 _delta
  ) internal override(FlexVotingClient, FlexVotingDelegatable) {
    return FlexVotingDelegatable._checkpointRawBalanceOf(_user, _delta);
  }
}

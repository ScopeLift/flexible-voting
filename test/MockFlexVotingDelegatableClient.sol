// SPDX-License-Identifier: MIT
pragma solidity >=0.8.10;

import {FlexVotingClient} from "src/FlexVotingClient.sol";
import {FlexVotingDelegatable} from "src/FlexVotingDelegatable.sol";
import {MockFlexVotingClient} from "test/MockFlexVotingClient.sol";
import {FlexVotingBase} from "src/FlexVotingBase.sol";

contract MockFlexVotingDelegatableClient is MockFlexVotingClient, FlexVotingDelegatable {
  constructor(address _governor) MockFlexVotingClient(_governor) {}

  function _checkpointVoteWeightOf(address _user, int256 _delta)
    internal
    override(FlexVotingBase, FlexVotingDelegatable)
  {
    return FlexVotingDelegatable._checkpointVoteWeightOf(_user, _delta);
  }
}

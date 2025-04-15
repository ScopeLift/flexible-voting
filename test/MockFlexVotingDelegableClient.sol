// SPDX-License-Identifier: MIT
pragma solidity >=0.8.10;

import {FlexVotingClient} from "src/FlexVotingClient.sol";
import {FlexVotingDelegable} from "src/FlexVotingDelegable.sol";
import {MockFlexVotingClient} from "test/MockFlexVotingClient.sol";
import {FlexVotingBase} from "src/FlexVotingBase.sol";

contract MockFlexVotingDelegableClient is MockFlexVotingClient, FlexVotingDelegable {
  constructor(address _governor) MockFlexVotingClient(_governor) {}

  function _checkpointVoteWeightOf(address _user, int256 _delta)
    internal
    override(FlexVotingBase, FlexVotingDelegable)
  {
    return FlexVotingDelegable._checkpointVoteWeightOf(_user, _delta);
  }
}

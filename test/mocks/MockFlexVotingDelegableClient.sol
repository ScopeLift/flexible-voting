// SPDX-License-Identifier: MIT
pragma solidity >=0.8.10;

import {FlexVotingClient} from "src/FlexVotingClient.sol";
import {FlexVotingDelegable} from "src/FlexVotingDelegable.sol";
import {MockFlexVotingClient} from "test/mocks/MockFlexVotingClient.sol";
import {FlexVotingBase} from "src/FlexVotingBase.sol";
import {IFractionalGovernor} from "src/interfaces/IFractionalGovernor.sol";
import {IVotingToken} from "src/interfaces/IVotingToken.sol";

contract MockFlexVotingDelegableClient is MockFlexVotingClient, FlexVotingDelegable {
  constructor(address _governor) MockFlexVotingClient(_governor) {}

  function _checkpointVoteWeightOf(IVotingToken _token, address _user, int256 _delta)
    internal
    override(FlexVotingBase, FlexVotingDelegable)
  {
    return FlexVotingDelegable._checkpointVoteWeightOf(_token, _user, _delta);
  }

  // Test hooks
  // ---------------------------------------------------------------------------
  function delegate(address _proxy) public {
    delegate(TOKEN, _proxy);
  }

  function delegates(address _account) public view virtual returns (address) {
    return delegates(TOKEN, _account);
  }
}

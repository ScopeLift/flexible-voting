// SPDX-License-Identifier: MIT
pragma solidity >=0.8.10;

import {FlexVotingClient} from "src/FlexVotingClient.sol";

contract MockClient is FlexVotingClient {
  constructor(address _governor) FlexVotingClient(_governor) {}

  function _rawBalanceOf(address _user) internal view override returns (uint256) {
    return 42;
  }
}

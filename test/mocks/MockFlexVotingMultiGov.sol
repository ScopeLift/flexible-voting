// SPDX-License-Identifier: MIT
pragma solidity >=0.8.10;

import {FlexVotingClient} from "src/FlexVotingClient.sol";
import {FlexVotingMultiGov} from "src/FlexVotingMultiGov.sol";
import {MockFlexVotingClient} from "test/mocks/MockFlexVotingClient.sol";

contract MockFlexVotingDelegatableClient is MockFlexVotingClient, FlexVotingMultiGov {
  constructor(
    IFractionalGovernor _governor,
    address _owner
  ) MockFlexVotingClient(address(_governor)) FlexVotingMultiGov(_owner) {}
}

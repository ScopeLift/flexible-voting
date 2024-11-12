// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {IVotes} from "@openzeppelin/contracts/governance/utils/IVotes.sol";
import {IGovernor} from "@openzeppelin/contracts/governance/Governor.sol";

import {IVotingToken} from "../src/interfaces/IVotingToken.sol";
import {IFractionalGovernor} from "../src/interfaces/IFractionalGovernor.sol";
import {MockFlexVotingClient} from "./MockFlexVotingClient.sol";
import {GovToken} from "./GovToken.sol";
import {FractionalGovernor} from "./FractionalGovernor.sol";
import {ProposalReceiverMock} from "./ProposalReceiverMock.sol";

contract FlexVotingClientHandler is Test {

  MockFlexVotingClient flexClient;
  GovToken token;
  FractionalGovernor governor;
  ProposalReceiverMock receiver;

  constructor(
    GovToken _token,
    FractionalGovernor _governor,
    MockFlexVotingClient _client,
    ProposalReceiverMock _receiver
  ) {
    token = _token;
    flexClient = _client;
    governor = _governor;
    receiver = _receiver;
  }
}

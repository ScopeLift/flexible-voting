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

contract FlexVotingInvariantTest is Test {

  // going to need a few contracts:
  //   - govToken
  //   - fractional governor
  //   - flex client (mock flex client)
  //   - (probably) reciever for governor proposals
  //
  // what functions to expose?
  //   - flexClient.deposit
  //   - flexClient.withdraw
  //   - flexClient.expressVote
  //   - flexClient.castVote
  //
  // system invariants:
  //   - one vote per person per proposal
  //   - flex client should not allow anyone to increase effective voting
  //     weight, i.e. voteWeight <= deposit amount
  //   - sum of all user raw balances == total balance for all checkpoints
  //   - sum of ProposalVote attr == weight of users expressing votes
  //   - voting (without borrows) w/ flex client should not decrease vote weight

  MockFlexVotingClient flexClient;
  GovToken token;
  FractionalGovernor governor;
  ProposalReceiverMock receiver;
  FlexClientHandler handler;

  function setUp() public {
    token = new GovToken();
    vm.label(address(token), "token");

    governor = new FractionalGovernor("Governor", IVotes(token));
    vm.label(address(governor), "governor");

    flexClient = new MockFlexVotingClient(address(governor));
    vm.label(address(flexClient), "flexClient");

    receiver = new ProposalReceiverMock();
    vm.label(address(receiver), "receiver");
  }
}

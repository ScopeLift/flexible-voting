// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {IVotes} from "@openzeppelin/contracts/governance/utils/IVotes.sol";
import {IGovernor} from "@openzeppelin/contracts/governance/Governor.sol";

import {IVotingToken} from "src/interfaces/IVotingToken.sol";
import {IFractionalGovernor} from "src/interfaces/IFractionalGovernor.sol";
import {MockFlexVotingClient} from "test/MockFlexVotingClient.sol";
import {GovToken} from "test/GovToken.sol";
import {FractionalGovernor} from "test/FractionalGovernor.sol";
import {ProposalReceiverMock} from "test/ProposalReceiverMock.sol";
import {FlexVotingClientHandler} from "test/handlers/FlexVotingClientHandler.sol";

contract FlexVotingInvariantTest is Test {

  MockFlexVotingClient flexClient;
  GovToken token;
  FractionalGovernor governor;
  ProposalReceiverMock receiver;
  FlexVotingClientHandler handler;

  function setUp() public {
    token = new GovToken();
    vm.label(address(token), "token");

    governor = new FractionalGovernor("Governor", IVotes(token));
    vm.label(address(governor), "governor");

    flexClient = new MockFlexVotingClient(address(governor));
    vm.label(address(flexClient), "flexClient");

    receiver = new ProposalReceiverMock();
    vm.label(address(receiver), "receiver");

    handler = new FlexVotingClientHandler(token, governor, flexClient, receiver);

    bytes4[] memory selectors = new bytes4[](5);
    selectors[0] = FlexVotingClientHandler.deposit.selector;
    selectors[0] = FlexVotingClientHandler.withdraw.selector;
    selectors[0] = FlexVotingClientHandler.expressVote.selector;
    selectors[0] = FlexVotingClientHandler.castVote.selector;
    selectors[0] = FlexVotingClientHandler.propose.selector;

    targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    targetContract(address(handler));
  }

  // system invariants:
  //   - one vote per person per proposal
  //   - flex client should not allow anyone to increase effective voting
  //     weight, i.e. voteWeight <= deposit amount
  //   - sum of all user raw balances == total balance for all checkpoints
  //   - sum of ProposalVote attr == weight of users expressing votes
  //   - voting (without borrows) w/ flex client should not decrease vote weight

  function invariant_OneVotePerActorPerProposal() public {
    assertEq(handler.ghost_doubleVoteActors.length, 0);
  }
}

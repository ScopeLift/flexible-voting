// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console2} from "forge-std/Test.sol";
import {IVotes} from "@openzeppelin/contracts/governance/utils/IVotes.sol";
import {IGovernor} from "@openzeppelin/contracts/governance/Governor.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {GovernorCountingFractional as GCF} from "@openzeppelin/contracts/governance/extensions/GovernorCountingFractional.sol";

import {IVotingToken} from "src/interfaces/IVotingToken.sol";
import {IFractionalGovernor} from "src/interfaces/IFractionalGovernor.sol";
import {MockFlexVotingClient} from "test/MockFlexVotingClient.sol";
import {GovToken} from "test/GovToken.sol";
import {FractionalGovernor} from "test/FractionalGovernor.sol";
import {ProposalReceiverMock} from "test/ProposalReceiverMock.sol";
import {FlexVotingClientHandler} from "test/handlers/FlexVotingClientHandler.sol";

contract FlexVotingInvariantSetup is Test {
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

    // Proposal will underflow if we're on the zero block.
    if (block.number == 0) vm.roll(1);

    bytes4[] memory selectors = new bytes4[](6);
    selectors[0] = FlexVotingClientHandler.deposit.selector;
    selectors[1] = FlexVotingClientHandler.propose.selector;
    selectors[2] = FlexVotingClientHandler.expressVote.selector;
    selectors[3] = FlexVotingClientHandler.castVote.selector;
    selectors[4] = FlexVotingClientHandler.withdraw.selector;
    selectors[5] = FlexVotingClientHandler.roll.selector;

    targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    targetContract(address(handler));
  }
}

contract FlexVotingInvariantTest is FlexVotingInvariantSetup {
  // We want to make sure that things like this cannot happen:
  // - user A deposits X
  // - user A expresses FOR on proposal P
  // - castVote is called for P, user A's votes are cast
  // - stuff we can't imagine happens...
  // - user A expresses again on proposal P
  // - castVote is called for P, user A gets more votes through
  function invariant_OneVotePerActorPerProposal() public view {
    handler.callSummary();

    uint256[] memory _proposals = handler.getProposals();
    address[] memory _voters = handler.getVoters();
    for (uint256 p; p < _proposals.length; p++) {
      for (uint256 v; v < _voters.length; v++) {
        address _voter = _voters[v];
        uint256 _proposal = _proposals[p];
        assertTrue(handler.ghost_actorExpressedVotes(_voter, _proposal) <= 1);
      }
    }
  }

  // Flex client should not allow anyone to increase effective voting
  // weight, i.e. cast voteWeight <= deposit amount. Example:
  //   - user A deposits 70
  //   - user B deposits 30
  //   - user A expresses FOR
  //   - user B does NOT express
  //   - castVote is called
  //   - 100 votes are cast FOR proposal
  //   - user A's effective vote weight increased from 70 to 100
  function invariant_VoteWeightCannotIncrease() public view {
    handler.callSummary();

    for (uint256 i; i < handler.proposalLength(); i++) {
      uint256 _id = handler.proposal(i);
      assert(handler.ghost_votesCast(_id) <= handler.ghost_depositsCast(_id));
    }
  }

  // The flex client should not lend out more than it recieves.
  function invariant_WithdrawalsDontExceedDepoists() public view {
    handler.callSummary();

    assertTrue(handler.ghost_depositSum() >= handler.ghost_withdrawSum());
  }

  function invariant_SumOfDepositsEqualsTotalBalanceCheckpoint() public {
    handler.callSummary();

    uint256 _checkpoint = block.number;
    vm.roll(_checkpoint + 1);
    assertEq(
      flexClient.getPastTotalBalance(_checkpoint),
      handler.ghost_depositSum() - handler.ghost_withdrawSum()
    );

    uint256 _sum;
    address[] memory _depositors = handler.getActors();
    for (uint256 d; d < _depositors.length; d++) {
      address _depositor = _depositors[d];
      _sum += flexClient.getPastRawBalance(_depositor, _checkpoint);
    }
    assertEq(flexClient.getPastTotalBalance(_checkpoint), _sum);
  }

  function invariant_SumOfDepositsIsGTEProposalVotes() public view {
    handler.callSummary();

    uint256[] memory _proposals = handler.getProposals();
    for (uint256 p; p < _proposals.length; p++) {
      uint256 _proposalId = _proposals[p];

      (uint256 _againstVotes, uint256 _forVotes, uint256 _abstainVotes) =
        governor.proposalVotes(_proposalId);
      uint256 _totalVotesGov = _againstVotes + _forVotes + _abstainVotes;

      (_againstVotes, _forVotes, _abstainVotes) = flexClient.proposalVotes(_proposalId);
      uint256 _totalVotesClient = _againstVotes + _forVotes + _abstainVotes;

      // The votes recorded in the governor and those in the client waiting to
      // be cast should never exceed the total amount deposited.
      assertTrue(handler.ghost_depositSum() >= _totalVotesClient + _totalVotesGov);
    }
  }
}

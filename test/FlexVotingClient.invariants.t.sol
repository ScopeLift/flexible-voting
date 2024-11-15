// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {IVotes} from "@openzeppelin/contracts/governance/utils/IVotes.sol";
import {IGovernor} from "@openzeppelin/contracts/governance/Governor.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";

import {GovernorCountingFractional as GCF} from "src/GovernorCountingFractional.sol";
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
    selectors[1] = FlexVotingClientHandler.propose.selector;
    selectors[2] = FlexVotingClientHandler.expressVote.selector;
    selectors[3] = FlexVotingClientHandler.castVote.selector;
    selectors[4] = FlexVotingClientHandler.withdraw.selector;

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

  function test_multipleProposals() public {
    assertEq(handler.proposalLength(), 0);
    handler.propose("capital idea 'ol chap", 42424242);
    assertEq(handler.proposalLength(), 1);
    handler.propose("we should do dis", 1702);
    assertEq(handler.proposalLength(), 2);
    handler.propose("yuge, beautiful proposal", 5927392);
    assertEq(handler.proposalLength(), 3);
    handler.propose("a modest proposal", 1111111);
    assertEq(handler.proposalLength(), 4);

    // After 4 proposals we stop adding new ones. The call doesn't revert.
    handler.propose("yessiree bob", 7777777);
    assertEq(handler.proposalLength(), 4);
  }

  function test_deposit() public {
    uint128 _amount = 42424242;

    // It passes through deposits into the client.
    assertEq(flexClient.deposits(address(this)), 0);
    handler.deposit(_amount);
    assertEq(flexClient.deposits(address(this)), _amount);
    assertEq(handler.ghost_depositSum(), _amount);

    // It enforces deposit maximums.
    vm.expectPartialRevert(IERC20Errors.ERC20InsufficientBalance.selector);
    handler.deposit(type(uint128).max);
    assertEq(handler.ghost_depositSum(), _amount);
    handler.deposit(type(uint128).max - _amount);
    assertEq(handler.ghost_depositSum(), type(uint128).max);
  }

  function test_withdraw() public {
    uint256 _userSeed = 1; // There's only one actor, so it doesn't matter.
    uint128 _amount = 42424242;
    handler.deposit(_amount);

    // Deposits can be withdrawn from the flexClient through the handler.
    handler.withdraw(_userSeed, _amount / 2);
    assertEq(handler.ghost_depositSum(), _amount);
    assertEq(handler.ghost_withdrawSum(), _amount / 2);
    assertEq(flexClient.deposits(address(this)), _amount / 2);
    assertEq(token.balanceOf(address(this)), _amount / 2);

    // Try to withdraw a sane but still to large amount.
    vm.expectRevert();
    handler.withdraw(_userSeed, _amount);

    handler.withdraw(_userSeed, _amount / 2);
    assertEq(handler.ghost_withdrawSum(), _amount);
    assertEq(token.balanceOf(address(this)), _amount);
    assertEq(flexClient.deposits(address(this)), 0);
  }

  function test_withdrawAmountIsBounded() public {
    uint256 _userSeed = 1; // There's only one actor, so it doesn't matter.
    uint128 _amount = 42424242;
    handler.deposit(_amount);

    // Try to withdraw a crazy amount, it won't revert.
    handler.withdraw(_userSeed, uint208(type(uint128).max));
    assert(token.balanceOf(address(this)) > 0);
    assert(token.balanceOf(address(this)) < _amount);
    assert(flexClient.deposits(address(this)) > 0);
    assert(flexClient.deposits(address(this)) < _amount);
  }

  function testFuzz_expressVote(
    uint256 _userSeed,
    uint256 _proposalId,
    uint128 _amount
  ) public {
    _amount = uint128(bound(_amount, 1, type(uint128).max));
    uint8 _voteType = uint8(GCF.VoteType.For);

    vm.expectRevert(bytes("no weight"));
    handler.expressVote(_proposalId, _voteType, _userSeed);

    handler.deposit(_amount);

    vm.expectRevert(bytes("no weight"));
    handler.expressVote(_proposalId, _voteType, _userSeed);

    // There needs to be a proposal.
    handler.propose("a beautiful proposal", 5927392);

    // Express vote on the handler passes through to the client.
    handler.expressVote(_proposalId, _voteType, _userSeed);
    _proposalId = handler.lastProposal();
    (,uint128 _forVotes,) = flexClient.proposalVotes(_proposalId);
    assertEq(_forVotes, _amount);
    vm.expectRevert(bytes("already voted"));
    handler.expressVote(_proposalId, _voteType, _userSeed);

    // Internal accounting is correct.
    assertEq(handler.ghost_actorProposalVotes(address(this), _proposalId), 1);
  }

  // function invariant_OneVotePerActorPerProposal() public {
  //   handler.callSummary();
  //   assertEq(handler.ghost_doubleVoteActors(), 0);
  // }
}

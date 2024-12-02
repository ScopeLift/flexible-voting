// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

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

  // function test_withdraw() public {
  //   uint256 _userSeed = 1; // There's only one actor, so it doesn't matter.
  //   uint128 _amount = 42424242;
  //   handler.deposit(_amount);
  //
  //   // Deposits can be withdrawn from the flexClient through the handler.
  //   handler.withdraw(_userSeed, _amount / 2);
  //   assertEq(handler.ghost_depositSum(), _amount);
  //   assertEq(handler.ghost_withdrawSum(), _amount / 2);
  //   assertEq(flexClient.deposits(address(this)), _amount / 2);
  //   assertEq(token.balanceOf(address(this)), _amount / 2);
  //
  //   handler.withdraw(_userSeed, _amount / 2);
  //   assertEq(handler.ghost_withdrawSum(), _amount);
  //   assertEq(token.balanceOf(address(this)), _amount);
  //   assertEq(flexClient.deposits(address(this)), 0);
  // }
  //
  // function test_withdrawAmountIsBounded() public {
  //   uint256 _userSeed = 1; // There's only one actor, so it doesn't matter.
  //   uint128 _amount = 42424242;
  //   handler.deposit(_amount);
  //
  //   // Try to withdraw a crazy amount, it won't revert.
  //   handler.withdraw(_userSeed, uint208(type(uint128).max));
  //   assert(token.balanceOf(address(this)) > 0);
  //   assert(token.balanceOf(address(this)) < _amount);
  //   assert(flexClient.deposits(address(this)) > 0);
  //   assert(flexClient.deposits(address(this)) < _amount);
  // }
  //
  // function testFuzz_expressVote(
  //   uint256 _userSeed,
  //   uint256 _proposalId,
  //   uint128 _amount
  // ) public {
  //   _amount = uint128(bound(_amount, 1, type(uint128).max));
  //   uint8 _voteType = uint8(GCF.VoteType.For);
  //
  //   vm.expectRevert(bytes("no weight"));
  //   handler.expressVote(_proposalId, _voteType, _userSeed);
  //
  //   handler.deposit(_amount);
  //
  //   vm.expectRevert(bytes("no weight"));
  //   handler.expressVote(_proposalId, _voteType, _userSeed);
  //
  //   // There needs to be a proposal.
  //   handler.propose("a beautiful proposal", 5927392);
  //
  //   // Express vote on the handler passes through to the client.
  //   handler.expressVote(_proposalId, _voteType, _userSeed);
  //   _proposalId = handler.lastProposal();
  //   (,uint128 _forVotes,) = flexClient.proposalVotes(_proposalId);
  //   assertEq(_forVotes, _amount);
  //   vm.expectRevert(bytes("already voted"));
  //   handler.expressVote(_proposalId, _voteType, _userSeed);
  //
  //   // Internal accounting is correct.
  //   assertEq(handler.ghost_actorProposalVotes(address(this), _proposalId), 1);
  // }
  //
  // function testFuzz_castVote(
  //   uint256 _proposalSeed,
  //   uint256 _userSeed,
  //   uint128 _amount
  // ) public {
  //   _amount = uint128(bound(_amount, 1, type(uint128).max));
  //
  //   // Won't revert even with no votes cast. This avoids uninteresting reverts.
  //   handler.castVote(_proposalSeed);
  //
  //   uint8 _voteType = uint8(GCF.VoteType.Against);
  //
  //   handler.deposit(_amount);
  //   handler.propose("a gorgeous proposal", _proposalSeed);
  //   handler.expressVote(_proposalSeed, _voteType, _userSeed);
  //   handler.castVote(_proposalSeed);
  //
  //   uint256 _proposalId = handler.lastProposal();
  //   (uint256 _againstVotes, uint256 _forVotes, uint256 _abstainVotes) =
  //     governor.proposalVotes(_proposalId);
  //
  //   assertEq(_forVotes, 0);
  //   assertEq(_againstVotes, _amount);
  //   assertEq(_abstainVotes, 0);
  // }

  // // We want to make sure that things like this cannot happen:
  // // - user A deposits X
  // // - user A expresses FOR on proposal P
  // // - castVote is called for P, user A's votes are cast
  // // - stuff we can't imagine happens...
  // // - user A expresses again on proposal P
  // // - castVote is called for P, user A gets more votes through
  // function invariant_OneVotePerActorPerProposal() public {
  //   // TODO why are no proposals getting created here for this invariant?
  //   handler.callSummary();
  //   // TODO the logic for checking this should probably live here rather than in
  //   // the handler, e.g.:
  //   //   for proposal in handler.proposals {
  //   //     for voter in handler.voters {
  //   //       assert(ghost_actorExpressedVotes[voter][proposal] <= 1)
  //   //     }
  //   //   }
  //   assertEq(handler.ghost_doubleVoteActors(), 0);
  // }
  //
  // // Flex client should not allow anyone to increase effective voting
  // // weight, i.e. cast voteWeight <= deposit amount. Example:
  // //   - user A deposits 70
  // //   - user B deposits 30
  // //   - user A expresses FOR
  // //   - user B does NOT express
  // //   - castVote is called
  // //   - 100 votes are cast FOR proposal
  // //   - user A's effective vote weight increased from 70 to 100
  // function invariant_VoteWeightCannotIncrease() public {
  //   handler.callSummary();
  //   for (uint256 i; i < handler.proposalLength(); i++) {
  //     uint256 _id = handler.proposal(i);
  //     assert(handler.ghost_votesCast(_id) <= handler.ghost_depositsCast(_id));
  //   }
  // }
  //
  // function invariant_SumOfRawBalancesEqualsTotalBalanceCheckpoint() public {
  // }

  // system invariants:
  //   x one vote per person per proposal
  //   x flex client should not allow anyone to increase effective voting
  //     weight, i.e. voteWeight <= deposit amount
  //   - sum of all user raw balances == total balance for all checkpoints
  //   - sum of ProposalVote attr == weight of users expressing votes
  //   - voting (without borrows) w/ flex client should not decrease vote weight
}

contract FlexVotingClientHandlerTest is FlexVotingInvariantTest {
  function _bytesToUser(bytes memory _entropy) internal returns (address) {
    return address(uint160(uint256(keccak256(_entropy))));
  }

  function _makeActors(uint256 _seed, uint256 _n) internal {
    for (uint256 i; i < _n; i++) {
      address _randUser = _bytesToUser(abi.encodePacked(_seed, _n, i));
      uint208 _amount = uint208(bound(_seed, 1, handler.remainingTokens() / _n));
      vm.startPrank(_randUser);
      handler.deposit(_amount);
      vm.stopPrank();
    }
  }

}

contract Propose is FlexVotingClientHandlerTest {
  function testFuzz_multipleProposals(uint256 _seed) public {
    // No proposal is created if there are no actors.
    assertEq(handler.proposalLength(), 0);
    handler.propose("capital idea 'ol chap", 42424242);
    assertEq(handler.proposalLength(), 0);

    // A critical mass of actors is required.
    _makeActors(_seed, 90);
    handler.propose("capital idea 'ol chap", 42424242);
    assertEq(handler.proposalLength(), 1);

    // We cap the number of proposals.
    handler.propose("we should do dis", 1702);
    assertEq(handler.proposalLength(), 2);
    handler.propose("yuge, beautiful proposal", 5927392);
    assertEq(handler.proposalLength(), 3);
    handler.propose("a modest proposal", 1111111);
    assertEq(handler.proposalLength(), 4);
    handler.propose("yessiree bob", 7777777);
    assertEq(handler.proposalLength(), 5);

    // After 5 proposals we stop adding new ones.
    // The call doesn't revert.
    handler.propose("this will be a no-op", 1029384756);
    assertEq(handler.proposalLength(), 5);
  }
}

contract Deposit is FlexVotingClientHandlerTest {
  function testFuzz_passesDepositsToClient(uint128 _amount) public {
    address _user = _bytesToUser(abi.encodePacked(_amount));

    vm.expectCall(
      address(flexClient),
      abi.encodeCall(flexClient.deposit, _amount)
    );
    vm.expectCall(
      address(token),
      abi.encodeCall(token.approve, (address(flexClient), _amount))
    );
    vm.startPrank(_user);
    assertEq(flexClient.deposits(_user), 0);
    handler.deposit(_amount);
    assertEq(flexClient.deposits(_user), _amount);
    assertEq(handler.ghost_depositSum(), _amount);
    vm.stopPrank();
  }

  function testFuzz_mintsNeededTokens(uint128 _amount) public {
    address _user = _bytesToUser(abi.encodePacked(_amount));

    assertEq(handler.ghost_mintedTokens(), 0);
    vm.expectCall(
      address(token),
      abi.encodeCall(token.exposed_mint, (_user, _amount))
    );

    vm.startPrank(_user);
    handler.deposit(_amount);
    vm.stopPrank();

    assertEq(handler.ghost_mintedTokens(), _amount);
  }

  function testFuzz_tracksTheCaller(uint128 _amount) public {
    address _user = _bytesToUser(abi.encodePacked(_amount));

    assertEq(handler.lastActor(), address(0));

    vm.startPrank(_user);
    handler.deposit(_amount);
    vm.stopPrank();

    assertEq(handler.lastActor(), _user);
  }

  function testFuzz_tracksVoters(
    uint128 _amountA,
    uint128 _amountB
  ) public {
    address _userA = makeAddr("userA");
    uint128 _reservedForOtherActors = 1e24;
    uint128 _remaining = handler.MAX_TOKENS() - _reservedForOtherActors;
    _amountA = uint128(bound(_amountA, 1, _remaining - 1));
    _amountB = uint128(bound(_amountB, 1, _remaining - _amountA));

    assertEq(handler.lastProposal(), 0);
    assertEq(handler.lastVoter(), address(0));

    vm.startPrank(_userA);
    handler.deposit(_amountA);
    vm.stopPrank();

    // Pre-proposal
    assertEq(handler.lastActor(), _userA);
    assertEq(handler.lastVoter(), _userA);

    // Create a proposal.
    uint256 _seed = uint256(_amountA);
    _makeActors(_remaining / 89, 89);
    uint256 _proposalId = handler.propose("jolly good idea", _seed);
    assertEq(handler.lastProposal(), _proposalId);

    // New depositors are no longer considered "voters".
    address _userB = makeAddr("userB");
    vm.startPrank(_userB);
    handler.deposit(_amountB);
    vm.stopPrank();
    assertEq(handler.lastActor(), _userB);
    assertNotEq(handler.lastVoter(), _userB);
  }

  function testFuzz_incrementsDepositSum(uint128 _amount) public {
    address _user = _bytesToUser(abi.encodePacked(_amount));
    vm.assume(flexClient.deposits(_user) == 0);
    assertEq(handler.ghost_depositSum(), 0);

    vm.startPrank(_user);
    handler.deposit(_amount);
    assertEq(handler.ghost_depositSum(), _amount);
    assertEq(handler.ghost_accountDeposits(_user), _amount);
    vm.stopPrank();
  }

  function testFuzz_capsDepositsAtTokenMax(uint208 _amount) public {
    address _user = _bytesToUser(abi.encodePacked(_amount));
    vm.assume(flexClient.deposits(_user) == 0);
    assertEq(handler.ghost_depositSum(), 0);

    vm.startPrank(_user);
    handler.deposit(_amount);
    vm.stopPrank();

    assert(handler.ghost_mintedTokens() <= handler.MAX_TOKENS());
  }
}

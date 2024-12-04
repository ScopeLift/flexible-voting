// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console2} from "forge-std/Test.sol";
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

    bytes4[] memory selectors = new bytes4[](5);
    selectors[0] = FlexVotingClientHandler.deposit.selector;
    selectors[1] = FlexVotingClientHandler.propose.selector;
    selectors[2] = FlexVotingClientHandler.expressVote.selector;
    selectors[3] = FlexVotingClientHandler.castVote.selector;
    selectors[4] = FlexVotingClientHandler.withdraw.selector;

    targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    targetContract(address(handler));
  }
}

contract FlexVotingInvariantTest is FlexVotingInvariantSetup {
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

  // Flex client should not allow anyone to increase effective voting
  // weight, i.e. cast voteWeight <= deposit amount. Example:
  //   - user A deposits 70
  //   - user B deposits 30
  //   - user A expresses FOR
  //   - user B does NOT express
  //   - castVote is called
  //   - 100 votes are cast FOR proposal
  //   - user A's effective vote weight increased from 70 to 100
  // function invariant_VoteWeightCannotIncrease() public {
  //   handler.callSummary();
  //   for (uint256 i; i < handler.proposalLength(); i++) {
  //     uint256 _id = handler.proposal(i);
  //     assert(handler.ghost_votesCast(_id) <= handler.ghost_depositsCast(_id));
  //   }
  // }

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

contract FlexVotingClientHandlerTest is FlexVotingInvariantSetup {
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

  function _validVoteType(uint8 _seed) internal returns (uint8) {
    return uint8(_bound(
      uint256(_seed),
      uint256(type(GCF.VoteType).min),
      uint256(type(GCF.VoteType).max)
    ));
  }
}

contract Propose is FlexVotingClientHandlerTest {
  function testFuzz_multipleProposals(uint256 _seed) public {
    // No proposal is created if there are no actors.
    assertEq(handler.proposalLength(), 0);
    handler.propose("capital idea 'ol chap");
    assertEq(handler.proposalLength(), 0);

    // A critical mass of actors is required.
    _makeActors(_seed, 90);
    handler.propose("capital idea 'ol chap");
    assertEq(handler.proposalLength(), 1);

    // We cap the number of proposals.
    handler.propose("we should do dis");
    assertEq(handler.proposalLength(), 2);
    handler.propose("yuge, beautiful proposal");
    assertEq(handler.proposalLength(), 3);
    handler.propose("a modest proposal");
    assertEq(handler.proposalLength(), 4);
    handler.propose("yessiree bob");
    assertEq(handler.proposalLength(), 5);

    // After 5 proposals we stop adding new ones.
    // The call doesn't revert.
    handler.propose("this will be a no-op");
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
    _makeActors(_remaining / 89, 89);
    uint256 _proposalId = handler.propose("jolly good idea");
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

    if (_amount > handler.MAX_TOKENS()) {
      assert(flexClient.deposits(_user) < _amount);
    }

    assert(handler.ghost_mintedTokens() <= handler.MAX_TOKENS());
  }
}

contract Withdraw is FlexVotingClientHandlerTest {
  function testFuzz_withdraw(uint208 _amount) public {
    address _user = _bytesToUser(abi.encodePacked(_amount));
    _amount = uint208(bound(_amount, 1, handler.MAX_TOKENS()));

    // There's only one actor, so seed doesn't matter.
    uint256 _userSeed = uint256(_amount);

    vm.startPrank(_user);
    handler.deposit(_amount);
    vm.stopPrank();

    uint208 _initAmount = _amount / 3;

    // Deposits can be withdrawn from the flexClient through the handler.
    vm.startPrank(_user);
    vm.expectCall(
      address(flexClient),
      abi.encodeCall(flexClient.withdraw, _initAmount)
    );
    handler.withdraw(_userSeed, _initAmount);
    vm.stopPrank();

    assertEq(handler.ghost_depositSum(), _amount);
    assertEq(handler.ghost_withdrawSum(), _initAmount);
    assertEq(handler.ghost_accountDeposits(_user), _amount - _initAmount);
    assertEq(flexClient.deposits(_user), _amount - _initAmount);
    assertEq(token.balanceOf(_user), _initAmount);

    vm.startPrank(_user);
    handler.withdraw(_userSeed, _amount - _initAmount);
    vm.stopPrank();

    assertEq(handler.ghost_withdrawSum(), _amount);
    assertEq(handler.ghost_accountDeposits(_user), 0);
    assertEq(token.balanceOf(_user), _amount);
    assertEq(flexClient.deposits(_user), 0);
  }

  function testFuzz_amountIsBounded(uint208 _amount) public {
    address _user = _bytesToUser(abi.encodePacked(_amount));
    // There's only one actor, so seed doesn't matter.
    uint256 _userSeed = uint256(_amount);

    // Try to withdraw a crazy amount, it won't revert.
    vm.startPrank(_user);
    handler.deposit(_amount);
    handler.withdraw(_userSeed, type(uint208).max);
    vm.stopPrank();

    assert(token.balanceOf(_user) <= _amount);
    assertTrue(flexClient.deposits(_user) <= _amount);
  }
}

contract ExpressVote is FlexVotingClientHandlerTest {
  function testFuzz_hasInternalAccounting(
    uint256 _userSeed,
    uint256 _proposalId,
    uint8 _voteType,
    uint128 _amount
  ) public {
    address _user = _bytesToUser(abi.encodePacked(_userSeed));
    // We need actors to cross the proposal threshold on expressVote.
    uint128 _actorCount = 89;
    uint128 _reserved = _actorCount * 1e24; // Tokens for other actors.
    _amount = uint128(bound(_amount, 1, handler.MAX_TOKENS() - _reserved));
    _voteType = _validVoteType(_voteType);

    _makeActors(_reserved / _actorCount, _actorCount);

    vm.startPrank(_user);
    handler.deposit(_amount);
    _actorCount += 1; // Deposit adds an actor/voter.

    // There's no proposal, so this should be a no-op.
    handler.expressVote(_proposalId, _voteType, _userSeed);
    assertFalse(handler.hasPendingVotes(_user, _proposalId));
    assertEq(
      handler.ghost_actorExpressedVotes(_user, _proposalId),
      0
    );
    (uint256 _againstVotes, uint256 _forVotes, uint256 _abstainVotes) =
      flexClient.proposalVotes(_proposalId);
    assertEq(_againstVotes, 0);
    assertEq(_forVotes, 0);
    assertEq(_abstainVotes, 0);

    _proposalId = handler.propose("a beautiful proposal");

    // This seed that allows us to force use of the voter we want.
    uint256 _seedForVoter = _actorCount - 1; // e.g. 89 % 90 = 89

    // Finally, we can call expressVote.
    vm.expectCall(
      address(flexClient),
      abi.encodeCall(flexClient.expressVote, (_proposalId, _voteType))
    );
    handler.expressVote(_proposalId, _voteType, _seedForVoter);
    assertTrue(handler.hasPendingVotes(_user, _proposalId));
    assertEq(handler.ghost_actorExpressedVotes(_user, _proposalId), 1);

    // The vote preference should have been recorded by the client.
    (_againstVotes, _forVotes, _abstainVotes) = flexClient.proposalVotes(_proposalId);
    if (_voteType == uint8(GCF.VoteType.Against)) assertEq(_amount, _againstVotes);
    if (_voteType == uint8(GCF.VoteType.For)) assertEq(_amount, _forVotes);
    if (_voteType == uint8(GCF.VoteType.Abstain)) assertEq(_amount, _abstainVotes);

    // The user should not be able to vote again.
    vm.expectRevert(bytes("already voted"));
    handler.expressVote(_proposalId, _voteType, _seedForVoter);

    vm.stopPrank();
  }
}

contract CastVote is FlexVotingClientHandlerTest {
  function testFuzz_doesNotRequireProposalToExist(
    uint256 _proposalSeed
  ) public {
    assertEq(handler.lastProposal(), 0);
    // Won't revert even with no votes cast.
    // This avoids uninteresting reverts during invariant runs.
    handler.castVote(_proposalSeed);
  }

  function testFuzz_passesThroughToFlexClient(
    uint256 _proposalSeed,
    uint256 _userSeed,
    uint8 _voteType,
    uint128 _amount
  ) public {
    _voteType = _validVoteType(_voteType);
    // We need actors to cross the proposal threshold on expressVote.
    uint128 _actorCount = 90;
    uint128 _voteSize = 1e24;
    uint128 _reserved = _actorCount * _voteSize; // Tokens for actors.
    _makeActors(_reserved / _actorCount, _actorCount);

    uint256 _proposalId = handler.propose("a preposterous proposal");

    assertFalse(handler.hasPendingVotes(makeAddr("joe"), _proposalId));

    address _actor = handler.expressVote(_proposalSeed, _voteType, _userSeed);
    assertTrue(handler.hasPendingVotes(_actor, _proposalId));

    vm.expectCall(
      address(flexClient),
      abi.encodeCall(flexClient.castVote, _proposalId)
    );
    handler.castVote(_proposalSeed);

    // The actor should no longer have pending votes.
    assertFalse(handler.hasPendingVotes(_actor, _proposalId));

    // The vote preference should have been sent to the Governor.
    (uint256 _againstVotes, uint256 _forVotes, uint256 _abstainVotes) =
      governor.proposalVotes(_proposalId);
    if (_voteType == uint8(GCF.VoteType.Against)) assertEq(_voteSize, _againstVotes);
    if (_voteType == uint8(GCF.VoteType.For)) assertEq(_voteSize, _forVotes);
    if (_voteType == uint8(GCF.VoteType.Abstain)) assertEq(_voteSize, _abstainVotes);
  }

  function testFuzz_aggregatesVotes(
    uint256 _proposalSeed,
    uint128 _weightA,
    uint128 _weightB,
    uint8 _voteTypeA,
    uint8 _voteTypeB
  ) public {
    // We need actors to cross the proposal threshold on expressVote.
    uint128 _actorCount = 90;
    uint128 _voteSize = 1e24;
    uint128 _reserved = _actorCount * _voteSize; // Tokens for actors.
    _makeActors(_reserved / _actorCount, _actorCount);

    _weightA = uint128(bound(_weightA, 1, handler.MAX_TOKENS() - _reserved - 1));
    _weightB = uint128(bound(_weightB, 1, handler.MAX_TOKENS() - _reserved - _weightA));

    address _alice = makeAddr("alice");
    vm.startPrank(_alice);
    handler.deposit(_weightA);
    vm.stopPrank();

    address _bob = makeAddr("bob");
    vm.startPrank(_bob);
    handler.deposit(_weightB);
    vm.stopPrank();

    uint256 _proposalId = handler.propose("a preposterous proposal");

    assertFalse(handler.hasPendingVotes(_alice, _proposalId));
    assertFalse(handler.hasPendingVotes(_bob, _proposalId));

    // The seeds that allow us to force use of the voter we want.
    uint256 _totalActors = _actorCount + 2; // Plus alice and bob.
    uint256 _seedForBob = _totalActors - 1; // Bob was added last.
    uint256 _seedForAlice = _totalActors - 2; // Alice is second to last.

    // _proposalSeed doesn't matter because there's only one proposal.
    _voteTypeA = _validVoteType(_voteTypeA);
    handler.expressVote(_proposalSeed, _voteTypeA, _seedForAlice);
    assertTrue(handler.hasPendingVotes(_alice, _proposalId));

    _voteTypeB = _validVoteType(_voteTypeB);
    handler.expressVote(_proposalSeed, _voteTypeB, _seedForBob);
    assertTrue(handler.hasPendingVotes(_bob, _proposalId));

    // No votes have been cast yet.
    assertEq(handler.ghost_votesCast(_proposalId), 0);

    // _proposalSeed doesn't matter because there's only one proposal.
    handler.castVote(_proposalSeed);

    // The actors should no longer have pending votes.
    assertFalse(handler.hasPendingVotes(_alice, _proposalId));
    assertFalse(handler.hasPendingVotes(_bob, _proposalId));

    assertEq(handler.ghost_votesCast(_proposalId), _weightA + _weightB);
    assertEq(handler.ghost_depositsCast(_proposalId), _weightA + _weightB);
  }

  function testFuzz_aggregatesVotesAcrossCasts(
    uint256 _proposalSeed,
    uint128 _weightA,
    uint128 _weightB,
    uint8 _voteTypeA,
    uint8 _voteTypeB
  ) public {
    // We need actors to cross the proposal threshold on expressVote.
    uint128 _actorCount = 90;
    uint128 _voteSize = 1e24;
    uint128 _reserved = _actorCount * _voteSize; // Tokens for actors.
    _makeActors(_reserved / _actorCount, _actorCount);

    _weightA = uint128(bound(_weightA, 1, handler.MAX_TOKENS() - _reserved - 1));
    _weightB = uint128(bound(_weightB, 1, handler.MAX_TOKENS() - _reserved - _weightA));

    address _alice = makeAddr("alice");
    vm.startPrank(_alice);
    handler.deposit(_weightA);
    vm.stopPrank();

    address _bob = makeAddr("bob");
    vm.startPrank(_bob);
    handler.deposit(_weightB);
    vm.stopPrank();

    uint256 _proposalId = handler.propose("a preposterous proposal");

    assertFalse(handler.hasPendingVotes(_alice, _proposalId));
    assertFalse(handler.hasPendingVotes(_bob, _proposalId));

    // The seeds that allow us to force use of the voter we want.
    uint256 _totalActors = _actorCount + 2; // Plus alice and bob.
    uint256 _seedForBob = _totalActors - 1; // Bob was added last.
    uint256 _seedForAlice = _totalActors - 2; // Alice is second to last.

    // Now alice expresses her voting preference.
    _voteTypeA = _validVoteType(_voteTypeA);
    handler.expressVote(_proposalSeed, _voteTypeA, _seedForAlice);
    assertTrue(handler.hasPendingVotes(_alice, _proposalId));

    handler.castVote(_proposalSeed);

    assertEq(handler.ghost_votesCast(_proposalId), _weightA);
    assertEq(handler.ghost_depositsCast(_proposalId), _weightA);
    assertFalse(handler.hasPendingVotes(_alice, _proposalId));

    // Now bob expresses his voting preference.
    _voteTypeB = _validVoteType(_voteTypeB);
    handler.expressVote(_proposalSeed, _voteTypeB, _seedForBob);
    assertTrue(handler.hasPendingVotes(_bob, _proposalId));

    handler.castVote(_proposalSeed);

    assertEq(handler.ghost_votesCast(_proposalId), _weightA + _weightB);
    assertEq(handler.ghost_depositsCast(_proposalId), _weightA + _weightB);
    assertFalse(handler.hasPendingVotes(_bob, _proposalId));
  }
  // Aggregates deposit weight via ghost_depositsCast.
  //   - user A deposits 70
  //   - user B deposits 30
  //   - user A withdraws 30
  //   - proposal is made
  //   - user A expressesVote
  //   - user B does NOT express
  //   - the contract has 70 weight to vote with, but we want to make sure it
  //     doesn't vote with all of it
  //   - castVote is called
  //   - ghost_VotesCast should = 40    <-- checks at the governor level
  //   - ghost_DepositsCast should = 40 <-- checks at the client level
  function testFuzz_tracksDepositsCast(
    uint256 _proposalSeed,
    uint128 _weightA,
    uint128 _weightB,
    uint8 _voteTypeA
  ) public {
    // We need actors to cross the proposal threshold on expressVote.
    uint128 _actorCount = 90;
    uint128 _voteSize = 1e24;
    uint128 _reserved = _actorCount * _voteSize; // Tokens for actors.
    _makeActors(_reserved / _actorCount, _actorCount);

    // The seeds that allow us to force use of the voter we want.
    uint256 _totalActors = _actorCount + 2; // Plus alice and bob.
    uint256 _seedForBob = _totalActors - 1; // Bob was added last.
    uint256 _seedForAlice = _totalActors - 2; // Alice is second to last.

    // User B needs to have less weight than User A.
    uint128 _remainingTokens = handler.MAX_TOKENS() - _reserved;
    _weightA = uint128(bound(
      _weightA,
      (_remainingTokens / 2) + 1,
      _remainingTokens - 1
    ));
    _weightB = uint128(bound(_weightB, 1, _remainingTokens - _weightA));

    address _alice = makeAddr("alice");
    vm.startPrank(_alice);
    handler.deposit(_weightA);
    vm.stopPrank();

    address _bob = makeAddr("bob");
    vm.startPrank(_bob);
    handler.deposit(_weightB);
    vm.stopPrank();

    // Before anything is proposed, Alice withdraws equal to *Bob's* balance.
    vm.startPrank(_alice);
    handler.withdraw(_seedForAlice, _weightB);
    vm.stopPrank();

    uint256 _proposalId = handler.propose("a party");

    // Now Alice expresses her voting preference.
    // Bob does not express a preference.
    _voteTypeA = _validVoteType(_voteTypeA);
    handler.expressVote(_proposalSeed, _voteTypeA, _seedForAlice);
    assertTrue(handler.hasPendingVotes(_alice, _proposalId));

    // Votes are cast.
    handler.castVote(_proposalSeed);

    // Bob's weight should not have been used by Alice to vote..
    assertEq(handler.ghost_votesCast(_proposalId), _weightA - _weightB);
    assertEq(handler.ghost_depositsCast(_proposalId), _weightA - _weightB);

    // TODO There is no way to make ghost_votesCast come apart from
    // ghost_depositsCast in tests, so it's not clear they are tracking
    // something different.
  }
}

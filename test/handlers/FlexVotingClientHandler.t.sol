// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console2} from "forge-std/Test.sol";
import {FlexVotingInvariantSetup} from "test/FlexVotingClient.invariants.t.sol";
import {FlexVotingClient as FVC} from "src/FlexVotingClient.sol";
import {GovernorCountingSimple as GCS} from "@openzeppelin/contracts/governance/extensions/GovernorCountingSimple.sol";

contract FlexVotingClientHandlerTest is FlexVotingInvariantSetup {
  // Amounts evenly divisible by 9 do not create new users.
  uint256 MAGIC_NUMBER = 9;

  function _bytesToUser(bytes memory _entropy) internal pure returns (address) {
    return address(uint160(uint256(keccak256(_entropy))));
  }

  function _makeActors(uint256 _seed, uint256 _n) internal {
    for (uint256 i; i < _n; i++) {
      address _randUser = _bytesToUser(abi.encodePacked(_seed, _n, i));
      uint208 _amount = uint208(bound(_seed, 1, handler.remainingTokens() / _n));
      // We want to create new users.
      if (_amount % MAGIC_NUMBER == 0) _amount += 1;
      vm.startPrank(_randUser);
      handler.deposit(_amount);
      vm.stopPrank();
    }
  }

  function _validVoteType(uint8 _seed) internal pure returns (uint8) {
    return uint8(
      _bound(uint256(_seed), uint256(type(GCS.VoteType).min), uint256(type(GCS.VoteType).max))
    );
  }
}

contract Propose is FlexVotingClientHandlerTest {
  function testFuzz_multipleProposals(uint256 _seed) public {
    // No proposal is created if there are no actors.
    assertEq(handler.proposalLength(), 0);
    handler.propose("capital idea 'ol chap");
    assertEq(handler.proposalLength(), 0);

    // A critical mass of actors is required.
    _makeActors(_seed, handler.PROPOSAL_THRESHOLD());
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
    assertEq(token.balanceOf(address(flexClient)), 0);
    assertEq(flexClient.deposits(_user), 0);

    vm.startPrank(_user);
    vm.expectCall(address(flexClient), abi.encodeCall(flexClient.deposit, _amount));
    vm.expectCall(address(token), abi.encodeCall(token.approve, (address(flexClient), _amount)));
    handler.deposit(_amount);
    vm.stopPrank();

    assertEq(flexClient.deposits(_user), _amount);
    assertEq(handler.ghost_depositSum(), _amount);
    assertEq(token.balanceOf(address(flexClient)), _amount);
  }

  function testFuzz_mintsNeededTokens(uint128 _amount) public {
    address _user = _bytesToUser(abi.encodePacked(_amount));

    assertEq(handler.ghost_mintedTokens(), 0);
    vm.expectCall(address(token), abi.encodeCall(token.exposed_mint, (_user, _amount)));

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

  function testFuzz_tracksVoters(uint128 _amountA, uint128 _amountB) public {
    address _userA = makeAddr("userA");
    uint128 _reservedForOtherActors = 1e24;
    uint128 _remaining = handler.MAX_TOKENS() - _reservedForOtherActors;
    _amountA = uint128(bound(_amountA, 1, _remaining - 1));
    _amountB = uint128(bound(_amountB, 1, _remaining - _amountA));
    if (_amountA % MAGIC_NUMBER == 0) _amountA -= 1;
    if (_amountB % MAGIC_NUMBER == 0) _amountB -= 1;

    assertEq(handler.lastProposal(), 0);
    assertEq(handler.lastVoter(), address(0));

    vm.startPrank(_userA);
    handler.deposit(_amountA);
    vm.stopPrank();

    // Pre-proposal
    assertEq(handler.lastActor(), _userA);
    assertEq(handler.lastVoter(), _userA);

    // Create a proposal.
    _makeActors(_remaining / handler.PROPOSAL_THRESHOLD(), handler.PROPOSAL_THRESHOLD());
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

    if (_amount > handler.MAX_TOKENS()) assert(flexClient.deposits(_user) < _amount);

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

    assertEq(token.balanceOf(_user), 0);
    uint208 _initAmount = _amount / 3;

    // Deposits can be withdrawn from the flexClient through the handler.
    vm.startPrank(_user);
    vm.expectCall(address(flexClient), abi.encodeCall(flexClient.withdraw, _initAmount));
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
    uint128 _actorCount = handler.PROPOSAL_THRESHOLD() - 1;
    uint128 _reserved = _actorCount * 1e24; // Tokens for other actors.
    _amount = uint128(bound(_amount, 1, handler.MAX_TOKENS() - _reserved));
    if (_amount % MAGIC_NUMBER == 0) _amount -= 1;
    _voteType = _validVoteType(_voteType);

    _makeActors(_reserved / _actorCount, _actorCount);

    vm.startPrank(_user);
    handler.deposit(_amount);
    _actorCount += 1; // Deposit adds an actor/voter.

    // There's no proposal, so this should be a no-op.
    handler.expressVote(_proposalId, _voteType, _userSeed);
    assertFalse(handler.hasPendingVotes(_user, _proposalId));
    assertEq(handler.ghost_actorExpressedVotes(_user, _proposalId), 0);
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
      address(flexClient), abi.encodeCall(flexClient.expressVote, (_proposalId, _voteType))
    );
    handler.expressVote(_proposalId, _voteType, _seedForVoter);
    assertTrue(handler.hasPendingVotes(_user, _proposalId));
    assertEq(handler.ghost_actorExpressedVotes(_user, _proposalId), 1);

    // The vote preference should have been recorded by the client.
    (_againstVotes, _forVotes, _abstainVotes) = flexClient.proposalVotes(_proposalId);
    if (_voteType == uint8(GCS.VoteType.Against)) assertEq(_amount, _againstVotes);
    if (_voteType == uint8(GCS.VoteType.For)) assertEq(_amount, _forVotes);
    if (_voteType == uint8(GCS.VoteType.Abstain)) assertEq(_amount, _abstainVotes);

    // The user should not be able to vote again.
    vm.expectRevert(FVC.FlexVotingClient__AlreadyVoted.selector);
    handler.expressVote(_proposalId, _voteType, _seedForVoter);

    vm.stopPrank();
  }
}

contract CastVote is FlexVotingClientHandlerTest {
  function testFuzz_doesNotRequireProposalToExist(uint256 _proposalSeed) public {
    assertEq(handler.lastProposal(), 0);
    // Won't revert even with no votes cast.
    // This avoids uninteresting reverts during invariant runs.
    handler.castVote(_proposalSeed);
  }

  function testFuzz_passesThroughToFlexClient(
    uint256 _proposalSeed,
    uint256 _userSeed,
    uint8 _voteType
  ) public {
    _voteType = _validVoteType(_voteType);
    // We need actors to cross the proposal threshold on expressVote.
    uint128 _actorCount = handler.PROPOSAL_THRESHOLD();
    uint128 _voteSize = 1e24;
    uint128 _reserved = _actorCount * _voteSize; // Tokens for actors.
    _makeActors(_reserved / _actorCount, _actorCount);

    uint256 _proposalId = handler.propose("a preposterous proposal");

    assertFalse(handler.hasPendingVotes(makeAddr("joe"), _proposalId));

    address _actor = handler.expressVote(_proposalSeed, _voteType, _userSeed);
    assertTrue(handler.hasPendingVotes(_actor, _proposalId));

    vm.expectCall(address(flexClient), abi.encodeCall(flexClient.castVote, _proposalId));
    handler.castVote(_proposalSeed);

    // The actor should no longer have pending votes.
    assertFalse(handler.hasPendingVotes(_actor, _proposalId));

    // The vote preference should have been sent to the Governor.
    (uint256 _againstVotes, uint256 _forVotes, uint256 _abstainVotes) =
      governor.proposalVotes(_proposalId);
    if (_voteType == uint8(GCS.VoteType.Against)) assertEq(_voteSize, _againstVotes);
    if (_voteType == uint8(GCS.VoteType.For)) assertEq(_voteSize, _forVotes);
    if (_voteType == uint8(GCS.VoteType.Abstain)) assertEq(_voteSize, _abstainVotes);
  }

  function testFuzz_aggregatesVotes(
    uint256 _proposalSeed,
    uint128 _weightA,
    uint128 _weightB,
    uint8 _voteTypeA,
    uint8 _voteTypeB
  ) public {
    // We need actors to cross the proposal threshold on expressVote.
    uint128 _actorCount = handler.PROPOSAL_THRESHOLD();
    uint128 _voteSize = 1e24;
    uint128 _reserved = _actorCount * _voteSize; // Tokens for actors.
    _makeActors(_voteSize, _actorCount);

    _weightA = uint128(bound(_weightA, 1, handler.MAX_TOKENS() - _reserved - 1));
    _weightB = uint128(bound(_weightB, 1, handler.MAX_TOKENS() - _reserved - _weightA));
    if (_weightA % MAGIC_NUMBER == 0) _weightA -= 1;
    if (_weightB % MAGIC_NUMBER == 0) _weightB -= 1;

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
    uint128 _actorCount = handler.PROPOSAL_THRESHOLD();
    uint128 _voteSize = 1e24;
    uint128 _reserved = _actorCount * _voteSize; // Tokens for actors.
    _makeActors(_reserved / _actorCount, _actorCount);

    _weightA = uint128(bound(_weightA, 1, handler.MAX_TOKENS() - _reserved - 1));
    _weightB = uint128(bound(_weightB, 1, handler.MAX_TOKENS() - _reserved - _weightA));
    if (_weightA % MAGIC_NUMBER == 0) _weightA -= 1;
    if (_weightB % MAGIC_NUMBER == 0) _weightB -= 1;

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
    uint128 _actorCount = handler.PROPOSAL_THRESHOLD();
    uint128 _voteSize = 1e24;
    uint128 _reserved = _actorCount * _voteSize; // Tokens for actors.
    _makeActors(_reserved / _actorCount, _actorCount);

    // The seeds that allow us to force use of the voter we want.
    uint256 _totalActors = _actorCount + 2; // Plus alice and bob.
    uint256 _seedForAlice = _totalActors - 2; // Alice is second to last.

    // User B needs to have less weight than User A.
    uint128 _remainingTokens = handler.MAX_TOKENS() - _reserved;
    _weightA = uint128(bound(_weightA, (_remainingTokens / 2) + 1, _remainingTokens - 1));
    _weightB = uint128(bound(_weightB, 1, _remainingTokens - _weightA));
    if (_weightA % MAGIC_NUMBER == 0) _weightA -= 1;
    if (_weightB % MAGIC_NUMBER == 0) _weightB -= 1;

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

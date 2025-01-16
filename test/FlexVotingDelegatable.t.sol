// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {FlexVotingDelegatable} from "src/FlexVotingDelegatable.sol";
import {MockFlexVotingClient as MFVC} from "test/MockFlexVotingClient.sol";
import {MockFlexVotingDelegatableClient} from "test/MockFlexVotingDelegatableClient.sol";
import {GovernorCountingSimple as GCS} from
  "@openzeppelin/contracts/governance/extensions/GovernorCountingSimple.sol";

import {FlexVotingClient as FVC} from "src/FlexVotingClient.sol";

import {
  FlexVotingClientTest,
  Deployment,
  Constructor,
  _RawBalanceOf,
  _CastVoteReasonString,
  _SelfDelegate,
  _CheckpointRawBalanceOf,
  _CheckpointTotalBalance,
  GetPastRawBalance,
  GetPastTotalBalance,
  Withdraw,
  Deposit,
  ExpressVote,
  CastVote,
  Borrow
} from "test/SharedFlexVoting.t.sol";

abstract contract Delegation is FlexVotingClientTest {
  // We cast the flexClient to the delegatable client to access the delegate
  // function.
  function client() internal view returns (MockFlexVotingDelegatableClient) {
    return MockFlexVotingDelegatableClient(address(flexClient));
  }

  // TODO
  // - delegating adds to a delegate's own votes
  // - test multiple delegatees to the same delegate
  // - test no double voting for delegatee
  // - test that delegator can't vote after delegate votes
  function testFuzz_selfDelegationByDefault(
    address _delegator
  ) public {
    _assumeSafeUser(_delegator);

    // By default, the delegator should delegate to themselves.
    assertEq(client().delegates(_delegator), _delegator);

    // The delegator can still explicitly delegate to himself.
    vm.prank(_delegator);
    client().delegate(_delegator);
    assertEq(client().delegates(_delegator), _delegator);
  }

  function testFuzz_delegateEmitsEvents(
    address _delegator,
    address _delegate,
    uint208 _weight
  ) public {
    _assumeSafeUser(_delegator);
    _assumeSafeUser(_delegate);
    vm.assume(_delegator != _delegate);
    _weight = uint208(bound(_weight, 1, MAX_VOTES));

    _mintGovAndDepositIntoFlexClient(_delegator, _weight);

    vm.expectEmit();
    emit FlexVotingDelegatable.DelegateChanged(_delegator, _delegator, _delegate);
    vm.expectEmit();
    emit FlexVotingDelegatable.DelegateWeightChanged(_delegate, 0, _weight);
    vm.prank(_delegator);
    client().delegate(_delegate);
  }

  function testFuzz_delegationAddsToDelegateWeight(
    address _delegator,
    uint208 _delegatorWeight,
    address _delegate,
    uint208 _delegateWeight,
    uint8 _supportType
  ) public {
    vm.assume(_delegator != _delegate);
    _assumeSafeUser(_delegator);
    _assumeSafeUser(_delegate);
    _delegateWeight = uint208(bound(_delegateWeight, 1, MAX_VOTES - 1));
    _delegatorWeight = uint208(bound(_delegatorWeight, 1, MAX_VOTES - _delegateWeight));
    GCS.VoteType _voteType = _randVoteType(_supportType);

    // Deposit some funds.
    _mintGovAndDepositIntoFlexClient(_delegator, _delegatorWeight);
    _mintGovAndDepositIntoFlexClient(_delegate, _delegateWeight);

    _advanceTimeBy(1); // Make past balances retrievable.
    assertEq(client().getPastRawBalance(_delegate, _now() - 1), _delegateWeight);
    assertEq(client().getPastRawBalance(_delegator, _now() - 1), _delegatorWeight);

    // Delegate.
    vm.expectEmit();
    emit FlexVotingDelegatable.DelegateWeightChanged(
      _delegate,
      _delegateWeight,
      _delegateWeight + _delegatorWeight
    );
    vm.prank(_delegator);
    client().delegate(_delegate);

    uint256 _combined = _delegatorWeight + _delegateWeight;
    _advanceTimeBy(1); // Make past balances retrievable.
    assertEq(client().getPastRawBalance(_delegator, _now() - 1), 0);
    assertEq(client().getPastRawBalance(_delegate, _now() - 1), _combined);

    // Create the proposal.
    uint48 _proposalTimepoint = _now();
    uint256 _proposalId = _createAndSubmitProposal();

    // The delegate expresses a vote.
    vm.prank(_delegate);
    client().expressVote(_proposalId, uint8(_voteType));

    (uint256 _againstVotesExpressed, uint256 _forVotesExpressed, uint256 _abstainVotesExpressed) =
      client().proposalVotes(_proposalId);
    assertEq(_forVotesExpressed, _voteType == GCS.VoteType.For ? _combined : 0);
    assertEq(_againstVotesExpressed, _voteType == GCS.VoteType.Against ? _combined : 0);
    assertEq(_abstainVotesExpressed, _voteType == GCS.VoteType.Abstain ? _combined : 0);
  }

  function testFuzz_delegateCanExpressVoteAfterWithdrawal(
    address _delegator,
    address _delegate,
    uint208 _weight,
    uint8 _supportType
  ) public {
    GCS.VoteType _voteType;
    (_weight, _voteType) = _assumeSafeVoteParams(_delegator, _weight, _supportType);
    _assumeSafeUser(_delegate);
    vm.assume(_delegator != _delegate);

    // Deposit some funds.
    _mintGovAndDepositIntoFlexClient(_delegator, _weight);

    // Delegate.
    vm.prank(_delegator);
    client().delegate(_delegate);
    assertEq(client().delegates(_delegator), _delegate);

    // Create the proposal.
    uint48 _proposalTimepoint = _now();
    uint256 _proposalId = _createAndSubmitProposal();

    // The delegator withdraws their funds without voting.
    vm.prank(_delegator);
    client().withdraw(_weight);
    assertEq(client().deposits(_delegator), 0);

    // The delegate can still vote on the proposal.
    vm.prank(_delegate);
    client().expressVote(_proposalId, uint8(_voteType));

    (uint256 _againstVotesExpressed, uint256 _forVotesExpressed, uint256 _abstainVotesExpressed) =
      client().proposalVotes(_proposalId);
    assertEq(_forVotesExpressed, _voteType == GCS.VoteType.For ? _weight : 0);
    assertEq(_againstVotesExpressed, _voteType == GCS.VoteType.Against ? _weight : 0);
    assertEq(_abstainVotesExpressed, _voteType == GCS.VoteType.Abstain ? _weight : 0);
  }

  function testFuzz_delegateCanExpressVoteWithoutDepositing(
    address _delegator,
    address _delegate,
    uint208 _weight,
    uint8 _supportType
  ) public {
    GCS.VoteType _voteType;
    (_weight, _voteType) = _assumeSafeVoteParams(_delegator, _weight, _supportType);
    _assumeSafeUser(_delegate);
    vm.assume(_delegator != _delegate);

    // Deposit some funds.
    _mintGovAndDepositIntoFlexClient(_delegator, _weight);

    // Delegate.
    vm.prank(_delegator);
    client().delegate(_delegate);
    assertEq(client().delegates(_delegator), _delegate);
    assertEq(client().delegates(_delegate), _delegate);

    // The delegator has not delegated *token* weight to the delegate.
    assertEq(token.delegates(_delegator), address(0));
    assertEq(token.balanceOf(_delegator), 0);
    assertEq(token.balanceOf(_delegate), 0);

    // Create the proposal.
    uint48 _proposalTimepoint = _now();
    uint256 _proposalId = _createAndSubmitProposal();

    // The delegator has no weight to vote with, despite having a deposit balance.
    assertEq(client().deposits(_delegator), _weight);
    assertEq(client().getPastRawBalance(_delegator, _proposalTimepoint), 0);
    vm.expectRevert(FVC.FlexVotingClient__NoVotingWeight.selector);
    vm.prank(_delegator);
    client().expressVote(_proposalId, uint8(_voteType));

    // The delegate *has* weight to vote with, despite having no deposit balance.
    assertEq(client().deposits(_delegate), 0);
    assertEq(client().getPastRawBalance(_delegate, _proposalTimepoint), _weight);
    vm.prank(_delegate);
    client().expressVote(_proposalId, uint8(_voteType));

    (uint256 _againstVotesExpressed, uint256 _forVotesExpressed, uint256 _abstainVotesExpressed) =
      client().proposalVotes(_proposalId);
    assertEq(_forVotesExpressed, _voteType == GCS.VoteType.For ? _weight : 0);
    assertEq(_againstVotesExpressed, _voteType == GCS.VoteType.Against ? _weight : 0);
    assertEq(_abstainVotesExpressed, _voteType == GCS.VoteType.Abstain ? _weight : 0);
  }
}

contract BlockNumberClock_Deployment is Deployment {
  function _timestampClock() internal pure override returns (bool) {
    return false;
  }
  function _deployFlexClient(address _governor) internal override {
    flexClient = MFVC(address(new MockFlexVotingDelegatableClient(_governor)));
  }
}
contract BlockNumberClock_Delegation is Delegation {
  function _timestampClock() internal pure override returns (bool) {
    return false;
  }
  function _deployFlexClient(address _governor) internal override {
    flexClient = MFVC(address(new MockFlexVotingDelegatableClient(_governor)));
  }
}
contract TimestampClock_Deployment is Deployment {
  function _timestampClock() internal pure override returns (bool) {
    return true;
  }
  function _deployFlexClient(address _governor) internal override {
    flexClient = MFVC(address(new MockFlexVotingDelegatableClient(_governor)));
  }
}
contract TimestampClock_Delegation is Delegation {
  function _timestampClock() internal pure override returns (bool) {
    return true;
  }
  function _deployFlexClient(address _governor) internal override {
    flexClient = MFVC(address(new MockFlexVotingDelegatableClient(_governor)));
  }
}

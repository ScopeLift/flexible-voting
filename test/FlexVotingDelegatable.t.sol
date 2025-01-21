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
  struct Delegator {
    address addr;
    uint208 weight;
  }

  // We cast the flexClient to the delegatable client to access the delegate
  // function.
  function client() internal view returns (MockFlexVotingDelegatableClient) {
    return MockFlexVotingDelegatableClient(address(flexClient));
  }

  function testFuzz_selfDelegationByDefault(address _delegator) public {
    _assumeSafeUser(_delegator);

    // By default, the delegator should delegate to themselves.
    assertEq(client().delegates(_delegator), _delegator);

    // The delegator can still explicitly delegate to himself.
    vm.prank(_delegator);
    client().delegate(_delegator);
    assertEq(client().delegates(_delegator), _delegator);
  }

  function testFuzz_delegateEmitsEvents(address _delegator, address _delegate, uint208 _weight)
    public
  {
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
      _delegate, _delegateWeight, _delegateWeight + _delegatorWeight
    );
    vm.prank(_delegator);
    client().delegate(_delegate);

    uint256 _combined = _delegatorWeight + _delegateWeight;
    _advanceTimeBy(1); // Make past balances retrievable.
    assertEq(client().getPastRawBalance(_delegator, _now() - 1), 0);
    assertEq(client().getPastRawBalance(_delegate, _now() - 1), _combined);

    // Create the proposal.
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

  function testFuzz_multipleAddressesDelegate(
    Delegator memory _delegatorA,
    Delegator memory _delegatorB,
    Delegator memory _delegatorC,
    Delegator memory _delegatorD,
    Delegator memory _delegate,
    uint8 _supportType
  ) public {
    Delegator[] memory _users = new Delegator[](5);
    _users[0] = _delegatorA;
    _users[1] = _delegatorB;
    _users[2] = _delegatorC;
    _users[3] = _delegatorD;
    _users[4] = _delegate;

    for (uint256 i = 0; i < _users.length; i++) {
      _assumeSafeUser(_users[i].addr);
    }

    vm.assume(_delegatorA.addr != _delegatorB.addr);
    vm.assume(_delegatorA.addr != _delegatorC.addr);
    vm.assume(_delegatorA.addr != _delegatorD.addr);
    vm.assume(_delegatorA.addr != _delegate.addr);
    vm.assume(_delegatorB.addr != _delegatorC.addr);
    vm.assume(_delegatorB.addr != _delegatorD.addr);
    vm.assume(_delegatorB.addr != _delegate.addr);
    vm.assume(_delegatorC.addr != _delegatorD.addr);
    vm.assume(_delegatorC.addr != _delegate.addr);
    vm.assume(_delegatorD.addr != _delegate.addr);

    vm.label(_delegatorA.addr, "delegatorA");
    vm.label(_delegatorB.addr, "delegatorB");
    vm.label(_delegatorC.addr, "delegatorC");
    vm.label(_delegatorD.addr, "delegatorD");
    vm.label(_delegate.addr, "delegate");

    uint256 _remaining = uint256(MAX_VOTES) - 4;
    _delegatorA.weight = uint208(bound(_delegatorA.weight, 1, _remaining));
    _remaining -= _delegatorA.weight - 1;
    _delegatorB.weight = uint208(bound(_delegatorB.weight, 1, _remaining));
    _remaining -= _delegatorB.weight - 1;
    _delegatorC.weight = uint208(bound(_delegatorC.weight, 1, _remaining));
    _remaining -= _delegatorC.weight - 1;
    _delegatorD.weight = uint208(bound(_delegatorD.weight, 1, _remaining));
    _remaining -= _delegatorD.weight - 1;
    _delegate.weight = uint208(bound(_delegate.weight, 1, _remaining));

    GCS.VoteType _voteType = _randVoteType(_supportType);

    // Deposit some funds.
    for (uint256 i = 0; i < _users.length; i++) {
      _mintGovAndDepositIntoFlexClient(_users[i].addr, _users[i].weight);
    }

    _advanceTimeBy(1);

    // Delegate.
    for (uint256 i = 0; i < _users.length - 1; i++) {
      vm.prank(_users[i].addr);
      client().delegate(_delegate.addr);
    }

    _advanceTimeBy(1);

    // Create the proposal.
    uint256 _proposalId = _createAndSubmitProposal();

    // The delegate expresses a vote.
    vm.prank(_delegate.addr);
    client().expressVote(_proposalId, uint8(_voteType));

    uint256 _combined;
    for (uint256 i = 0; i < _users.length; i++) {
      _combined += _users[i].weight;
    }

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

  function testFuzz_RevertIf_delegateDoubleVotes(
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
    uint256 _proposalId = _createAndSubmitProposal();

    // The delegate expresses a voting preference.
    vm.prank(_delegate);
    client().expressVote(_proposalId, uint8(_voteType));

    // Even if you're voting for multiple people, you can't double vote.
    vm.expectRevert(FVC.FlexVotingClient__AlreadyVoted.selector);
    vm.prank(_delegate);
    client().expressVote(_proposalId, uint8(_voteType));
  }

  function testFuzz_delegatorCanChangeDelegates(
    address _delegator,
    address _delegateA,
    address _delegateB,
    uint208 _weight,
    uint8 _supportType
  ) public {
    _assumeSafeUser(_delegator);
    _assumeSafeUser(_delegateA);
    _assumeSafeUser(_delegateB);

    vm.assume(_delegator != _delegateA);
    vm.assume(_delegator != _delegateB);
    vm.assume(_delegateA != _delegateB);

    vm.label(_delegator, "delegator");
    vm.label(_delegateA, "delegateA");
    vm.label(_delegateB, "delegateB");

    GCS.VoteType _voteType = _randVoteType(_supportType);
    _weight = uint208(bound(_weight, 1, MAX_VOTES));
    _mintGovAndDepositIntoFlexClient(_delegator, _weight);

    _advanceTimeBy(1);

    // Delegate to first account.
    vm.prank(_delegator);
    client().delegate(_delegateA);

    _advanceTimeBy(1);

    // Create the first proposal.
    uint256 _proposalA = _createAndSubmitProposal();

    _advanceTimeBy(1);

    // Change delegate to second account.
    vm.prank(_delegator);
    client().delegate(_delegateB);

    // Create the second proposal.
    uint256 _proposalB = _createAndSubmitProposal("anotherReceiverFunction()");

    // The delegator and delegateB should not be able to vote on proposalA.
    vm.expectRevert(FVC.FlexVotingClient__NoVotingWeight.selector);
    vm.prank(_delegator);
    client().expressVote(_proposalA, uint8(_voteType));
    vm.expectRevert(FVC.FlexVotingClient__NoVotingWeight.selector);
    vm.prank(_delegateB);
    client().expressVote(_proposalA, uint8(_voteType));

    // The delegator and delegateA should not be able to vote on proposalB.
    vm.expectRevert(FVC.FlexVotingClient__NoVotingWeight.selector);
    vm.prank(_delegator);
    client().expressVote(_proposalB, uint8(_voteType));
    vm.expectRevert(FVC.FlexVotingClient__NoVotingWeight.selector);
    vm.prank(_delegateA);
    client().expressVote(_proposalB, uint8(_voteType));

    // Delegate A should be able to express a vote on the first proposal.
    vm.prank(_delegateA);
    client().expressVote(_proposalA, uint8(_voteType));

    // Delegate B should be able to express a vote on the second proposal.
    vm.prank(_delegateB);
    client().expressVote(_proposalB, uint8(_voteType));

    (uint256 _againstA, uint256 _forA, uint256 _abstainA) =
      client().proposalVotes(_proposalA);
    assertEq(_forA,     _voteType == GCS.VoteType.For ? _weight : 0);
    assertEq(_againstA, _voteType == GCS.VoteType.Against ? _weight : 0);
    assertEq(_abstainA, _voteType == GCS.VoteType.Abstain ? _weight : 0);

    (uint256 _againstB, uint256 _forB, uint256 _abstainB) =
      client().proposalVotes(_proposalB);
    assertEq(_forB, _voteType == GCS.VoteType.For ? _weight : 0);
    assertEq(_againstB, _voteType == GCS.VoteType.Against ? _weight : 0);
    assertEq(_abstainB, _voteType == GCS.VoteType.Abstain ? _weight : 0);
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

contract BlockNumber_Constructor is Constructor {
  function _timestampClock() internal pure override returns (bool) {
    return false;
  }

  function _deployFlexClient(address _governor) internal override {
    flexClient = MFVC(address(new MockFlexVotingDelegatableClient(_governor)));
  }
}

contract BlockNumber__RawBalanceOf is _RawBalanceOf {
  function _timestampClock() internal pure override returns (bool) {
    return false;
  }

  function _deployFlexClient(address _governor) internal override {
    flexClient = MFVC(address(new MockFlexVotingDelegatableClient(_governor)));
  }
}

contract BlockNumber__CastVoteReasonString is _CastVoteReasonString {
  function _timestampClock() internal pure override returns (bool) {
    return false;
  }

  function _deployFlexClient(address _governor) internal override {
    flexClient = MFVC(address(new MockFlexVotingDelegatableClient(_governor)));
  }
}

contract BlockNumber__SelfDelegate is _SelfDelegate {
  function _timestampClock() internal pure override returns (bool) {
    return false;
  }

  function _deployFlexClient(address _governor) internal override {
    flexClient = MFVC(address(new MockFlexVotingDelegatableClient(_governor)));
  }
}

contract BlockNumber__CheckpointRawBalanceOf is _CheckpointRawBalanceOf {
  function _timestampClock() internal pure override returns (bool) {
    return false;
  }

  function _deployFlexClient(address _governor) internal override {
    flexClient = MFVC(address(new MockFlexVotingDelegatableClient(_governor)));
  }
}

contract BlockNumber__CheckpointTotalBalance is _CheckpointTotalBalance {
  function _timestampClock() internal pure override returns (bool) {
    return false;
  }

  function _deployFlexClient(address _governor) internal override {
    flexClient = MFVC(address(new MockFlexVotingDelegatableClient(_governor)));
  }
}

contract BlockNumber_GetPastRawBalance is GetPastRawBalance {
  function _timestampClock() internal pure override returns (bool) {
    return false;
  }

  function _deployFlexClient(address _governor) internal override {
    flexClient = MFVC(address(new MockFlexVotingDelegatableClient(_governor)));
  }
}

contract BlockNumber_GetPastTotalBalance is GetPastTotalBalance {
  function _timestampClock() internal pure override returns (bool) {
    return false;
  }

  function _deployFlexClient(address _governor) internal override {
    flexClient = MFVC(address(new MockFlexVotingDelegatableClient(_governor)));
  }
}

contract BlockNumber_Withdraw is Withdraw {
  function _timestampClock() internal pure override returns (bool) {
    return false;
  }

  function _deployFlexClient(address _governor) internal override {
    flexClient = MFVC(address(new MockFlexVotingDelegatableClient(_governor)));
  }
}

contract BlockNumber_Deposit is Deposit {
  function _timestampClock() internal pure override returns (bool) {
    return false;
  }

  function _deployFlexClient(address _governor) internal override {
    flexClient = MFVC(address(new MockFlexVotingDelegatableClient(_governor)));
  }
}

contract BlockNumber_ExpressVote is ExpressVote {
  function _timestampClock() internal pure override returns (bool) {
    return false;
  }

  function _deployFlexClient(address _governor) internal override {
    flexClient = MFVC(address(new MockFlexVotingDelegatableClient(_governor)));
  }
}

contract BlockNumber_CastVote is CastVote {
  function _timestampClock() internal pure override returns (bool) {
    return false;
  }

  function _deployFlexClient(address _governor) internal override {
    flexClient = MFVC(address(new MockFlexVotingDelegatableClient(_governor)));
  }
}

contract BlockNumber_Borrow is Borrow {
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

contract TimestampClockClock_Deployment is Deployment {
  function _timestampClock() internal pure override returns (bool) {
    return true;
  }

  function _deployFlexClient(address _governor) internal override {
    flexClient = MFVC(address(new MockFlexVotingDelegatableClient(_governor)));
  }
}

contract TimestampClock_Constructor is Constructor {
  function _timestampClock() internal pure override returns (bool) {
    return true;
  }

  function _deployFlexClient(address _governor) internal override {
    flexClient = MFVC(address(new MockFlexVotingDelegatableClient(_governor)));
  }
}

contract TimestampClock__RawBalanceOf is _RawBalanceOf {
  function _timestampClock() internal pure override returns (bool) {
    return true;
  }

  function _deployFlexClient(address _governor) internal override {
    flexClient = MFVC(address(new MockFlexVotingDelegatableClient(_governor)));
  }
}

contract TimestampClock__CastVoteReasonString is _CastVoteReasonString {
  function _timestampClock() internal pure override returns (bool) {
    return true;
  }

  function _deployFlexClient(address _governor) internal override {
    flexClient = MFVC(address(new MockFlexVotingDelegatableClient(_governor)));
  }
}

contract TimestampClock__SelfDelegate is _SelfDelegate {
  function _timestampClock() internal pure override returns (bool) {
    return true;
  }

  function _deployFlexClient(address _governor) internal override {
    flexClient = MFVC(address(new MockFlexVotingDelegatableClient(_governor)));
  }
}

contract TimestampClock__CheckpointRawBalanceOf is _CheckpointRawBalanceOf {
  function _timestampClock() internal pure override returns (bool) {
    return true;
  }

  function _deployFlexClient(address _governor) internal override {
    flexClient = MFVC(address(new MockFlexVotingDelegatableClient(_governor)));
  }
}

contract TimestampClock__CheckpointTotalBalance is _CheckpointTotalBalance {
  function _timestampClock() internal pure override returns (bool) {
    return true;
  }

  function _deployFlexClient(address _governor) internal override {
    flexClient = MFVC(address(new MockFlexVotingDelegatableClient(_governor)));
  }
}

contract TimestampClock_GetPastRawBalance is GetPastRawBalance {
  function _timestampClock() internal pure override returns (bool) {
    return true;
  }

  function _deployFlexClient(address _governor) internal override {
    flexClient = MFVC(address(new MockFlexVotingDelegatableClient(_governor)));
  }
}

contract TimestampClock_GetPastTotalBalance is GetPastTotalBalance {
  function _timestampClock() internal pure override returns (bool) {
    return true;
  }

  function _deployFlexClient(address _governor) internal override {
    flexClient = MFVC(address(new MockFlexVotingDelegatableClient(_governor)));
  }
}

contract TimestampClock_Withdraw is Withdraw {
  function _timestampClock() internal pure override returns (bool) {
    return true;
  }

  function _deployFlexClient(address _governor) internal override {
    flexClient = MFVC(address(new MockFlexVotingDelegatableClient(_governor)));
  }
}

contract TimestampClock_Deposit is Deposit {
  function _timestampClock() internal pure override returns (bool) {
    return true;
  }

  function _deployFlexClient(address _governor) internal override {
    flexClient = MFVC(address(new MockFlexVotingDelegatableClient(_governor)));
  }
}

contract TimestampClock_ExpressVote is ExpressVote {
  function _timestampClock() internal pure override returns (bool) {
    return true;
  }

  function _deployFlexClient(address _governor) internal override {
    flexClient = MFVC(address(new MockFlexVotingDelegatableClient(_governor)));
  }
}

contract TimestampClock_CastVote is CastVote {
  function _timestampClock() internal pure override returns (bool) {
    return true;
  }

  function _deployFlexClient(address _governor) internal override {
    flexClient = MFVC(address(new MockFlexVotingDelegatableClient(_governor)));
  }
}

contract TimestampClock_Borrow is Borrow {
  function _timestampClock() internal pure override returns (bool) {
    return true;
  }

  function _deployFlexClient(address _governor) internal override {
    flexClient = MFVC(address(new MockFlexVotingDelegatableClient(_governor)));
  }
}

contract TimestampClockClock_Delegation is Delegation {
  function _timestampClock() internal pure override returns (bool) {
    return true;
  }

  function _deployFlexClient(address _governor) internal override {
    flexClient = MFVC(address(new MockFlexVotingDelegatableClient(_governor)));
  }
}

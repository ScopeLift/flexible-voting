// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {GovernorCountingSimple as GCS} from
  "@openzeppelin/contracts/governance/extensions/GovernorCountingSimple.sol";

import {IFractionalGovernor} from "src/interfaces/IFractionalGovernor.sol";
import {FlexVotingDelegable} from "src/FlexVotingDelegable.sol";
import {MockFlexVotingClient as MFVC} from "test/mocks/MockFlexVotingClient.sol";
import {MockFlexVotingDelegableClient} from "test/mocks/MockFlexVotingDelegableClient.sol";
import {GovToken} from "test/mocks/GovToken.sol";
import {FractionalGovernor} from "test/mocks/FractionalGovernor.sol";

import {FlexVotingClient as FVC} from "src/FlexVotingClient.sol";
import {IVotingToken} from "src/interfaces/IVotingToken.sol";

import {
  FlexVotingClientTest,
  Deployment,
  Constructor,
  _ApplyDeltaToCheckpoint,
  _RawBalanceOf,
  _CastVoteReasonString,
  _SelfDelegate,
  _CheckpointVoteWeightOf,
  _CheckpointTotalVoteWeight,
  GetPastVoteWeight,
  GetPastTotalVoteWeight,
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
  function client() internal view returns (MockFlexVotingDelegableClient) {
    return MockFlexVotingDelegableClient(address(flexClient));
  }

  function testFuzz_selfDelegationByDefault(uint256 _seed, address _delegator) public {
    _assumeSafeUser(_delegator);
    IVotingToken _token = IVotingToken(address(_randToken(_seed)));

    // By default, the delegator should delegate to themselves.
    assertEq(client().delegates(_token, _delegator), _delegator);

    // The delegator can still explicitly delegate to himself.
    vm.prank(_delegator);
    client().delegate(_token, _delegator);
    assertEq(client().delegates(_token, _delegator), _delegator);
  }

  function testFuzz_delegateEmitsEvents(
    uint256 _seed,
    address _delegator,
    address _delegate,
    uint208 _weight
  ) public {
    _assumeSafeUser(_delegator);
    _assumeSafeUser(_delegate);
    vm.assume(_delegator != _delegate);
    _weight = uint208(bound(_weight, 1, MAX_VOTES));
    IVotingToken _token = IVotingToken(address(_randToken(_seed)));

    _mintAndDepositIntoFlexClient(_token, _delegator, _weight);

    vm.expectEmit();
    emit FlexVotingDelegable.DelegateChanged(address(_token), _delegator, _delegator, _delegate);
    vm.expectEmit();
    emit FlexVotingDelegable.DelegateWeightChanged(address(_token), _delegate, 0, _weight);
    vm.prank(_delegator);
    client().delegate(_token, _delegate);
  }

  function testFuzz_delegationAddsToDelegateWeight(
    uint256 _seed,
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

    FractionalGovernor _gov = _randGov(_seed);
    IFractionalGovernor _iGov = IFractionalGovernor(address(_gov));
    IVotingToken _token = IVotingToken(address(_gov.token()));

    // Deposit some funds.
    _mintAndDepositIntoFlexClient(_token, _delegator, _delegatorWeight);
    _mintAndDepositIntoFlexClient(_token, _delegate, _delegateWeight);

    _advanceTimeBy(1); // Make past balances retrievable.
    assertEq(client().getPastVoteWeight(_token, _delegate, _now() - 1), _delegateWeight);
    assertEq(client().getPastVoteWeight(_token, _delegator, _now() - 1), _delegatorWeight);

    // Delegate.
    vm.expectEmit();
    emit FlexVotingDelegable.DelegateWeightChanged(
      address(_token), _delegate, _delegateWeight, _delegateWeight + _delegatorWeight
    );
    vm.prank(_delegator);
    client().delegate(_token, _delegate);

    uint256 _combined = _delegatorWeight + _delegateWeight;
    _advanceTimeBy(1); // Make past balances retrievable.
    assertEq(client().getPastVoteWeight(_token, _delegator, _now() - 1), 0);
    assertEq(client().getPastVoteWeight(_token, _delegate, _now() - 1), _combined);

    // Create the proposal.
    uint256 _proposalId = _createAndSubmitProposal(_gov);

    // The delegate expresses a vote.
    vm.prank(_delegate);
    client().expressVote(_iGov, _proposalId, uint8(_voteType));

    (uint256 _againstVotesExpressed, uint256 _forVotesExpressed, uint256 _abstainVotesExpressed) =
      client().proposalVotes(_iGov, _proposalId);
    assertEq(_forVotesExpressed, _voteType == GCS.VoteType.For ? _combined : 0);
    assertEq(_againstVotesExpressed, _voteType == GCS.VoteType.Against ? _combined : 0);
    assertEq(_abstainVotesExpressed, _voteType == GCS.VoteType.Abstain ? _combined : 0);
  }

  function testFuzz_multipleAddressesDelegate(
    uint256 _seed,
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

    FractionalGovernor _gov = _randGov(_seed);
    IFractionalGovernor _iGov = IFractionalGovernor(address(_gov));
    IVotingToken _token = IVotingToken(address(_gov.token()));

    // Deposit some funds.
    for (uint256 i = 0; i < _users.length; i++) {
      _mintAndDepositIntoFlexClient(_token, _users[i].addr, _users[i].weight);
    }

    _advanceTimeBy(1);

    // Delegate.
    for (uint256 i = 0; i < _users.length - 1; i++) {
      vm.prank(_users[i].addr);
      client().delegate(_token, _delegate.addr);
    }

    _advanceTimeBy(1);

    // Create the proposal.
    uint256 _proposalId = _createAndSubmitProposal(_gov);

    // The delegate expresses a vote.
    vm.prank(_delegate.addr);
    client().expressVote(_iGov, _proposalId, uint8(_voteType));

    uint256 _combined;
    for (uint256 i = 0; i < _users.length; i++) {
      _combined += _users[i].weight;
    }

    (uint256 _againstVotesExpressed, uint256 _forVotesExpressed, uint256 _abstainVotesExpressed) =
      client().proposalVotes(_iGov, _proposalId);
    assertEq(_forVotesExpressed, _voteType == GCS.VoteType.For ? _combined : 0);
    assertEq(_againstVotesExpressed, _voteType == GCS.VoteType.Against ? _combined : 0);
    assertEq(_abstainVotesExpressed, _voteType == GCS.VoteType.Abstain ? _combined : 0);
  }

  function testFuzz_delegateCanExpressVoteAfterWithdrawal(
    uint256 _seed,
    address _delegator,
    address _delegate,
    uint208 _weight,
    uint8 _supportType
  ) public {
    GCS.VoteType _voteType;
    (_weight, _voteType) = _assumeSafeVoteParams(_delegator, _weight, _supportType);
    _assumeSafeUser(_delegate);
    vm.assume(_delegator != _delegate);

    FractionalGovernor _gov = _randGov(_seed);
    IFractionalGovernor _iGov = IFractionalGovernor(address(_gov));
    IVotingToken _token = IVotingToken(address(_gov.token()));

    // Deposit some funds.
    _mintAndDepositIntoFlexClient(_token, _delegator, _weight);

    // Delegate.
    vm.prank(_delegator);
    client().delegate(_token, _delegate);
    assertEq(client().delegates(_token, _delegator), _delegate);

    // Create the proposal.
    uint256 _proposalId = _createAndSubmitProposal(_gov);

    // The delegator withdraws their funds without voting.
    vm.prank(_delegator);
    client().withdraw(_token, _weight);
    assertEq(client().deposits(_token, _delegator), 0);

    // The delegate can still vote on the proposal.
    vm.prank(_delegate);
    client().expressVote(_iGov, _proposalId, uint8(_voteType));

    (uint256 _againstVotesExpressed, uint256 _forVotesExpressed, uint256 _abstainVotesExpressed) =
      client().proposalVotes(_iGov, _proposalId);
    assertEq(_forVotesExpressed, _voteType == GCS.VoteType.For ? _weight : 0);
    assertEq(_againstVotesExpressed, _voteType == GCS.VoteType.Against ? _weight : 0);
    assertEq(_abstainVotesExpressed, _voteType == GCS.VoteType.Abstain ? _weight : 0);
  }

  function testFuzz_RevertIf_delegateDoubleVotes(
    uint256 _seed,
    address _delegator,
    address _delegate,
    uint208 _weight,
    uint8 _supportType
  ) public {
    GCS.VoteType _voteType;
    (_weight, _voteType) = _assumeSafeVoteParams(_delegator, _weight, _supportType);
    _assumeSafeUser(_delegate);
    vm.assume(_delegator != _delegate);

    FractionalGovernor _gov = _randGov(_seed);
    IFractionalGovernor _iGov = IFractionalGovernor(address(_gov));
    IVotingToken _token = IVotingToken(address(_gov.token()));

    // Deposit some funds.
    _mintAndDepositIntoFlexClient(_token, _delegator, _weight);

    // Delegate.
    vm.prank(_delegator);
    client().delegate(_token, _delegate);
    assertEq(client().delegates(_token, _delegator), _delegate);

    // Create the proposal.
    uint256 _proposalId = _createAndSubmitProposal(_gov);

    // The delegate expresses a voting preference.
    vm.prank(_delegate);
    client().expressVote(_iGov, _proposalId, uint8(_voteType));

    // Even if you're voting for multiple people, you can't double vote.
    vm.expectRevert(FVC.FlexVotingClient__AlreadyVoted.selector);
    vm.prank(_delegate);
    client().expressVote(_iGov, _proposalId, uint8(_voteType));
  }

  function testFuzz_delegatorCanChangeDelegates(
    uint256 _seed,
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

    FractionalGovernor _gov = _randGov(_seed);
    IFractionalGovernor _iGov = IFractionalGovernor(address(_gov));
    IVotingToken _token = IVotingToken(address(_gov.token()));

    GCS.VoteType _voteType = _randVoteType(_supportType);
    _weight = uint208(bound(_weight, 1, MAX_VOTES));
    _mintAndDepositIntoFlexClient(_token, _delegator, _weight);

    _advanceTimeBy(1);

    // Delegate to first account.
    vm.prank(_delegator);
    client().delegate(_token, _delegateA);

    _advanceTimeBy(1);

    // Create the first proposal.
    uint256 _proposalA = _createAndSubmitProposal(_gov);

    _advanceTimeBy(1);

    // Change delegate to second account.
    vm.prank(_delegator);
    client().delegate(_token, _delegateB);

    // Create the second proposal.
    uint256 _proposalB = _createAndSubmitProposal(_gov, "anotherReceiverFunction()");

    // The delegator and delegateB should not be able to vote on proposalA.
    vm.expectRevert(FVC.FlexVotingClient__NoVotingWeight.selector);
    vm.prank(_delegator);
    client().expressVote(_iGov, _proposalA, uint8(_voteType));
    vm.expectRevert(FVC.FlexVotingClient__NoVotingWeight.selector);
    vm.prank(_delegateB);
    client().expressVote(_iGov, _proposalA, uint8(_voteType));

    // The delegator and delegateA should not be able to vote on proposalB.
    vm.expectRevert(FVC.FlexVotingClient__NoVotingWeight.selector);
    vm.prank(_delegator);
    client().expressVote(_iGov, _proposalB, uint8(_voteType));
    vm.expectRevert(FVC.FlexVotingClient__NoVotingWeight.selector);
    vm.prank(_delegateA);
    client().expressVote(_iGov, _proposalB, uint8(_voteType));

    // Delegate A should be able to express a vote on the first proposal.
    vm.prank(_delegateA);
    client().expressVote(_iGov, _proposalA, uint8(_voteType));

    // Delegate B should be able to express a vote on the second proposal.
    vm.prank(_delegateB);
    client().expressVote(_iGov, _proposalB, uint8(_voteType));

    (uint256 _againstA, uint256 _forA, uint256 _abstainA) =
      client().proposalVotes(_iGov, _proposalA);
    assertEq(_forA, _voteType == GCS.VoteType.For ? _weight : 0);
    assertEq(_againstA, _voteType == GCS.VoteType.Against ? _weight : 0);
    assertEq(_abstainA, _voteType == GCS.VoteType.Abstain ? _weight : 0);

    (uint256 _againstB, uint256 _forB, uint256 _abstainB) =
      client().proposalVotes(_iGov, _proposalB);
    assertEq(_forB, _voteType == GCS.VoteType.For ? _weight : 0);
    assertEq(_againstB, _voteType == GCS.VoteType.Against ? _weight : 0);
    assertEq(_abstainB, _voteType == GCS.VoteType.Abstain ? _weight : 0);
  }

  function testFuzz_delegateCanExpressVoteWithoutDepositing(
    uint256 _seed,
    address _delegator,
    address _delegate,
    uint208 _weight,
    uint8 _supportType
  ) public {
    GCS.VoteType _voteType;
    (_weight, _voteType) = _assumeSafeVoteParams(_delegator, _weight, _supportType);
    _assumeSafeUser(_delegate);
    vm.assume(_delegator != _delegate);

    FractionalGovernor _gov = _randGov(_seed);
    IFractionalGovernor _iGov = IFractionalGovernor(address(_gov));
    IVotingToken _token = IVotingToken(address(_gov.token()));
    GovToken _tokenGov = GovToken(address(_token));

    // Deposit some funds.
    _mintAndDepositIntoFlexClient(_token, _delegator, _weight);

    // Delegate.
    vm.prank(_delegator);
    client().delegate(_token, _delegate);
    assertEq(client().delegates(_token, _delegator), _delegate);
    assertEq(client().delegates(_token, _delegate), _delegate);

    // The delegator has not delegated *token* weight to the delegate.
    assertEq(_tokenGov.delegates(_delegator), address(0));
    assertEq(_tokenGov.balanceOf(_delegator), 0);
    assertEq(_tokenGov.balanceOf(_delegate), 0);

    // Create the proposal.
    uint48 _proposalTimepoint = _now();
    uint256 _proposalId = _createAndSubmitProposal(_gov);

    // The delegator has no weight to vote with, despite having a deposit balance.
    assertEq(client().deposits(_token, _delegator), _weight);
    assertEq(client().getPastVoteWeight(_token, _delegator, _proposalTimepoint), 0);
    vm.expectRevert(FVC.FlexVotingClient__NoVotingWeight.selector);
    vm.prank(_delegator);
    client().expressVote(_iGov, _proposalId, uint8(_voteType));

    // The delegate *has* weight to vote with, despite having no deposit balance.
    assertEq(client().deposits(_token, _delegate), 0);
    assertEq(client().getPastVoteWeight(_token, _delegate, _proposalTimepoint), _weight);
    vm.prank(_delegate);
    client().expressVote(_iGov, _proposalId, uint8(_voteType));

    (uint256 _againstVotesExpressed, uint256 _forVotesExpressed, uint256 _abstainVotesExpressed) =
      client().proposalVotes(_iGov, _proposalId);
    assertEq(_forVotesExpressed, _voteType == GCS.VoteType.For ? _weight : 0);
    assertEq(_againstVotesExpressed, _voteType == GCS.VoteType.Against ? _weight : 0);
    assertEq(_abstainVotesExpressed, _voteType == GCS.VoteType.Abstain ? _weight : 0);
  }

  struct DelegationInfo {
    address delegate;
    uint208 weight;
    uint8 supportType;
    uint256 proposalId;
    IVotingToken token;
    FractionalGovernor gov;
    IFractionalGovernor iGov;
  }

  function testFuzz_CanDelegateToDifferentAddressesPerToken(
    uint256 _seed,
    address _delegator,
    DelegationInfo memory _infoA,
    DelegationInfo memory _infoB
  ) public {
    _assumeSafeUser(_delegator);
    _assumeSafeUser(_infoA.delegate);
    _assumeSafeUser(_infoB.delegate);
    vm.assume(_delegator != _infoA.delegate);
    vm.assume(_delegator != _infoB.delegate);

    _infoA.weight = uint208(bound(_infoA.weight, 1, MAX_VOTES));
    _infoB.weight = uint208(bound(_infoB.weight, 1, MAX_VOTES));

    _infoA.token = IVotingToken(address(_randToken(_seed)));
    _infoB.token = IVotingToken(address(_randTokenAlt(_seed)));

    _infoA.gov = _randGov(_seed);
    _infoB.gov = _randGovAlt(_seed);
    _infoA.iGov = IFractionalGovernor(address(_infoA.gov));
    _infoB.iGov = IFractionalGovernor(address(_infoB.gov));
    _infoA.token = IVotingToken(address(_infoA.gov.token()));
    _infoB.token = IVotingToken(address(_infoB.gov.token()));

    // Deposit some funds.
    _mintAndDepositIntoFlexClient(_infoA.token, _delegator, _infoA.weight);
    _mintAndDepositIntoFlexClient(_infoB.token, _delegator, _infoB.weight);

    assertEq(client().delegates(_infoA.token, _delegator), _delegator);
    assertEq(client().delegates(_infoA.token, _delegator), _delegator);

    // Delegate.
    vm.prank(_delegator);
    client().delegate(_infoA.token, _infoA.delegate);

    assertEq(client().delegates(_infoA.token, _delegator), _infoA.delegate);
    assertEq(client().delegates(_infoB.token, _delegator), _delegator);

    vm.prank(_delegator);
    client().delegate(_infoB.token, _infoB.delegate);

    assertEq(client().delegates(_infoA.token, _delegator), _infoA.delegate);
    assertEq(client().delegates(_infoB.token, _delegator), _infoB.delegate);

    _infoA.proposalId = _createAndSubmitProposal(_infoA.gov);
    _infoB.proposalId = _createAndSubmitProposal(_infoB.gov);

    // Delegates vote.
    vm.prank(_infoA.delegate);
    client().expressVote(_infoA.iGov, _infoA.proposalId, uint8(GCS.VoteType.For));
    vm.prank(_infoB.delegate);
    client().expressVote(_infoB.iGov, _infoB.proposalId, uint8(GCS.VoteType.Against));

    // Internal accounting is correct.
    (, uint256 _forVotes,) = client().proposalVotes(_infoA.iGov, _infoA.proposalId);
    assertEq(_forVotes, _infoA.weight);
    (uint256 _againstVotes,,) = client().proposalVotes(_infoB.iGov, _infoB.proposalId);
    assertEq(_againstVotes, _infoB.weight);
  }
}

contract BlockNumberClock_Deployment is Deployment {
  function _timestampClock() internal pure override returns (bool) {
    return false;
  }

  function _deployFlexClient(address _governor) internal override {
    flexClient = MFVC(address(new MockFlexVotingDelegableClient(_governor)));
  }
}

contract BlockNumber_Constructor is Constructor {
  function _timestampClock() internal pure override returns (bool) {
    return false;
  }

  function _deployFlexClient(address _governor) internal override {
    flexClient = MFVC(address(new MockFlexVotingDelegableClient(_governor)));
  }
}

contract BlockNumber__ApplyDeltaToCheckpoint is _ApplyDeltaToCheckpoint {
  function _timestampClock() internal pure override returns (bool) {
    return false;
  }

  function _deployFlexClient(address _governor) internal override {
    flexClient = MFVC(address(new MockFlexVotingDelegableClient(_governor)));
  }
}

contract BlockNumber__RawBalanceOf is _RawBalanceOf {
  function _timestampClock() internal pure override returns (bool) {
    return false;
  }

  function _deployFlexClient(address _governor) internal override {
    flexClient = MFVC(address(new MockFlexVotingDelegableClient(_governor)));
  }
}

contract BlockNumber__CastVoteReasonString is _CastVoteReasonString {
  function _timestampClock() internal pure override returns (bool) {
    return false;
  }

  function _deployFlexClient(address _governor) internal override {
    flexClient = MFVC(address(new MockFlexVotingDelegableClient(_governor)));
  }
}

contract BlockNumber__SelfDelegate is _SelfDelegate {
  function _timestampClock() internal pure override returns (bool) {
    return false;
  }

  function _deployFlexClient(address _governor) internal override {
    flexClient = MFVC(address(new MockFlexVotingDelegableClient(_governor)));
  }
}

contract BlockNumber__CheckpointVoteWeightOf is _CheckpointVoteWeightOf {
  function _timestampClock() internal pure override returns (bool) {
    return false;
  }

  function _deployFlexClient(address _governor) internal override {
    flexClient = MFVC(address(new MockFlexVotingDelegableClient(_governor)));
  }
}

contract BlockNumber__CheckpointTotalVoteWeight is _CheckpointTotalVoteWeight {
  function _timestampClock() internal pure override returns (bool) {
    return false;
  }

  function _deployFlexClient(address _governor) internal override {
    flexClient = MFVC(address(new MockFlexVotingDelegableClient(_governor)));
  }
}

contract BlockNumber_GetPastVoteWeight is GetPastVoteWeight {
  function _timestampClock() internal pure override returns (bool) {
    return false;
  }

  function _deployFlexClient(address _governor) internal override {
    flexClient = MFVC(address(new MockFlexVotingDelegableClient(_governor)));
  }
}

contract BlockNumber_GetPastTotalVoteWeight is GetPastTotalVoteWeight {
  function _timestampClock() internal pure override returns (bool) {
    return false;
  }

  function _deployFlexClient(address _governor) internal override {
    flexClient = MFVC(address(new MockFlexVotingDelegableClient(_governor)));
  }
}

contract BlockNumber_Withdraw is Withdraw {
  function _timestampClock() internal pure override returns (bool) {
    return false;
  }

  function _deployFlexClient(address _governor) internal override {
    flexClient = MFVC(address(new MockFlexVotingDelegableClient(_governor)));
  }
}

contract BlockNumber_Deposit is Deposit {
  function _timestampClock() internal pure override returns (bool) {
    return false;
  }

  function _deployFlexClient(address _governor) internal override {
    flexClient = MFVC(address(new MockFlexVotingDelegableClient(_governor)));
  }
}

contract BlockNumber_ExpressVote is ExpressVote {
  function _timestampClock() internal pure override returns (bool) {
    return false;
  }

  function _deployFlexClient(address _governor) internal override {
    flexClient = MFVC(address(new MockFlexVotingDelegableClient(_governor)));
  }
}

contract BlockNumber_CastVote is CastVote {
  function _timestampClock() internal pure override returns (bool) {
    return false;
  }

  function _deployFlexClient(address _governor) internal override {
    flexClient = MFVC(address(new MockFlexVotingDelegableClient(_governor)));
  }
}

contract BlockNumber_Borrow is Borrow {
  function _timestampClock() internal pure override returns (bool) {
    return false;
  }

  function _deployFlexClient(address _governor) internal override {
    flexClient = MFVC(address(new MockFlexVotingDelegableClient(_governor)));
  }
}

contract BlockNumberClock_Delegation is Delegation {
  function _timestampClock() internal pure override returns (bool) {
    return false;
  }

  function _deployFlexClient(address _governor) internal override {
    flexClient = MFVC(address(new MockFlexVotingDelegableClient(_governor)));
  }
}

contract TimestampClockClock_Deployment is Deployment {
  function _timestampClock() internal pure override returns (bool) {
    return true;
  }

  function _deployFlexClient(address _governor) internal override {
    flexClient = MFVC(address(new MockFlexVotingDelegableClient(_governor)));
  }
}

contract TimestampClock_Constructor is Constructor {
  function _timestampClock() internal pure override returns (bool) {
    return true;
  }

  function _deployFlexClient(address _governor) internal override {
    flexClient = MFVC(address(new MockFlexVotingDelegableClient(_governor)));
  }
}

contract TimestampClock__ApplyDeltaToCheckpoint is _ApplyDeltaToCheckpoint {
  function _timestampClock() internal pure override returns (bool) {
    return true;
  }

  function _deployFlexClient(address _governor) internal override {
    flexClient = MFVC(address(new MockFlexVotingDelegableClient(_governor)));
  }
}

contract TimestampClock__RawBalanceOf is _RawBalanceOf {
  function _timestampClock() internal pure override returns (bool) {
    return true;
  }

  function _deployFlexClient(address _governor) internal override {
    flexClient = MFVC(address(new MockFlexVotingDelegableClient(_governor)));
  }
}

contract TimestampClock__CastVoteReasonString is _CastVoteReasonString {
  function _timestampClock() internal pure override returns (bool) {
    return true;
  }

  function _deployFlexClient(address _governor) internal override {
    flexClient = MFVC(address(new MockFlexVotingDelegableClient(_governor)));
  }
}

contract TimestampClock__SelfDelegate is _SelfDelegate {
  function _timestampClock() internal pure override returns (bool) {
    return true;
  }

  function _deployFlexClient(address _governor) internal override {
    flexClient = MFVC(address(new MockFlexVotingDelegableClient(_governor)));
  }
}

contract TimestampClock__CheckpointVoteWeightOf is _CheckpointVoteWeightOf {
  function _timestampClock() internal pure override returns (bool) {
    return true;
  }

  function _deployFlexClient(address _governor) internal override {
    flexClient = MFVC(address(new MockFlexVotingDelegableClient(_governor)));
  }
}

contract TimestampClock__CheckpointTotalVoteWeight is _CheckpointTotalVoteWeight {
  function _timestampClock() internal pure override returns (bool) {
    return true;
  }

  function _deployFlexClient(address _governor) internal override {
    flexClient = MFVC(address(new MockFlexVotingDelegableClient(_governor)));
  }
}

contract TimestampClock_GetPastVoteWeight is GetPastVoteWeight {
  function _timestampClock() internal pure override returns (bool) {
    return true;
  }

  function _deployFlexClient(address _governor) internal override {
    flexClient = MFVC(address(new MockFlexVotingDelegableClient(_governor)));
  }
}

contract TimestampClock_GetPastTotalVoteWeight is GetPastTotalVoteWeight {
  function _timestampClock() internal pure override returns (bool) {
    return true;
  }

  function _deployFlexClient(address _governor) internal override {
    flexClient = MFVC(address(new MockFlexVotingDelegableClient(_governor)));
  }
}

contract TimestampClock_Withdraw is Withdraw {
  function _timestampClock() internal pure override returns (bool) {
    return true;
  }

  function _deployFlexClient(address _governor) internal override {
    flexClient = MFVC(address(new MockFlexVotingDelegableClient(_governor)));
  }
}

contract TimestampClock_Deposit is Deposit {
  function _timestampClock() internal pure override returns (bool) {
    return true;
  }

  function _deployFlexClient(address _governor) internal override {
    flexClient = MFVC(address(new MockFlexVotingDelegableClient(_governor)));
  }
}

contract TimestampClock_ExpressVote is ExpressVote {
  function _timestampClock() internal pure override returns (bool) {
    return true;
  }

  function _deployFlexClient(address _governor) internal override {
    flexClient = MFVC(address(new MockFlexVotingDelegableClient(_governor)));
  }
}

contract TimestampClock_CastVote is CastVote {
  function _timestampClock() internal pure override returns (bool) {
    return true;
  }

  function _deployFlexClient(address _governor) internal override {
    flexClient = MFVC(address(new MockFlexVotingDelegableClient(_governor)));
  }
}

contract TimestampClock_Borrow is Borrow {
  function _timestampClock() internal pure override returns (bool) {
    return true;
  }

  function _deployFlexClient(address _governor) internal override {
    flexClient = MFVC(address(new MockFlexVotingDelegableClient(_governor)));
  }
}

contract TimestampClockClock_Delegation is Delegation {
  function _timestampClock() internal pure override returns (bool) {
    return true;
  }

  function _deployFlexClient(address _governor) internal override {
    flexClient = MFVC(address(new MockFlexVotingDelegableClient(_governor)));
  }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {IVotes} from "@openzeppelin/contracts/governance/utils/IVotes.sol";
import {IGovernor} from "@openzeppelin/contracts/governance/Governor.sol";
import {GovernorCountingSimple as GCS} from
  "@openzeppelin/contracts/governance/extensions/GovernorCountingSimple.sol";
import {SignedMath} from "@openzeppelin/contracts/utils/math/SignedMath.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import {IVotingToken} from "src/interfaces/IVotingToken.sol";
import {IFractionalGovernor} from "src/interfaces/IFractionalGovernor.sol";
import {FlexVotingClient as FVC} from "src/FlexVotingClient.sol";
import {MockFlexVotingDelegatableClient} from "test/MockFlexVotingDelegatableClient.sol";
import {GovToken, TimestampGovToken} from "test/GovToken.sol";
import {FractionalGovernor} from "test/FractionalGovernor.sol";
import {ProposalReceiverMock} from "test/ProposalReceiverMock.sol";

abstract contract FlexVotingDelegatableTest is Test {
  MockFlexVotingDelegatableClient flexClient;
  GovToken token;
  FractionalGovernor governor;
  ProposalReceiverMock receiver;

  // This max is a limitation of GovernorCountingFractional's vote storage size.
  // See GovernorCountingFractional.ProposalVote struct.
  uint256 MAX_VOTES = type(uint128).max;

  // The highest valid vote type, represented as a uint256.
  uint256 MAX_VOTE_TYPE = uint256(type(GCS.VoteType).max);

  function setUp() public {
    if (_timestampClock()) token = new TimestampGovToken();
    else token = new GovToken();
    vm.label(address(token), "token");

    governor = new FractionalGovernor("Governor", IVotes(token));
    vm.label(address(governor), "governor");

    flexClient = new MockFlexVotingDelegatableClient(address(governor));
    vm.label(address(flexClient), "flexClient");

    receiver = new ProposalReceiverMock();
    vm.label(address(receiver), "receiver");
  }

  function _timestampClock() internal pure virtual returns (bool);

  function _now() internal view returns (uint48) {
    return token.clock();
  }

  function _advanceTimeBy(uint256 _timeUnits) internal {
    if (_timestampClock()) vm.warp(block.timestamp + _timeUnits);
    else vm.roll(block.number + _timeUnits);
  }

  function _advanceTimeTo(uint256 _timepoint) internal {
    if (_timestampClock()) vm.warp(_timepoint);
    else vm.roll(_timepoint);
  }

  function _mintGovAndApproveFlexClient(address _user, uint208 _amount) public {
    vm.assume(_user != address(0));
    token.exposed_mint(_user, _amount);
    vm.prank(_user);
    token.approve(address(flexClient), type(uint256).max);
  }

  function _mintGovAndDepositIntoFlexClient(address _address, uint208 _amount) internal {
    _mintGovAndApproveFlexClient(_address, _amount);
    vm.prank(_address);
    flexClient.deposit(_amount);
  }

  function _createAndSubmitProposal() internal returns (uint256 proposalId) {
    // Proposal will underflow if we're on the zero block
    if (_now() == 0) _advanceTimeBy(1);

    // Create a proposal
    bytes memory receiverCallData = abi.encodeWithSignature("mockReceiverFunction()");
    address[] memory targets = new address[](1);
    uint256[] memory values = new uint256[](1);
    bytes[] memory calldatas = new bytes[](1);
    targets[0] = address(receiver);
    values[0] = 0; // No ETH will be sent.
    calldatas[0] = receiverCallData;

    // Submit the proposal.
    proposalId = governor.propose(targets, values, calldatas, "A great proposal");
    assertEq(uint8(governor.state(proposalId)), uint8(IGovernor.ProposalState.Pending));

    // Advance proposal to active state.
    _advanceTimeTo(governor.proposalSnapshot(proposalId) + 1);
    assertEq(uint8(governor.state(proposalId)), uint8(IGovernor.ProposalState.Active));
  }

  function _assumeSafeUser(address _user) internal view {
    vm.assume(_user != address(flexClient));
    vm.assume(_user != address(0));
  }

  function _randVoteType(uint8 _seed) public view returns (GCS.VoteType) {
    return
      GCS.VoteType(uint8(bound(uint256(_seed), uint256(type(GCS.VoteType).min), MAX_VOTE_TYPE)));
  }

  function _assumeSafeVoteParams(address _account, uint208 _voteWeight)
    public
    view
    returns (uint208 _boundedWeight)
  {
    _assumeSafeUser(_account);
    _boundedWeight = uint208(bound(_voteWeight, 1, MAX_VOTES));
  }

  function _assumeSafeVoteParams(address _account, uint208 _voteWeight, uint8 _supportType)
    public
    view
    returns (uint208 _boundedWeight, GCS.VoteType _boundedSupport)
  {
    _assumeSafeUser(_account);
    _boundedSupport = _randVoteType(_supportType);
    _boundedWeight = uint208(bound(_voteWeight, 1, MAX_VOTES));
  }
}

abstract contract Deployment is FlexVotingDelegatableTest {
  function test_FlexVotingClientDeployment() public view {
    assertEq(token.name(), "Governance Token");
    assertEq(token.symbol(), "GOV");

    assertEq(address(flexClient.GOVERNOR()), address(governor));
    assertEq(token.delegates(address(flexClient)), address(flexClient));

    assertEq(governor.name(), "Governor");
    assertEq(address(governor.token()), address(token));
  }
}

abstract contract Delegation is FlexVotingDelegatableTest {
  // TODO
  // Users should need to delegate to themselves before they can express?
  // We need to checkpoint delegates.
  function test_delegation(
    address _delegator,
    address _delegatee,
    uint208 _weight,
    uint8 _supportType
  ) public {
    vm.label(_delegator, "delegator");
    vm.label(_delegatee, "delegatee");
    GCS.VoteType _voteType;
    (_weight, _voteType) = _assumeSafeVoteParams(_delegator, _weight, _supportType);
    _assumeSafeUser(_delegatee);
    vm.assume(_delegator != _delegatee);

    // Deposit some funds.
    _mintGovAndDepositIntoFlexClient(_delegator, _weight);

    // Delegate.
    vm.prank(_delegatee);
    flexClient.delegate(_delegatee);
    assertEq(flexClient.delegates(_delegatee), _delegatee);
    vm.prank(_delegator);
    flexClient.delegate(_delegatee);
    assertEq(flexClient.delegates(_delegator), _delegatee);

    // The delegator has not delegated *token* weight to the delegatee.
    assertEq(token.delegates(_delegator), address(0));
    assertEq(token.balanceOf(_delegator), 0);
    assertEq(token.balanceOf(_delegatee), 0);

    // Create the proposal.
    uint48 _proposalTimepoint = _now();
    uint256 _proposalId = _createAndSubmitProposal();

    // The delegator has no weight to vote with, despite having a deposit balance.
    assertEq(flexClient.deposits(_delegator), _weight);
    assertEq(flexClient.getPastRawBalance(_delegator, _proposalTimepoint), 0);
    vm.expectRevert(FVC.FlexVotingClient__NoVotingWeight.selector);
    vm.prank(_delegator);
    flexClient.expressVote(_proposalId, uint8(_voteType));

    // The delegatee *has* weight to vote with, despite having no deposit balance.
    assertEq(flexClient.deposits(_delegatee), 0);
    assertEq(flexClient.getPastRawBalance(_delegatee, _proposalTimepoint), _weight);
    vm.prank(_delegatee);
    flexClient.expressVote(_proposalId, uint8(_voteType));

    (uint256 _againstVotesExpressed, uint256 _forVotesExpressed, uint256 _abstainVotesExpressed) =
      flexClient.proposalVotes(_proposalId);
    assertEq(_forVotesExpressed, _voteType == GCS.VoteType.For ? _weight : 0);
    assertEq(_againstVotesExpressed, _voteType == GCS.VoteType.Against ? _weight : 0);
    assertEq(_abstainVotesExpressed, _voteType == GCS.VoteType.Abstain ? _weight : 0);
  }
}

// TODO test no double voting

contract BlockNumberClock_Deployment is Deployment {
  function _timestampClock() internal pure override returns (bool) {
    return false;
  }
}
contract BlockNumberClock_Delegation is Delegation {
  function _timestampClock() internal pure override returns (bool) {
    return false;
  }
}
contract TimestampClock_Deployment is Deployment {
  function _timestampClock() internal pure override returns (bool) {
    return true;
  }
}
contract TimestampClock_Delegation is Delegation {
  function _timestampClock() internal pure override returns (bool) {
    return true;
  }
}

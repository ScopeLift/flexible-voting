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
import {MockFlexVotingClient} from "test/MockFlexVotingClient.sol";
import {GovToken, TimestampGovToken} from "test/GovToken.sol";
import {FractionalGovernor} from "test/FractionalGovernor.sol";
import {ProposalReceiverMock} from "test/ProposalReceiverMock.sol";

abstract contract FlexVotingClientTest is Test {
  MockFlexVotingClient flexClient;
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

    _deployFlexClient(address(governor));
    vm.label(address(flexClient), "flexclient");

    receiver = new ProposalReceiverMock();
    vm.label(address(receiver), "receiver");
  }

  function _timestampClock() internal pure virtual returns (bool);

  // Function to deploy FlexVotingClient and write to `flexClient` storage var.
  function _deployFlexClient(address _governor) internal virtual;

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

abstract contract Deployment is FlexVotingClientTest {
  function test_FlexVotingClientDeployment() public view {
    assertEq(token.name(), "Governance Token");
    assertEq(token.symbol(), "GOV");

    assertEq(address(flexClient.GOVERNOR()), address(governor));
    assertEq(token.delegates(address(flexClient)), address(flexClient));

    assertEq(governor.name(), "Governor");
    assertEq(address(governor.token()), address(token));
  }
}

abstract contract Constructor is FlexVotingClientTest {
  function test_SetsGovernor() public view {
    assertEq(address(flexClient.GOVERNOR()), address(governor));
  }

  function test_SelfDelegates() public view {
    assertEq(token.delegates(address(flexClient)), address(flexClient));
  }
}

// Contract name has a leading underscore for scopelint spec support.
abstract contract _RawBalanceOf is FlexVotingClientTest {
  function testFuzz_ReturnsZeroForNonDepositors(address _user) public view {
    _assumeSafeUser(_user);
    assertEq(flexClient.exposed_rawBalanceOf(_user), 0);
  }

  function testFuzz_IncreasesOnDeposit(address _user, uint208 _amount) public {
    _assumeSafeUser(_user);
    _amount = uint208(bound(_amount, 1, MAX_VOTES));

    // Deposit some gov.
    _mintGovAndDepositIntoFlexClient(_user, _amount);

    assertEq(flexClient.exposed_rawBalanceOf(_user), _amount);
  }

  function testFuzz_DecreasesOnWithdrawal(address _user, uint208 _amount) public {
    _assumeSafeUser(_user);
    _amount = uint208(bound(_amount, 1, MAX_VOTES));

    // Deposit some gov.
    _mintGovAndDepositIntoFlexClient(_user, _amount);

    assertEq(flexClient.exposed_rawBalanceOf(_user), _amount);

    vm.prank(_user);
    flexClient.withdraw(_amount);
    assertEq(flexClient.exposed_rawBalanceOf(_user), 0);
  }

  function testFuzz_UnaffectedByBorrow(address _user, uint208 _deposit, uint208 _borrow) public {
    _assumeSafeUser(_user);
    _deposit = uint208(bound(_deposit, 1, MAX_VOTES));
    _borrow = uint208(bound(_borrow, 1, _deposit));

    // Deposit some gov.
    _mintGovAndDepositIntoFlexClient(_user, _deposit);

    assertEq(flexClient.exposed_rawBalanceOf(_user), _deposit);

    vm.prank(_user);
    flexClient.borrow(_borrow);

    // Raw balance is unchanged.
    assertEq(flexClient.exposed_rawBalanceOf(_user), _deposit);
  }
}

// Contract name has a leading underscore for scopelint spec support.
abstract contract _CastVoteReasonString is FlexVotingClientTest {
  function test_ReturnsDescriptiveString() public {
    assertEq(
      flexClient.exposed_castVoteReasonString(), "rolled-up vote from governance token holders"
    );
  }
}

// Contract name has a leading underscore for scopelint spec support.
abstract contract _SelfDelegate is FlexVotingClientTest {
  function testFuzz_SetsClientAsTheDelegate(address _delegatee) public {
    vm.assume(_delegatee != address(0));
    vm.assume(_delegatee != address(flexClient));

    // We self-delegate in the constructor, so we need to first un-delegate for
    // this test to be meaningful.
    vm.prank(address(flexClient));
    token.delegate(_delegatee);
    assertEq(token.delegates(address(flexClient)), _delegatee);

    flexClient.exposed_selfDelegate();
    assertEq(token.delegates(address(flexClient)), address(flexClient));
  }
}

// Contract name has a leading underscore for scopelint spec support.
abstract contract _CheckpointRawBalanceOf is FlexVotingClientTest {
  function testFuzz_StoresTheRawBalanceWithTheTimepoint(
    address _user,
    uint208 _amount,
    uint48 _future
  ) public {
    vm.assume(_user != address(flexClient));
    _future = uint48(bound(_future, _now() + 1, type(uint48).max));
    _amount = uint208(bound(_amount, 1, MAX_VOTES));
    uint48 _past = _now();

    _advanceTimeTo(_future);
    flexClient.exposed_setDeposits(_user, _amount);
    flexClient.exposed_checkpointRawBalanceOf(_user);

    assertEq(flexClient.getPastRawBalance(_user, _past), 0);
    assertEq(flexClient.getPastRawBalance(_user, _future), _amount);
  }
}

abstract contract _CheckpointTotalBalance is FlexVotingClientTest {
  int256 MAX_UINT208 = int256(uint256(type(uint208).max));

  function testFuzz_writesACheckpointAtClockTime(int256 _value, uint48 _timepoint) public {
    _timepoint = uint48(bound(_timepoint, 1, type(uint48).max - 1));
    _value = bound(_value, 1, MAX_UINT208);
    assertEq(flexClient.exposed_latestTotalBalance(), 0);

    _advanceTimeTo(_timepoint);
    flexClient.exposed_checkpointTotalBalance(_value);
    _advanceTimeBy(1);

    assertEq(flexClient.getPastTotalBalance(_timepoint), uint256(_value));
    assertEq(flexClient.exposed_latestTotalBalance(), uint256(_value));
  }

  function testFuzz_checkpointsTheTotalBalanceDeltaAtClockTime(
    int256 _initBalance,
    int256 _delta,
    uint48 _timepoint
  ) public {
    _timepoint = uint48(bound(_timepoint, 1, type(uint48).max - 1));
    _initBalance = bound(_initBalance, 1, MAX_UINT208 - 1);
    _delta = bound(_delta, -_initBalance, MAX_UINT208 - _initBalance);
    flexClient.exposed_checkpointTotalBalance(_initBalance);

    _advanceTimeTo(_timepoint);
    flexClient.exposed_checkpointTotalBalance(_delta);
    _advanceTimeBy(1);

    assertEq(flexClient.getPastTotalBalance(_timepoint), uint256(_initBalance + _delta));
  }

  function testFuzz_RevertIf_negativeDeltaWraps(int256 delta, uint208 balance) public {
    // Math.abs(delta) must be > balance for the concerning scenario to arise.
    delta = bound(delta, type(int256).min, -int256(uint256(balance)) - 1);
    assertTrue(SignedMath.abs(delta) > balance);

    // Effectively this function has 5 steps.
    //
    // Step 1: Cast balance up from a uint208 to a uint256.
    // Safe, since uint256 is bigger.
    uint256 balanceUint256 = uint256(balance);

    // Step 2: Cast balance down to int256.
    // Safe, since uint208.max < int256.max.
    int256 balanceInt256 = int256(balanceUint256);

    // Step 3: Add the delta. The result might be negative.
    int256 netBalanceInt256 = balanceInt256 + delta;

    // Step 4: Cast back to uint256.
    //
    // This is where things get a little scary.
    //   uint256(int256) = 2^256 + int256, for int256 < 0.
    // If |delta| > balance, then netBalance will be a negative int256 and when
    // we cast to uint256 it will wrap to a very large positive number.
    uint256 netBalanceUint256 = uint256(netBalanceInt256);

    // Step 5: Cast back to uint208.
    // We need to ensure that when |delta| > balance:
    //   uint256(balance + delta) > uint208.max
    // As this will cause the safecast to fail.
    assert(netBalanceUint256 > type(uint208).max);
    vm.expectRevert();
    SafeCast.toUint208(netBalanceUint256);
  }

  function testFuzz_RevertIf_withdrawalFromZero(int256 _withdraw) public {
    _withdraw = bound(_withdraw, type(int208).min, -1);
    vm.expectRevert();
    flexClient.exposed_checkpointTotalBalance(_withdraw);
  }

  function testFuzz_RevertIf_withdrawalExceedsDeposit(int256 _deposit, int256 _withdraw) public {
    _deposit = bound(_deposit, 1, type(int208).max - 1);
    _withdraw = bound(_withdraw, type(int208).min, (-1 * _deposit) - 1);

    flexClient.exposed_checkpointTotalBalance(_deposit);
    vm.expectRevert();
    flexClient.exposed_checkpointTotalBalance(_withdraw);
  }

  function testFuzz_RevertIf_depositsOverflow(int256 _deposit1, int256 _deposit2) public {
    int256 _max = int256(uint256(type(uint208).max));
    _deposit1 = bound(_deposit1, 1, _max);
    _deposit2 = bound(_deposit2, 1 + _max - _deposit1, _max);

    flexClient.exposed_checkpointTotalBalance(_deposit1);
    vm.expectRevert();
    flexClient.exposed_checkpointTotalBalance(_deposit2);
  }
}

abstract contract GetPastRawBalance is FlexVotingClientTest {
  function testFuzz_ReturnsZeroForUsersWithoutDeposits(
    address _depositor,
    address _nonDepositor,
    uint208 _amount
  ) public {
    vm.assume(_depositor != address(flexClient));
    vm.assume(_nonDepositor != address(flexClient));
    vm.assume(_nonDepositor != _depositor);
    _amount = uint208(bound(_amount, 1, MAX_VOTES));

    _advanceTimeBy(1);
    assertEq(flexClient.getPastRawBalance(_depositor, 0), 0);
    assertEq(flexClient.getPastRawBalance(_nonDepositor, 0), 0);

    _mintGovAndDepositIntoFlexClient(_depositor, _amount);
    _advanceTimeBy(1);

    assertEq(flexClient.getPastRawBalance(_depositor, _now() - 1), _amount);
    assertEq(flexClient.getPastRawBalance(_nonDepositor, _now() - 1), 0);
  }

  function testFuzz_ReturnsCurrentValueForFutureTimepoints(
    address _user,
    uint208 _amount,
    uint48 _timepoint
  ) public {
    vm.assume(_user != address(flexClient));
    _timepoint = uint48(bound(_timepoint, _now() + 1, type(uint48).max));
    _amount = uint208(bound(_amount, 1, MAX_VOTES));

    _mintGovAndDepositIntoFlexClient(_user, _amount);

    assertEq(flexClient.getPastRawBalance(_user, _now()), _amount);
    assertEq(flexClient.getPastRawBalance(_user, _timepoint), _amount);

    _advanceTimeTo(_timepoint);

    assertEq(flexClient.getPastRawBalance(_user, _now()), _amount);
  }

  function testFuzz_ReturnsUserBalanceAtAGivenTimepoint(
    address _user,
    uint208 _amountA,
    uint208 _amountB,
    uint48 _timepoint
  ) public {
    vm.assume(_user != address(flexClient));
    _timepoint = uint48(bound(_timepoint, _now() + 1, type(uint48).max));
    _amountA = uint208(bound(_amountA, 1, MAX_VOTES));
    _amountB = uint208(bound(_amountB, 0, MAX_VOTES - _amountA));

    uint48 _initTimepoint = _now();
    _mintGovAndDepositIntoFlexClient(_user, _amountA);

    _advanceTimeTo(_timepoint);

    _mintGovAndDepositIntoFlexClient(_user, _amountB);
    _advanceTimeBy(1);

    uint48 _zeroTimepoint = 0;
    assertEq(flexClient.getPastRawBalance(_user, _zeroTimepoint), 0);
    assertEq(flexClient.getPastRawBalance(_user, _initTimepoint), _amountA);
    assertEq(flexClient.getPastRawBalance(_user, _timepoint), _amountA + _amountB);
  }
}

abstract contract GetPastTotalBalance is FlexVotingClientTest {
  function testFuzz_ReturnsZeroWithoutDeposits(uint48 _future) public view {
    uint48 _zeroTimepoint = 0;
    assertEq(flexClient.getPastTotalBalance(_zeroTimepoint), 0);
    assertEq(flexClient.getPastTotalBalance(_future), 0);
  }

  function testFuzz_ReturnsCurrentValueForFutureTimepoints(
    address _user,
    uint208 _amount,
    uint48 _future
  ) public {
    vm.assume(_user != address(flexClient));
    _future = uint48(bound(_future, _now() + 1, type(uint48).max));
    _amount = uint208(bound(_amount, 1, MAX_VOTES));

    _mintGovAndDepositIntoFlexClient(_user, _amount);

    assertEq(flexClient.getPastTotalBalance(_now()), _amount);
    assertEq(flexClient.getPastTotalBalance(_future), _amount);

    _advanceTimeTo(_future);

    assertEq(flexClient.getPastTotalBalance(_now()), _amount);
  }

  function testFuzz_SumsAllUserDeposits(
    address _userA,
    uint208 _amountA,
    address _userB,
    uint208 _amountB
  ) public {
    vm.assume(_userA != address(flexClient));
    vm.assume(_userB != address(flexClient));
    vm.assume(_userA != _userB);

    _amountA = uint208(bound(_amountA, 1, MAX_VOTES));
    _amountB = uint208(bound(_amountB, 0, MAX_VOTES - _amountA));

    _mintGovAndDepositIntoFlexClient(_userA, _amountA);
    _mintGovAndDepositIntoFlexClient(_userB, _amountB);

    _advanceTimeBy(1);

    assertEq(flexClient.getPastTotalBalance(_now()), _amountA + _amountB);
  }

  function testFuzz_ReturnsTotalDepositsAtAGivenTimepoint(
    address _userA,
    uint208 _amountA,
    address _userB,
    uint208 _amountB,
    uint48 _future
  ) public {
    vm.assume(_userA != address(flexClient));
    vm.assume(_userB != address(flexClient));
    vm.assume(_userA != _userB);
    _future = uint48(bound(_future, _now() + 1, type(uint48).max));

    _amountA = uint208(bound(_amountA, 1, MAX_VOTES));
    _amountB = uint208(bound(_amountB, 0, MAX_VOTES - _amountA));

    assertEq(flexClient.getPastTotalBalance(_now()), 0);

    _mintGovAndDepositIntoFlexClient(_userA, _amountA);
    _advanceTimeTo(_future);
    _mintGovAndDepositIntoFlexClient(_userB, _amountB);

    assertEq(flexClient.getPastTotalBalance(_now() - _future + 1), _amountA);
    assertEq(flexClient.getPastTotalBalance(_now()), _amountA + _amountB);
  }
}

abstract contract Withdraw is FlexVotingClientTest {
  function testFuzz_UserCanWithdrawGovTokens(address _lender, address _borrower, uint208 _amount)
    public
  {
    _amount = uint208(bound(_amount, 0, type(uint208).max));
    vm.assume(_lender != address(flexClient));
    vm.assume(_borrower != address(flexClient));
    vm.assume(_borrower != address(0));
    vm.assume(_lender != _borrower);

    uint256 _initBalance = token.balanceOf(_borrower);
    assertEq(flexClient.deposits(_borrower), 0);
    assertEq(flexClient.borrowTotal(_borrower), 0);

    _mintGovAndDepositIntoFlexClient(_lender, _amount);
    assertEq(flexClient.deposits(_lender), _amount);

    // Borrow the funds.
    vm.prank(_borrower);
    flexClient.borrow(_amount);

    assertEq(token.balanceOf(_borrower), _initBalance + _amount);
    assertEq(flexClient.borrowTotal(_borrower), _amount);

    // Deposit totals are unaffected.
    assertEq(flexClient.deposits(_lender), _amount);
    assertEq(flexClient.deposits(_borrower), 0);
  }

  // `borrow`s affects on vote weights are tested in Vote contract below.
}

abstract contract Deposit is FlexVotingClientTest {
  function testFuzz_UserCanDepositGovTokens(address _user, uint208 _amount) public {
    _amount = uint208(bound(_amount, 0, type(uint208).max));
    vm.assume(_user != address(flexClient));
    uint256 initialBalance = token.balanceOf(_user);
    assertEq(flexClient.deposits(_user), 0);

    _mintGovAndDepositIntoFlexClient(_user, _amount);

    assertEq(token.balanceOf(address(flexClient)), _amount);
    assertEq(token.balanceOf(_user), initialBalance);
    assertEq(token.getVotes(address(flexClient)), _amount);

    // Confirm internal accounting has updated.
    assertEq(flexClient.deposits(_user), _amount);
  }

  function testFuzz_DepositsAreCheckpointed(
    address _user,
    uint208 _amountA,
    uint208 _amountB,
    uint24 _depositDelay
  ) public {
    _amountA = uint208(bound(_amountA, 1, MAX_VOTES));
    _amountB = uint208(bound(_amountB, 0, MAX_VOTES - _amountA));

    // Deposit some gov.
    _mintGovAndDepositIntoFlexClient(_user, _amountA);
    assertEq(flexClient.deposits(_user), _amountA);

    _advanceTimeBy(1); // Advance so that we can look at checkpoints.

    // We can still retrieve the user's balance at the given time.
    uint256 _checkpoint1 = _now() - 1;
    assertEq(
      flexClient.getPastRawBalance(_user, _checkpoint1),
      _amountA,
      "user's first deposit was not properly checkpointed"
    );

    uint256 _checkpoint2 = _now() + _depositDelay;
    _advanceTimeTo(_checkpoint2);

    // Deposit some more.
    _mintGovAndDepositIntoFlexClient(_user, _amountB);
    assertEq(flexClient.deposits(_user), _amountA + _amountB);

    _advanceTimeBy(1); // Advance so that we can look at checkpoints.

    assertEq(
      flexClient.getPastRawBalance(_user, _checkpoint1),
      _amountA,
      "user's first deposit was not properly checkpointed"
    );
    assertEq(
      flexClient.getPastRawBalance(_user, _checkpoint2),
      _amountA + _amountB,
      "user's second deposit was not properly checkpointed"
    );
  }
}

abstract contract ExpressVote is FlexVotingClientTest {
  function testFuzz_IncrementsInternalAccouting(
    address _user,
    uint208 _voteWeight,
    uint8 _supportType
  ) public {
    GCS.VoteType _voteType;
    (_voteWeight, _voteType) = _assumeSafeVoteParams(_user, _voteWeight, _supportType);

    // Deposit some funds.
    _mintGovAndDepositIntoFlexClient(_user, _voteWeight);

    // Create the proposal.
    uint256 _proposalId = _createAndSubmitProposal();

    // _user should now be able to express his/her vote on the proposal.
    vm.prank(_user);
    flexClient.expressVote(_proposalId, uint8(_voteType));
    (uint256 _againstVotesExpressed, uint256 _forVotesExpressed, uint256 _abstainVotesExpressed) =
      flexClient.proposalVotes(_proposalId);
    assertEq(_forVotesExpressed, _voteType == GCS.VoteType.For ? _voteWeight : 0);
    assertEq(_againstVotesExpressed, _voteType == GCS.VoteType.Against ? _voteWeight : 0);
    assertEq(_abstainVotesExpressed, _voteType == GCS.VoteType.Abstain ? _voteWeight : 0);

    // No votes have been cast yet.
    (uint256 _againstVotes, uint256 _forVotes, uint256 _abstainVotes) =
      governor.proposalVotes(_proposalId);
    assertEq(_forVotes, 0);
    assertEq(_againstVotes, 0);
    assertEq(_abstainVotes, 0);
  }

  function testFuzz_RevertWhen_DepositingAfterProposal(
    address _user,
    uint208 _voteWeight,
    uint8 _supportType
  ) public {
    GCS.VoteType _voteType;
    (_voteWeight, _voteType) = _assumeSafeVoteParams(_user, _voteWeight, _supportType);

    // Create the proposal *before* the user deposits anything.
    uint256 _proposalId = _createAndSubmitProposal();

    // Deposit some funds.
    _mintGovAndDepositIntoFlexClient(_user, _voteWeight);

    // Now try to express a voting preference on the proposal.
    assertEq(flexClient.deposits(_user), _voteWeight);
    vm.expectRevert(FVC.FlexVotingClient__NoVotingWeight.selector);
    vm.prank(_user);
    flexClient.expressVote(_proposalId, uint8(_voteType));
  }

  function testFuzz_RevertWhen_NoClientWeightButTokenWeight(
    address _user,
    uint208 _voteWeight,
    uint8 _supportType
  ) public {
    GCS.VoteType _voteType;
    (_voteWeight, _voteType) = _assumeSafeVoteParams(_user, _voteWeight, _supportType);

    // Mint gov but do not deposit.
    _mintGovAndApproveFlexClient(_user, _voteWeight);
    assertEq(token.balanceOf(_user), _voteWeight);
    assertEq(flexClient.deposits(_user), 0);

    // Create the proposal.
    uint256 _proposalId = _createAndSubmitProposal();

    // _user should NOT be able to express his/her vote on the proposal.
    vm.expectRevert(FVC.FlexVotingClient__NoVotingWeight.selector);
    vm.prank(_user);
    flexClient.expressVote(_proposalId, uint8(_voteType));

    // Deposit into the client.
    vm.prank(_user);
    flexClient.deposit(_voteWeight);
    assertEq(flexClient.deposits(_user), _voteWeight);

    // _user should still NOT be able to express his/her vote on the proposal.
    // Despite having a deposit balance, he/she didn't have a balance at the
    // proposal snapshot.
    vm.expectRevert(FVC.FlexVotingClient__NoVotingWeight.selector);
    vm.prank(_user);
    flexClient.expressVote(_proposalId, uint8(_voteType));
  }

  function testFuzz_RevertOn_DoubleVotes(address _user, uint208 _voteWeight, uint8 _supportType)
    public
  {
    GCS.VoteType _voteType;
    (_voteWeight, _voteType) = _assumeSafeVoteParams(_user, _voteWeight, _supportType);

    // Deposit some funds.
    _mintGovAndDepositIntoFlexClient(_user, _voteWeight);

    // Create the proposal.
    uint256 _proposalId = _createAndSubmitProposal();

    // _user should now be able to express his/her vote on the proposal.
    vm.prank(_user);
    flexClient.expressVote(_proposalId, uint8(_voteType));

    (
      uint256 _againstVotesExpressedInit,
      uint256 _forVotesExpressedInit,
      uint256 _abstainVotesExpressedInit
    ) = flexClient.proposalVotes(_proposalId);
    assertEq(_forVotesExpressedInit, _voteType == GCS.VoteType.For ? _voteWeight : 0);
    assertEq(_againstVotesExpressedInit, _voteType == GCS.VoteType.Against ? _voteWeight : 0);
    assertEq(_abstainVotesExpressedInit, _voteType == GCS.VoteType.Abstain ? _voteWeight : 0);

    // Vote early and often!
    vm.expectRevert(FVC.FlexVotingClient__AlreadyVoted.selector);
    vm.prank(_user);
    flexClient.expressVote(_proposalId, uint8(_voteType));

    // No votes changed.
    (uint256 _againstVotesExpressed, uint256 _forVotesExpressed, uint256 _abstainVotesExpressed) =
      flexClient.proposalVotes(_proposalId);
    assertEq(_forVotesExpressed, _forVotesExpressedInit);
    assertEq(_againstVotesExpressed, _againstVotesExpressedInit);
    assertEq(_abstainVotesExpressed, _abstainVotesExpressedInit);
  }

  function testFuzz_RevertOn_UnknownVoteType(address _user, uint208 _voteWeight, uint8 _supportType)
    public
  {
    // Force vote type to be unrecognized.
    _supportType = uint8(bound(_supportType, MAX_VOTE_TYPE + 1, type(uint8).max));

    _assumeSafeUser(_user);
    _voteWeight = uint208(bound(_voteWeight, 1, MAX_VOTES));

    // Deposit some funds.
    _mintGovAndDepositIntoFlexClient(_user, _voteWeight);

    // Create the proposal.
    uint256 _proposalId = _createAndSubmitProposal();

    // Now try to express a voting preference with a bogus support type.
    vm.expectRevert(FVC.FlexVotingClient__InvalidSupportValue.selector);
    vm.prank(_user);
    flexClient.expressVote(_proposalId, _supportType);
  }

  function testFuzz_RevertOn_UnknownProposal(
    address _user,
    uint208 _voteWeight,
    uint8 _supportType,
    uint256 _proposalId
  ) public {
    _assumeSafeUser(_user);
    _voteWeight = uint208(bound(_voteWeight, 1, MAX_VOTES));

    // Confirm that we've pulled a bogus proposal number.
    // This is the condition Governor.state checks for when raising
    // GovernorNonexistentProposal.
    vm.assume(governor.proposalSnapshot(_proposalId) == 0);

    // Force vote type to be unrecognized.
    _supportType = uint8(bound(_supportType, MAX_VOTE_TYPE + 1, type(uint8).max));

    // Deposit some funds.
    _mintGovAndDepositIntoFlexClient(_user, _voteWeight);

    // Create a real proposal to verify the two won't be mixed up when
    // expressing.
    uint256 _id = _createAndSubmitProposal();
    assert(_proposalId != _id);

    // Now try to express a voting preference on the bogus proposal.
    vm.expectRevert(FVC.FlexVotingClient__NoVotingWeight.selector);
    vm.prank(_user);
    flexClient.expressVote(_proposalId, _supportType);
  }
}

abstract contract CastVote is FlexVotingClientTest {
  function testFuzz_SubmitsVotesToGovernor(address _user, uint208 _voteWeight, uint8 _supportType)
    public
  {
    GCS.VoteType _voteType;
    (_voteWeight, _voteType) = _assumeSafeVoteParams(_user, _voteWeight, _supportType);

    // Deposit some funds.
    _mintGovAndDepositIntoFlexClient(_user, _voteWeight);

    // Create the proposal.
    uint256 _proposalId = _createAndSubmitProposal();

    // _user should now be able to express his/her vote on the proposal.
    vm.prank(_user);
    flexClient.expressVote(_proposalId, uint8(_voteType));
    (uint256 _againstVotesExpressed, uint256 _forVotesExpressed, uint256 _abstainVotesExpressed) =
      flexClient.proposalVotes(_proposalId);
    assertEq(_forVotesExpressed, _voteType == GCS.VoteType.For ? _voteWeight : 0);
    assertEq(_againstVotesExpressed, _voteType == GCS.VoteType.Against ? _voteWeight : 0);
    assertEq(_abstainVotesExpressed, _voteType == GCS.VoteType.Abstain ? _voteWeight : 0);

    // No votes have been cast yet.
    (uint256 _againstVotes, uint256 _forVotes, uint256 _abstainVotes) =
      governor.proposalVotes(_proposalId);
    assertEq(_forVotes, 0);
    assertEq(_againstVotes, 0);
    assertEq(_abstainVotes, 0);

    // Submit votes on behalf of the flexClient.
    flexClient.castVote(_proposalId);

    // Governor should now record votes from the flexClient.
    (_againstVotes, _forVotes, _abstainVotes) = governor.proposalVotes(_proposalId);
    assertEq(_forVotes, _forVotesExpressed);
    assertEq(_againstVotes, _againstVotesExpressed);
    assertEq(_abstainVotes, _abstainVotesExpressed);
  }

  function testFuzz_WeightIsSnapshotDependent(
    address _user,
    uint208 _voteWeightA,
    uint208 _voteWeightB,
    uint8 _supportType
  ) public {
    GCS.VoteType _voteType;
    (_voteWeightA, _voteType) = _assumeSafeVoteParams(_user, _voteWeightA, _supportType);
    _voteWeightB = _assumeSafeVoteParams(_user, _voteWeightB);

    // Deposit some funds.
    _mintGovAndDepositIntoFlexClient(_user, _voteWeightA);

    // Create the proposal.
    uint256 _proposalId = _createAndSubmitProposal();

    // Sometime later the user deposits some more.
    _advanceTimeTo(governor.proposalDeadline(_proposalId) - 1);
    _mintGovAndDepositIntoFlexClient(_user, _voteWeightB);

    vm.prank(_user);
    flexClient.expressVote(_proposalId, uint8(_voteType));

    // The internal proposal vote weight should not reflect the new deposit weight.
    (uint256 _againstVotesExpressed, uint256 _forVotesExpressed, uint256 _abstainVotesExpressed) =
      flexClient.proposalVotes(_proposalId);
    assertEq(_forVotesExpressed, _voteType == GCS.VoteType.For ? _voteWeightA : 0);
    assertEq(_againstVotesExpressed, _voteType == GCS.VoteType.Against ? _voteWeightA : 0);
    assertEq(_abstainVotesExpressed, _voteType == GCS.VoteType.Abstain ? _voteWeightA : 0);

    // Submit votes on behalf of the flexClient.
    flexClient.castVote(_proposalId);

    // Votes cast should likewise reflect only the earlier balance.
    (uint256 _againstVotes, uint256 _forVotes, uint256 _abstainVotes) =
      governor.proposalVotes(_proposalId);
    assertEq(_forVotes, _voteType == GCS.VoteType.For ? _voteWeightA : 0);
    assertEq(_againstVotes, _voteType == GCS.VoteType.Against ? _voteWeightA : 0);
    assertEq(_abstainVotes, _voteType == GCS.VoteType.Abstain ? _voteWeightA : 0);
  }

  function testFuzz_TracksMultipleUsersVotes(
    address _userA,
    address _userB,
    uint208 _voteWeightA,
    uint208 _voteWeightB
  ) public {
    vm.assume(_userA != _userB);
    _assumeSafeUser(_userA);
    _assumeSafeUser(_userB);
    _voteWeightA = uint208(bound(_voteWeightA, 1, MAX_VOTES - 1));
    _voteWeightB = uint208(bound(_voteWeightB, 1, MAX_VOTES - _voteWeightA));

    // Deposit some funds.
    _mintGovAndDepositIntoFlexClient(_userA, _voteWeightA);
    _mintGovAndDepositIntoFlexClient(_userB, _voteWeightB);

    // Create the proposal.
    uint256 _proposalId = _createAndSubmitProposal();

    // users should now be able to express their votes on the proposal.
    vm.prank(_userA);
    flexClient.expressVote(_proposalId, uint8(GCS.VoteType.Against));
    vm.prank(_userB);
    flexClient.expressVote(_proposalId, uint8(GCS.VoteType.Abstain));

    (uint256 _againstVotesExpressed, uint256 _forVotesExpressed, uint256 _abstainVotesExpressed) =
      flexClient.proposalVotes(_proposalId);
    assertEq(_forVotesExpressed, 0);
    assertEq(_againstVotesExpressed, _voteWeightA);
    assertEq(_abstainVotesExpressed, _voteWeightB);

    // The governor should have not recieved any votes yet.
    (uint256 _againstVotes, uint256 _forVotes, uint256 _abstainVotes) =
      governor.proposalVotes(_proposalId);
    assertEq(_forVotes, 0);
    assertEq(_againstVotes, 0);
    assertEq(_abstainVotes, 0);

    // Submit votes on behalf of the flexClient.
    flexClient.castVote(_proposalId);

    // Governor should now record votes for the flexClient.
    (_againstVotes, _forVotes, _abstainVotes) = governor.proposalVotes(_proposalId);
    assertEq(_forVotes, 0);
    assertEq(_againstVotes, _voteWeightA);
    assertEq(_abstainVotes, _voteWeightB);
  }

  struct VoteWeightIsScaledTestVars {
    address userA;
    address userB;
    address userC;
    address userD;
    uint208 voteWeightA;
    uint8 supportTypeA;
    uint208 voteWeightB;
    uint8 supportTypeB;
    uint208 borrowAmountC;
    uint208 borrowAmountD;
  }

  function testFuzz_ScalesVoteWeightBasedOnPoolBalance(VoteWeightIsScaledTestVars memory _vars)
    public
  {
    _vars.userA = address(0xbeef);
    _vars.userB = address(0xbabe);
    _vars.userC = address(0xf005ba11);
    _vars.userD = address(0xba5eba11);

    _vars.supportTypeA = uint8(bound(_vars.supportTypeA, 0, MAX_VOTE_TYPE));
    _vars.supportTypeB = uint8(bound(_vars.supportTypeB, 0, MAX_VOTE_TYPE));

    _vars.voteWeightA = uint208(bound(_vars.voteWeightA, 1e4, MAX_VOTES - 1e4 - 1));
    _vars.voteWeightB = uint208(bound(_vars.voteWeightB, 1e4, MAX_VOTES - _vars.voteWeightA - 1));

    uint208 _maxBorrowWeight = _vars.voteWeightA + _vars.voteWeightB;
    _vars.borrowAmountC = uint208(bound(_vars.borrowAmountC, 1, _maxBorrowWeight - 1));
    _vars.borrowAmountD =
      uint208(bound(_vars.borrowAmountD, 1, _maxBorrowWeight - _vars.borrowAmountC));

    // These are here just as a sanity check that all of the bounding above worked.
    vm.assume(_vars.voteWeightA + _vars.voteWeightB < MAX_VOTES);
    vm.assume(_vars.voteWeightA + _vars.voteWeightB >= _vars.borrowAmountC + _vars.borrowAmountD);

    // Mint and deposit.
    _mintGovAndDepositIntoFlexClient(_vars.userA, _vars.voteWeightA);
    _mintGovAndDepositIntoFlexClient(_vars.userB, _vars.voteWeightB);
    uint256 _initDepositWeight = token.balanceOf(address(flexClient));

    // Borrow from the flexClient, decreasing its token balance.
    vm.prank(_vars.userC);
    flexClient.borrow(_vars.borrowAmountC);

    // Create the proposal.
    uint256 _proposalId = _createAndSubmitProposal();

    // Jump ahead to the proposal snapshot to lock in the flexClient's balance.
    _advanceTimeTo(governor.proposalSnapshot(_proposalId) + 1);
    uint256 _expectedVotingWeight = token.balanceOf(address(flexClient));
    assert(_expectedVotingWeight < _initDepositWeight);

    // A+B express votes
    vm.prank(_vars.userA);
    flexClient.expressVote(_proposalId, _vars.supportTypeA);
    vm.prank(_vars.userB);
    flexClient.expressVote(_proposalId, _vars.supportTypeB);

    // Borrow more from the flexClient, just to confirm that the vote weight will be based
    // on the snapshot blocktime/number.
    vm.prank(_vars.userD);
    flexClient.borrow(_vars.borrowAmountD);

    // Submit votes on behalf of the flexClient.
    flexClient.castVote(_proposalId);

    // Vote should be cast as a percentage of the depositer's expressed types, since
    // the actual weight is different from the deposit weight.
    (uint256 _againstVotes, uint256 _forVotes, uint256 _abstainVotes) =
      governor.proposalVotes(_proposalId);

    // These can differ because votes are rounded.
    assertApproxEqAbs(_againstVotes + _forVotes + _abstainVotes, _expectedVotingWeight, 1);

    if (_vars.supportTypeA == _vars.supportTypeB) {
      assertEq(_forVotes, _vars.supportTypeA == uint8(GCS.VoteType.For) ? _expectedVotingWeight : 0);
      assertEq(
        _againstVotes, _vars.supportTypeA == uint8(GCS.VoteType.Against) ? _expectedVotingWeight : 0
      );
      assertEq(
        _abstainVotes, _vars.supportTypeA == uint8(GCS.VoteType.Abstain) ? _expectedVotingWeight : 0
      );
    } else {
      uint256 _expectedVotingWeightA =
        (_vars.voteWeightA * _expectedVotingWeight) / _initDepositWeight;
      uint256 _expectedVotingWeightB =
        (_vars.voteWeightB * _expectedVotingWeight) / _initDepositWeight;

      // We assert the weight is within a range of 1 because scaled weights are sometimes floored.
      if (_vars.supportTypeA == uint8(GCS.VoteType.For)) {
        assertApproxEqAbs(_forVotes, _expectedVotingWeightA, 1);
      }
      if (_vars.supportTypeB == uint8(GCS.VoteType.For)) {
        assertApproxEqAbs(_forVotes, _expectedVotingWeightB, 1);
      }
      if (_vars.supportTypeA == uint8(GCS.VoteType.Against)) {
        assertApproxEqAbs(_againstVotes, _expectedVotingWeightA, 1);
      }
      if (_vars.supportTypeB == uint8(GCS.VoteType.Against)) {
        assertApproxEqAbs(_againstVotes, _expectedVotingWeightB, 1);
      }
      if (_vars.supportTypeA == uint8(GCS.VoteType.Abstain)) {
        assertApproxEqAbs(_abstainVotes, _expectedVotingWeightA, 1);
      }
      if (_vars.supportTypeB == uint8(GCS.VoteType.Abstain)) {
        assertApproxEqAbs(_abstainVotes, _expectedVotingWeightB, 1);
      }
    }
  }

  // This is important because it ensures you can't *gain* voting weight by
  // getting other people to not vote.
  function testFuzz_AbandonsUnexpressedVotingWeight(
    uint208 _voteWeightA,
    uint208 _voteWeightB,
    uint8 _supportTypeA,
    uint208 _borrowAmount
  ) public {
    // We need to do this to prevent:
    // "CompilerError: Stack too deep, try removing local variables."
    address[3] memory _users = [
      address(0xbeef), // userA
      address(0xbabe), // userB
      address(0xf005ba11) // userC
    ];

    // Requirements:
    //   voteWeights and borrow each >= 1
    //   voteWeights and borrow each <= uint128.max
    //   _voteWeightA + _voteWeightB < MAX_VOTES
    //   _voteWeightA + _voteWeightB > _borrowAmount
    _voteWeightA = uint208(bound(_voteWeightA, 1, MAX_VOTES - 2));
    _voteWeightB = uint208(bound(_voteWeightB, 1, MAX_VOTES - _voteWeightA - 1));
    _borrowAmount = uint208(bound(_borrowAmount, 1, _voteWeightA + _voteWeightB - 1));
    GCS.VoteType _voteTypeA = _randVoteType(_supportTypeA);

    // Mint and deposit.
    _mintGovAndDepositIntoFlexClient(_users[0], _voteWeightA);
    _mintGovAndDepositIntoFlexClient(_users[1], _voteWeightB);
    uint256 _initDepositWeight = token.balanceOf(address(flexClient));

    // Borrow from the flexClient, decreasing its token balance.
    vm.prank(_users[2]);
    flexClient.borrow(_borrowAmount);

    // Create the proposal.
    uint256 _proposalId = _createAndSubmitProposal();

    // Jump ahead to the proposal snapshot to lock in the flexClient's balance.
    _advanceTimeTo(governor.proposalSnapshot(_proposalId) + 1);
    uint256 _totalPossibleVotingWeight = token.balanceOf(address(flexClient));

    uint256 _fullVotingWeight = token.balanceOf(address(flexClient));
    assert(_fullVotingWeight < _initDepositWeight);
    assertEq(_fullVotingWeight, _voteWeightA + _voteWeightB - _borrowAmount);

    // Only user A expresses a vote.
    vm.prank(_users[0]);
    flexClient.expressVote(_proposalId, uint8(_voteTypeA));

    // Submit votes on behalf of the flexClient.
    flexClient.castVote(_proposalId);

    // Vote should be cast as a percentage of the depositer's expressed types, since
    // the actual weight is different from the deposit weight.
    (uint256 _againstVotes, uint256 _forVotes, uint256 _abstainVotes) =
      governor.proposalVotes(_proposalId);

    uint256 _expectedVotingWeightA = (_voteWeightA * _fullVotingWeight) / _initDepositWeight;
    uint256 _expectedVotingWeightB = (_voteWeightB * _fullVotingWeight) / _initDepositWeight;

    // The flexClient *could* have voted with this much weight.
    assertApproxEqAbs(
      _totalPossibleVotingWeight, _expectedVotingWeightA + _expectedVotingWeightB, 1
    );

    // Actually, though, the flexClient did not vote with all of the weight it could have.
    // VoterB's votes were never cast because he/she did not express his/her preference.
    assertApproxEqAbs(
      _againstVotes + _forVotes + _abstainVotes, // The total actual weight.
      _expectedVotingWeightA, // VoterB's weight has been abandoned, only A's is counted.
      1
    );

    // We assert the weight is within a range of 1 because scaled weights are sometimes floored.
    if (_voteTypeA == GCS.VoteType.For) assertApproxEqAbs(_forVotes, _expectedVotingWeightA, 1);
    if (_voteTypeA == GCS.VoteType.Against) {
      assertApproxEqAbs(_againstVotes, _expectedVotingWeightA, 1);
    }
    if (_voteTypeA == GCS.VoteType.Abstain) {
      assertApproxEqAbs(_abstainVotes, _expectedVotingWeightA, 1);
    }
  }

  function testFuzz_VotingWeightIsUnaffectedByDepositsAfterProposal(
    uint208 _voteWeightA,
    uint208 _voteWeightB,
    uint8 _supportTypeA
  ) public {
    // We need to do this to prevent:
    // "CompilerError: Stack too deep, try removing local variables."
    address[3] memory _users = [
      address(0xbeef), // userA
      address(0xbabe), // userB
      address(0xf005ba11) // userC
    ];

    // We need _voteWeightA + _voteWeightB < MAX_VOTES.
    _voteWeightA = uint208(bound(_voteWeightA, 1, MAX_VOTES - 2));
    _voteWeightB = uint208(bound(_voteWeightB, 1, MAX_VOTES - _voteWeightA - 1));
    GCS.VoteType _voteTypeA = _randVoteType(_supportTypeA);

    // Mint and deposit for just userA.
    _mintGovAndDepositIntoFlexClient(_users[0], _voteWeightA);
    uint256 _initDepositWeight = token.balanceOf(address(flexClient));

    // Create the proposal.
    uint256 _proposalId = _createAndSubmitProposal();

    // Jump ahead to the proposal snapshot to lock in the flexClient's balance.
    _advanceTimeTo(governor.proposalSnapshot(_proposalId) + 1);

    // Now mint and deposit for userB.
    _mintGovAndDepositIntoFlexClient(_users[1], _voteWeightB);

    uint256 _fullVotingWeight = token.balanceOf(address(flexClient));
    assert(_fullVotingWeight > _initDepositWeight);
    assertEq(_fullVotingWeight, _voteWeightA + _voteWeightB);

    // Only user A expresses a vote.
    vm.prank(_users[0]);
    flexClient.expressVote(_proposalId, uint8(_voteTypeA));

    // Submit votes on behalf of the flexClient.
    flexClient.castVote(_proposalId);

    (uint256 _againstVotes, uint256 _forVotes, uint256 _abstainVotes) =
      governor.proposalVotes(_proposalId);

    // We assert the weight is within a range of 1 because scaled weights are sometimes floored.
    if (_voteTypeA == GCS.VoteType.For) assertEq(_forVotes, _voteWeightA);
    if (_voteTypeA == GCS.VoteType.Against) assertEq(_againstVotes, _voteWeightA);
    if (_voteTypeA == GCS.VoteType.Abstain) assertEq(_abstainVotes, _voteWeightA);
  }

  function testFuzz_CanCallMultipleTimesForTheSameProposal(
    address _userA,
    address _userB,
    uint208 _voteWeightA,
    uint208 _voteWeightB
  ) public {
    _voteWeightA = uint208(bound(_voteWeightA, 1, type(uint120).max));
    _voteWeightB = uint208(bound(_voteWeightB, 1, type(uint120).max));

    vm.assume(_userA != address(flexClient));
    vm.assume(_userB != address(flexClient));
    vm.assume(_userA != _userB);

    // Deposit some funds.
    _mintGovAndDepositIntoFlexClient(_userA, _voteWeightA);
    _mintGovAndDepositIntoFlexClient(_userB, _voteWeightB);

    // Create the proposal.
    uint256 _proposalId = _createAndSubmitProposal();

    // users should now be able to express their votes on the proposal.
    vm.prank(_userA);
    flexClient.expressVote(_proposalId, uint8(GCS.VoteType.Against));

    (uint256 _againstVotesExpressed, uint256 _forVotesExpressed, uint256 _abstainVotesExpressed) =
      flexClient.proposalVotes(_proposalId);
    assertEq(_forVotesExpressed, 0);
    assertEq(_againstVotesExpressed, _voteWeightA);
    assertEq(_abstainVotesExpressed, 0);

    // The governor should have not recieved any votes yet.
    (uint256 _againstVotes, uint256 _forVotes, uint256 _abstainVotes) =
      governor.proposalVotes(_proposalId);
    assertEq(_forVotes, 0);
    assertEq(_againstVotes, 0);
    assertEq(_abstainVotes, 0);

    // Submit votes on behalf of the flexClient.
    flexClient.castVote(_proposalId);

    // Governor should now record votes for the flexClient.
    (_againstVotes, _forVotes, _abstainVotes) = governor.proposalVotes(_proposalId);
    assertEq(_forVotes, 0);
    assertEq(_againstVotes, _voteWeightA);
    assertEq(_abstainVotes, 0);

    // The second user now decides to express and cast.
    vm.prank(_userB);
    flexClient.expressVote(_proposalId, uint8(GCS.VoteType.Abstain));
    flexClient.castVote(_proposalId);

    // Governor should now record votes for both users.
    (_againstVotes, _forVotes, _abstainVotes) = governor.proposalVotes(_proposalId);
    assertEq(_forVotes, 0);
    assertEq(_againstVotes, _voteWeightA); // This should be unchanged!
    assertEq(_abstainVotes, _voteWeightB); // Second user's votes are now in.
  }

  function testFuzz_RevertWhen_NoVotesToCast(address _user, uint208 _voteWeight, uint8 _supportType)
    public
  {
    GCS.VoteType _voteType;
    (_voteWeight, _voteType) = _assumeSafeVoteParams(_user, _voteWeight, _supportType);

    // Deposit some funds.
    _mintGovAndDepositIntoFlexClient(_user, _voteWeight);

    // Create the proposal.
    uint256 _proposalId = _createAndSubmitProposal();

    // No one has expressed, there are no votes to cast.
    vm.expectRevert(FVC.FlexVotingClient__NoVotesExpressed.selector);
    flexClient.castVote(_proposalId);

    // _user expresses his/her vote on the proposal.
    vm.prank(_user);
    flexClient.expressVote(_proposalId, uint8(_voteType));

    // Submit votes on behalf of the flexClient.
    flexClient.castVote(_proposalId);

    // All votes have been cast, there's nothing new to send to the governor.
    vm.expectRevert(FVC.FlexVotingClient__NoVotesExpressed.selector);
    flexClient.castVote(_proposalId);
  }

  function testFuzz_RevertWhen_AfterVotingPeriod(
    address _user,
    uint208 _voteWeight,
    uint8 _supportType
  ) public {
    GCS.VoteType _voteType;
    (_voteWeight, _voteType) = _assumeSafeVoteParams(_user, _voteWeight, _supportType);

    // Deposit some funds.
    _mintGovAndDepositIntoFlexClient(_user, _voteWeight);

    // Create the proposal.
    uint256 _proposalId = _createAndSubmitProposal();

    // Express vote preference.
    vm.prank(_user);
    flexClient.expressVote(_proposalId, uint8(_voteType));

    // Jump ahead so that we're outside of the proposal's voting period.
    _advanceTimeTo(governor.proposalDeadline(_proposalId) + 1);
    IGovernor.ProposalState status = IGovernor.ProposalState(uint32(governor.state(_proposalId)));

    // We should not be able to castVote at this point.
    vm.expectRevert(
      abi.encodeWithSelector(
        IGovernor.GovernorUnexpectedProposalState.selector,
        _proposalId,
        status,
        bytes32(1 << uint8(IGovernor.ProposalState.Active))
      )
    );
    flexClient.castVote(_proposalId);
  }
}

abstract contract Borrow is FlexVotingClientTest {
  function testFuzz_UsersCanBorrowTokens(
    address _depositer,
    uint208 _depositAmount,
    address _borrower,
    uint208 _borrowAmount
  ) public {
    _depositAmount = _assumeSafeVoteParams(_depositer, _depositAmount);
    _borrowAmount = _assumeSafeVoteParams(_borrower, _borrowAmount);
    vm.assume(_depositAmount > _borrowAmount);

    // Deposit some funds.
    _mintGovAndDepositIntoFlexClient(_depositer, _depositAmount);

    // Borrow some funds.
    uint256 _initBalance = token.balanceOf(_borrower);
    vm.prank(_borrower);
    flexClient.borrow(_borrowAmount);

    // Tokens should have been transferred.
    assertEq(token.balanceOf(_borrower), _initBalance + _borrowAmount);
    assertEq(token.balanceOf(address(flexClient)), _depositAmount - _borrowAmount);

    // Borrow total has been tracked.
    assertEq(flexClient.borrowTotal(_borrower), _borrowAmount);

    // The deposit balance of the depositer should not have changed.
    assertEq(flexClient.deposits(_depositer), _depositAmount);

    _advanceTimeBy(1); // Advance so we can check the snapshot.

    // The total deposit snapshot should not have changed.
    assertEq(flexClient.getPastTotalBalance(_now() - 1), _depositAmount);
  }
}

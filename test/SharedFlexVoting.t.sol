// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console2} from "forge-std/Test.sol";
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
import {MockFlexVotingClient} from "test/mocks/MockFlexVotingClient.sol";
import {ProposalReceiverMock} from "test/mocks/ProposalReceiverMock.sol";
import {GovToken, TimestampGovToken} from "test/mocks/GovToken.sol";
import {FractionalGovernor} from "test/mocks/FractionalGovernor.sol";

abstract contract FlexVotingClientTest is Test {
  int256 MAX_UINT208 = int256(uint256(type(uint208).max));

  MockFlexVotingClient flexClient;
  ProposalReceiverMock receiver;

  GovToken token;
  FractionalGovernor governor;
  GovToken token2;
  FractionalGovernor governor2;
  GovToken token3;
  FractionalGovernor governor3;
  uint256 TOKEN_COUNT = 3; // Increment if adding another token to this contract.

  // This max is a limitation of GovernorCountingFractional's vote storage size.
  // See GovernorCountingFractional.ProposalVote struct.
  uint256 MAX_VOTES = type(uint128).max;

  // The highest valid vote type, represented as a uint256.
  uint256 MAX_VOTE_TYPE = uint256(type(GCS.VoteType).max);

  function setUp() public {
    // Base token and governor used by default in most tests.
    if (_timestampClock()) token = new TimestampGovToken();
    else token = new GovToken();
    vm.label(address(token), "token");
    governor = new FractionalGovernor("Governor", IVotes(token));
    vm.label(address(governor), "governor");

    _deployFlexClient(address(governor));
    vm.label(address(flexClient), "flexclient");

    receiver = new ProposalReceiverMock();
    vm.label(address(receiver), "receiver");

    // Used for multi-gov tests.
    if (_timestampClock()) token2 = new TimestampGovToken();
    else token2 = new GovToken();
    vm.label(address(token2), "token2");
    governor2 = new FractionalGovernor("Other Governor", IVotes(token2));
    vm.label(address(governor2), "governor2");
    flexClient.exposed_selfDelegate(IVotingToken(address(token2)));

    if (_timestampClock()) token3 = new TimestampGovToken();
    else token3 = new GovToken();
    vm.label(address(token3), "token3");
    governor3 = new FractionalGovernor("Other Governor", IVotes(token3));
    vm.label(address(governor3), "governor3");
    flexClient.exposed_selfDelegate(IVotingToken(address(token3)));
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

  function _mintAndApproveFlexClient(GovToken _token, address _user, uint208 _amount) public {
    vm.assume(_user != address(0));
    _token.exposed_mint(_user, _amount);
    vm.prank(_user);
    _token.approve(address(flexClient), type(uint256).max);
  }

  function _mintGovAndApproveFlexClient(address _user, uint208 _amount) public {
    _mintAndApproveFlexClient(token, _user, _amount);
  }

  function _mintGovAndDepositIntoFlexClient(address _user, uint208 _amount) internal {
    _mintGovAndApproveFlexClient(_user, _amount);
    vm.prank(_user);
    flexClient.deposit(_amount);
  }

  function _mintAndDepositIntoFlexClient(IVotingToken _token, address _address, uint208 _amount) internal {

    _mintAndDepositIntoFlexClient(GovToken(address(_token)), _address, _amount);
  }

  function _mintAndDepositIntoFlexClient(GovToken _token, address _address, uint208 _amount) internal {
    _mintAndApproveFlexClient(_token, _address, _amount);
    vm.prank(_address);
    flexClient.deposit(IVotingToken(address(_token)), _amount);
  }

  function _createAndSubmitProposal() internal returns (uint256 proposalId) {
    return _createAndSubmitProposal(governor);
  }

  function _createAndSubmitProposal(FractionalGovernor _governor) internal returns (uint256 proposalId) {
    return _createAndSubmitProposal(_governor, "mockReceiverFunction()");
  }

  function _createAndSubmitProposal(
    string memory _sig
  ) internal returns (uint256 proposalId) {
    return _createAndSubmitProposal(governor, _sig);
  }

  function _createAndSubmitProposal(
    FractionalGovernor _governor,
    string memory _sig
  ) internal returns (uint256 proposalId) {
    // Proposal will underflow if we're on the zero block
    if (_now() == 0) _advanceTimeBy(1);

    // Create a proposal
    bytes memory receiverCallData = abi.encodeWithSignature(_sig);
    address[] memory targets = new address[](1);
    uint256[] memory values = new uint256[](1);
    bytes[] memory calldatas = new bytes[](1);
    targets[0] = address(receiver);
    values[0] = 0; // No ETH will be sent.
    calldatas[0] = receiverCallData;

    // Submit the proposal.
    proposalId = _governor.propose(targets, values, calldatas, "A great proposal");
    assertEq(uint8(_governor.state(proposalId)), uint8(IGovernor.ProposalState.Pending));

    // Advance proposal to active state.
    _advanceTimeTo(_governor.proposalSnapshot(proposalId) + 1);
    assertEq(uint8(_governor.state(proposalId)), uint8(IGovernor.ProposalState.Active));
  }

  function _assumeSafeUser(address _user) internal view returns (address) {
    vm.assume(_user != address(flexClient));
    vm.assume(_user != address(0));
    return _user;
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

  function _randGov(uint256 _seed) public view returns (FractionalGovernor _gov) {
    if (_seed % TOKEN_COUNT == 0) return _gov = governor;
    if (_seed % TOKEN_COUNT == 1) return _gov = governor2;
    if (_seed % TOKEN_COUNT == 2) return _gov = governor3;
    revert("Governor was added without updating _randGov");
  }

  // Returns an alternate governor to the one returned by _randGov for the same seed.
  function _randGovAlt(uint256 _seed) public view returns (FractionalGovernor _gov) {
    _gov = _randGov((_seed % TOKEN_COUNT) + 1);
  }

  function _randToken(uint256 _seed) public view returns (GovToken _token) {
    if (_seed % TOKEN_COUNT == 0) return _token = token;
    if (_seed % TOKEN_COUNT == 1) return _token = token2;
    if (_seed % TOKEN_COUNT == 2) return _token = token3;
    revert("Token was added without updating _randToken");
  }

  // Returns an alternate token to the one returned by _randToken for the same seed.
  function _randTokenAlt(uint256 _seed) public view returns (GovToken _token) {
    _token = _randToken((_seed % TOKEN_COUNT) + 1);
  }

  function _randTokens(uint256 _seed) public view returns (IVotingToken _tokenA, IVotingToken _tokenB) {
    _tokenA = IVotingToken(address(_randToken(_seed)));
    _tokenB = IVotingToken(address(_randToken((_seed % TOKEN_COUNT) + 1)));
  }

  function _randGovernor(uint256 _seed) public view returns (FractionalGovernor _gov) {
    if (_seed % 3 == 0) _gov = governor;
    if (_seed % 3 == 1) _gov = governor2;
    if (_seed % 3 == 2) _gov = governor3;
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
  function testFuzz_ReturnsZeroForNonDepositors(address _user, uint256 _seed) public view {
    _assumeSafeUser(_user);
    GovToken _token = _randToken(_seed);
    assertEq(flexClient.exposed_rawBalanceOf(_token, _user), 0);
  }

  function testFuzz_IncreasesOnDeposit(address _user, uint208 _amount, uint256 _seed) public {
    _assumeSafeUser(_user);
    _amount = uint208(bound(_amount, 1, MAX_VOTES));
    GovToken _token = _randToken(_seed);

    // Deposit some tokens.
    _mintAndDepositIntoFlexClient(_token, _user, _amount);

    assertEq(flexClient.exposed_rawBalanceOf(_token, _user), _amount);
  }

  function testFuzz_DecreasesOnWithdrawal(address _user, uint208 _amount, uint256 _seed) public {
    _assumeSafeUser(_user);
    _amount = uint208(bound(_amount, 1, MAX_VOTES));
    GovToken _token = _randToken(_seed);

    // Deposit some tokens.
    _mintAndDepositIntoFlexClient(_token, _user, _amount);

    assertEq(flexClient.exposed_rawBalanceOf(_token, _user), _amount);

    vm.prank(_user);
    flexClient.withdraw(IVotingToken(address(_token)), _amount);
    assertEq(flexClient.exposed_rawBalanceOf(_token, _user), 0);
  }

  function testFuzz_UnaffectedByBorrow(
    uint256 _seed,
    address _user,
    uint208 _deposit,
    uint208 _borrow
  ) public {
    _assumeSafeUser(_user);
    _deposit = uint208(bound(_deposit, 1, MAX_VOTES));
    _borrow = uint208(bound(_borrow, 1, _deposit));
    GovToken _token = _randToken(_seed);

    // Deposit some gov.
    _mintAndDepositIntoFlexClient(_token, _user, _deposit);

    assertEq(flexClient.exposed_rawBalanceOf(_token, _user), _deposit);

    vm.prank(_user);
    flexClient.borrow(IVotingToken(address(_token)), _borrow);

    // Raw balance is unchanged.
    assertEq(flexClient.exposed_rawBalanceOf(_token, _user), _deposit);
  }

  function testFuzz_TracksMultipleDepositorsOnMultipleTokens(
    address _userA,
    address _userB,
    uint208 _amountA,
    uint208 _amountB,
    uint256 _seedA,
    uint256 _seedB
  ) public {
    _assumeSafeUser(_userA);
    _assumeSafeUser(_userB);
    vm.assume(_userA != _userB);
    _amountA = uint208(bound(_amountA, 1, MAX_VOTES));
    _amountB = uint208(bound(_amountB, 1, MAX_VOTES));
    GovToken _tokenA = _randToken(_seedA);
    GovToken _tokenB = _randToken(_seedB);

    // Deposit some tokens.
    _mintAndDepositIntoFlexClient(_tokenA, _userA, _amountA);
    _mintAndDepositIntoFlexClient(_tokenB, _userB, _amountB);

    assertEq(flexClient.exposed_rawBalanceOf(_tokenA, _userA), _amountA);
    assertEq(flexClient.exposed_rawBalanceOf(_tokenB, _userB), _amountB);
  }
}

// Contract name has a leading underscore for scopelint spec support.
abstract contract _CastVoteReasonString is FlexVotingClientTest {
  function testFuzz_ReturnsDescriptiveString(uint256 _seed) public {
    FractionalGovernor _governor = _randGovernor(_seed);
    assertEq(
      flexClient.exposed_castVoteReasonString(
        IFractionalGovernor(address(_governor))
      ),
      "rolled-up vote from governance token holders"
    );
  }
}

// Contract name has a leading underscore for scopelint spec support.
abstract contract _SelfDelegate is FlexVotingClientTest {
  function testFuzz_SetsClientAsTheDelegate(uint256 _seed, address _delegatee) public {
    vm.assume(_delegatee != address(0));
    vm.assume(_delegatee != address(flexClient));
    GovToken _token = _randToken(_seed);

    // We self-delegate in the constructor, so we need to first un-delegate for
    // this test to be meaningful.
    vm.prank(address(flexClient));
    _token.delegate(_delegatee);
    assertEq(_token.delegates(address(flexClient)), _delegatee);

    flexClient.exposed_selfDelegate(IVotingToken(address(_token)));
    assertEq(_token.delegates(address(flexClient)), address(flexClient));
  }

  function testFuzz_DifferentiatesBetweenTokens(uint256 _seed, address _delegatee) public {
    vm.assume(_delegatee != address(0));
    vm.assume(_delegatee != address(flexClient));
    GovToken _tokenA = _randToken(_seed);
    GovToken _tokenB = _randTokenAlt(_seed);

    // We self-delegate in the constructor, so we need to first un-delegate for
    // this test to be meaningful.
    vm.startPrank(address(flexClient));
    _tokenA.delegate(_delegatee);
    _tokenB.delegate(_delegatee);
    vm.stopPrank();
    assertEq(_tokenA.delegates(address(flexClient)), _delegatee);
    assertEq(_tokenB.delegates(address(flexClient)), _delegatee);

    assertEq(_tokenA.delegates(address(flexClient)), address(flexClient));
    assertEq(_tokenB.delegates(address(flexClient)), _delegatee);
  }
}

// Contract name has a leading underscore for scopelint spec support.
abstract contract _CheckpointVoteWeightOf is FlexVotingClientTest {
  function testFuzz_StoresTheRawBalanceWithTheTimepoint(
    uint256 _seed,
    address _user,
    uint208 _amount,
    uint48 _future
  ) public {
    vm.assume(_user != address(flexClient));
    _future = uint48(bound(_future, _now() + 1, type(uint48).max));
    _amount = uint208(bound(_amount, 1, MAX_VOTES));
    IVotingToken _token = IVotingToken(address(_randToken(_seed)));
    uint48 _past = _now();

    _advanceTimeTo(_future);
    flexClient.exposed_setDeposits(_token, _user, _amount);
    int256 _delta = int256(uint256(_amount));
    flexClient.exposed_checkpointVoteWeightOf(_token, _user, _delta);

    assertEq(flexClient.getPastVoteWeight(_token, _user, _past), 0);
    assertEq(flexClient.getPastVoteWeight(_token, _user, _future), _amount);
  }

  function testFuzz_DifferentiatesBetweenTokens(
    uint256 _seed,
    address _user,
    uint208 _amountA,
    uint208 _amountB,
    uint48 _future
  ) public {
    vm.assume(_user != address(flexClient));
    _future = uint48(bound(_future, _now() + 1, type(uint48).max));
    _amountA = uint208(bound(_amountA, 1, MAX_VOTES));
    _amountB = uint208(bound(_amountB, 1, MAX_VOTES));
    (IVotingToken _tokenA, IVotingToken _tokenB) = _randTokens(_seed);
    uint48 _past = _now();

    _advanceTimeTo(_future);
    flexClient.exposed_setDeposits(_tokenA, _user, _amountA);
    int256 _delta = int256(uint256(_amountA));
    flexClient.exposed_checkpointVoteWeightOf(_tokenA, _user, _delta);

    flexClient.exposed_setDeposits(_tokenB, _user, _amountB);
    _delta = int256(uint256(_amountB));
    flexClient.exposed_checkpointVoteWeightOf(_tokenB, _user, _delta);

    assertEq(flexClient.getPastVoteWeight(_tokenA, _user, _past), 0);
    assertEq(flexClient.getPastVoteWeight(_tokenA, _user, _future), _amountA);
    assertEq(flexClient.getPastVoteWeight(_tokenB, _user, _past), 0);
    assertEq(flexClient.getPastVoteWeight(_tokenB, _user, _future), _amountB);
  }
}

abstract contract _ApplyDeltaToCheckpoint is FlexVotingClientTest {
  function testFuzz_VoteWeightCheckpointIsUpdated(
    address _user,
    uint256 _seed,
    int256 _delta,
    uint208 _balance
  ) public {
    vm.assume(_user != address(flexClient));
    int256 _balanceInt = int256(uint256(_balance));
    _delta = bound(
      _delta,
      // |_delta| may not be greater than _balance.
      -_balanceInt,
      // _delta may not be greater than a uint208 when added to _balance.
      MAX_UINT208 - _balanceInt
    );

    IVotingToken _token = IVotingToken(address(_randToken(_seed)));

    flexClient.exposed_checkpointVoteWeightOf(_token, _user, _balanceInt);
    _advanceTimeBy(1); // Set the checkpoint.

    flexClient.exposed_applyDeltaToAddressCheckpoint(_token, _user, _delta);
    _advanceTimeBy(1); // Set new checkpoint.

    assertEq(
      flexClient.getPastVoteWeight(_token, _user, _now()),
      uint256(_balanceInt + _delta)
    );
  }

  function testFuzz_RevertIf_CheckpointWouldExceedUint208(
    address _user,
    uint256 _seed,
    int256 _delta,
    uint208 _balance
  ) public {
    vm.assume(_user != address(flexClient));
    int256 _balanceInt = int256(uint256(_balance));
    _delta = bound(
      _delta,
      // _delta must be greater than a uint208 when added to _balance.
      MAX_UINT208 - _balanceInt + 1,
      type(int256).max
    );
    IVotingToken _token = IVotingToken(address(_randToken(_seed)));

    flexClient.exposed_checkpointVoteWeightOf(_token, _user, _balanceInt);
    _advanceTimeBy(1); // Set the checkpoint.

    vm.expectRevert();
    flexClient.exposed_applyDeltaToAddressCheckpoint(_token, _user, _delta);
  }

  function test_RevertIf_CheckpointWouldBeNegative0() public {
    testFuzz_RevertIf_CheckpointWouldBeNegative(
      address(0xBEEF),
      0,
      -int256(uint256(type(uint208).max) + 1), // delta.
      uint208(type(uint208).max) // balance.
    );
  }

  function test_RevertIf_CheckpointWouldBeNegative1() public {
    testFuzz_RevertIf_CheckpointWouldBeNegative(
      address(0xBEEF),
      0,
      type(int256).min, // delta.
      uint208(type(uint208).max) // balance.
    );
  }

  function test_RevertIf_CheckpointWouldBeNegative2() public {
    testFuzz_RevertIf_CheckpointWouldBeNegative(
      address(0xBEEF),
      0,
      type(int256).min, // delta.
      0 // balance.
    );
  }

  function test_RevertIf_CheckpointWouldBeNegative3() public {
    testFuzz_RevertIf_CheckpointWouldBeNegative(
      address(0xBEEF),
      0,
      int256(-1), // delta.
      0 // balance.
    );
  }

  function testFuzz_RevertIf_CheckpointWouldBeNegative(
    address _user,
    uint256 _seed,
    int256 _delta,
    uint208 _balance
  ) public {
    vm.assume(_user != address(flexClient));
    // Math.abs(delta) must be > balance for the concerning scenario to arise.
    _delta = bound(_delta, type(int256).min, -int256(uint256(_balance) + 1));
    IVotingToken _token = IVotingToken(address(_randToken(_seed)));

    flexClient.exposed_checkpointVoteWeightOf(_token, _user, int256(uint256(_balance)));
    _advanceTimeBy(1); // Set the checkpoint.

    vm.expectPartialRevert(SafeCast.SafeCastOverflowedUintDowncast.selector);
    flexClient.exposed_applyDeltaToAddressCheckpoint(_token, _user, _delta);
  }
}

abstract contract _CheckpointTotalVoteWeight is FlexVotingClientTest {
  function testFuzz_writesACheckpointAtClockTime(uint256 _seed, int256 _value, uint48 _timepoint) public {
    _timepoint = uint48(bound(_timepoint, 1, type(uint48).max - 1));
    _value = bound(_value, 1, MAX_UINT208);
    IVotingToken _token = IVotingToken(address(_randToken(_seed)));
    assertEq(flexClient.exposed_latestTotalWeight(_token), 0);

    _advanceTimeTo(_timepoint);
    flexClient.exposed_checkpointTotalVoteWeight(_token, _value);
    _advanceTimeBy(1);

    assertEq(flexClient.getPastTotalVoteWeight(_token, _timepoint), uint256(_value));
    assertEq(flexClient.exposed_latestTotalWeight(_token), uint256(_value));
  }

  function testFuzz_checkpointsTheTotalBalanceDeltaAtClockTime(
    uint256 _seed,
    int256 _initBalance,
    int256 _delta,
    uint48 _timepoint
  ) public {
    _timepoint = uint48(bound(_timepoint, 1, type(uint48).max - 1));
    _initBalance = bound(_initBalance, 1, MAX_UINT208 - 1);
    _delta = bound(_delta, -_initBalance, MAX_UINT208 - _initBalance);
    IVotingToken _token = IVotingToken(address(_randToken(_seed)));
    flexClient.exposed_checkpointTotalVoteWeight(_token, _initBalance);

    _advanceTimeTo(_timepoint);
    flexClient.exposed_checkpointTotalVoteWeight(_token, _delta);
    _advanceTimeBy(1);

    assertEq(flexClient.getPastTotalVoteWeight(_token, _timepoint), uint256(_initBalance + _delta));
  }

  function testFuzz_RevertIf_withdrawalFromZero(uint256 _seed, int256 _withdraw) public {
    _withdraw = bound(_withdraw, type(int208).min, -1);
    IVotingToken _token = IVotingToken(address(_randToken(_seed)));
    vm.expectRevert();
    flexClient.exposed_checkpointTotalVoteWeight(_token, _withdraw);
  }

  function testFuzz_RevertIf_withdrawalExceedsDeposit(uint256 _seed, int256 _deposit, int256 _withdraw) public {
    _deposit = bound(_deposit, 1, type(int208).max - 1);
    _withdraw = bound(_withdraw, type(int208).min, (-1 * _deposit) - 1);
    IVotingToken _token = IVotingToken(address(_randToken(_seed)));

    flexClient.exposed_checkpointTotalVoteWeight(_token, _deposit);
    vm.expectRevert();
    flexClient.exposed_checkpointTotalVoteWeight(_token, _withdraw);
  }

  function testFuzz_RevertIf_depositsOverflow(uint256 _seed, int256 _deposit1, int256 _deposit2) public {
    int256 _max = int256(uint256(type(uint208).max));
    _deposit1 = bound(_deposit1, 1, _max);
    _deposit2 = bound(_deposit2, 1 + _max - _deposit1, _max);
    IVotingToken _token = IVotingToken(address(_randToken(_seed)));

    flexClient.exposed_checkpointTotalVoteWeight(_token, _deposit1);
    vm.expectRevert();
    flexClient.exposed_checkpointTotalVoteWeight(_token, _deposit2);
  }

  function testFuzz_DifferentiatesBetweenTokens(
    uint256 _seed,
    int256 _amountA,
    int256 _amountB,
    uint48 _future
  ) public {
    _future = uint48(bound(_future, _now() + 1, type(uint48).max));
    _amountA = bound(_amountA, 0, MAX_UINT208);
    _amountB = bound(_amountB, 0, MAX_UINT208);
    (IVotingToken _tokenA, IVotingToken _tokenB) = _randTokens(_seed);
    uint48 _past = _now();

    _advanceTimeTo(_future);
    flexClient.exposed_checkpointTotalVoteWeight(_tokenA, _amountA);
    flexClient.exposed_checkpointTotalVoteWeight(_tokenB, _amountB);

    assertEq(flexClient.getPastTotalVoteWeight(_tokenA, _past), 0);
    assertEq(flexClient.getPastTotalVoteWeight(_tokenA, _future), uint256(_amountA));
    assertEq(flexClient.getPastTotalVoteWeight(_tokenB, _past), 0);
    assertEq(flexClient.getPastTotalVoteWeight(_tokenB, _future), uint256(_amountB));
  }
}

abstract contract GetPastVoteWeight is FlexVotingClientTest {
  function testFuzz_ReturnsZeroForUsersWithoutDeposits(
    uint256 _seed,
    address _depositor,
    address _nonDepositor,
    uint208 _amount
  ) public {
    vm.assume(_depositor != address(flexClient));
    vm.assume(_nonDepositor != address(flexClient));
    vm.assume(_nonDepositor != _depositor);
    _amount = uint208(bound(_amount, 1, MAX_VOTES));

    IVotingToken _token = IVotingToken(address(_randToken(_seed)));

    _advanceTimeBy(1);
    assertEq(flexClient.getPastVoteWeight(_token, _depositor, 0), 0);
    assertEq(flexClient.getPastVoteWeight(_token, _nonDepositor, 0), 0);

    _mintAndDepositIntoFlexClient(_token, _depositor, _amount);
    _advanceTimeBy(1);

    assertEq(flexClient.getPastVoteWeight(_token, _depositor, _now() - 1), _amount);
    assertEq(flexClient.getPastVoteWeight(_token, _nonDepositor, _now() - 1), 0);
  }

  function testFuzz_ReturnsCurrentValueForFutureTimepoints(
    uint256 _seed,
    address _user,
    uint208 _amount,
    uint48 _timepoint
  ) public {
    vm.assume(_user != address(flexClient));
    _timepoint = uint48(bound(_timepoint, _now() + 1, type(uint48).max));
    _amount = uint208(bound(_amount, 1, MAX_VOTES));
    IVotingToken _token = IVotingToken(address(_randToken(_seed)));

    _mintAndDepositIntoFlexClient(_token, _user, _amount);

    assertEq(flexClient.getPastVoteWeight(_token, _user, _now()), _amount);
    assertEq(flexClient.getPastVoteWeight(_token, _user, _timepoint), _amount);

    _advanceTimeTo(_timepoint);

    assertEq(flexClient.getPastVoteWeight(_token, _user, _now()), _amount);
  }

  function testFuzz_ReturnsUserBalanceAtAGivenTimepoint(
    uint256 _seed,
    address _user,
    uint208 _amountA,
    uint208 _amountB,
    uint48 _timepoint
  ) public {
    vm.assume(_user != address(flexClient));
    _timepoint = uint48(bound(_timepoint, _now() + 1, type(uint48).max));
    _amountA = uint208(bound(_amountA, 1, MAX_VOTES));
    _amountB = uint208(bound(_amountB, 0, MAX_VOTES - _amountA));
    IVotingToken _token = IVotingToken(address(_randToken(_seed)));

    uint48 _initTimepoint = _now();
    _mintAndDepositIntoFlexClient(_token, _user, _amountA);

    _advanceTimeTo(_timepoint);

    _mintAndDepositIntoFlexClient(_token, _user, _amountB);
    _advanceTimeBy(1);

    uint48 _zeroTimepoint = 0;
    assertEq(flexClient.getPastVoteWeight(_token, _user, _zeroTimepoint), 0);
    assertEq(flexClient.getPastVoteWeight(_token, _user, _initTimepoint), _amountA);
    assertEq(flexClient.getPastVoteWeight(_token, _user, _timepoint), _amountA + _amountB);
  }

  function testFuzz_TracksMultipleTokenBalancesForSingleUserAtMultipleTimepoints(
    uint256 _seed,
    address _user,
    uint208 _amountA1,
    uint208 _amountA2,
    uint208 _amountB1,
    uint208 _amountB2,
    uint48 _timepoint
  ) public {
    vm.assume(_user != address(flexClient));
    _timepoint = uint48(bound(_timepoint, _now() + 1, type(uint48).max));

    _amountA1 = uint208(bound(_amountA1, 1, MAX_VOTES));
    _amountA2 = uint208(bound(_amountA2, 0, MAX_VOTES - _amountA1));
    _amountB1 = uint208(bound(_amountB1, 1, MAX_VOTES));
    _amountB2 = uint208(bound(_amountB2, 0, MAX_VOTES - _amountB1));

    (IVotingToken _tokenA, IVotingToken _tokenB) = _randTokens(_seed);

    uint48 _initTimepoint = _now();
    _mintAndDepositIntoFlexClient(_tokenA, _user, _amountA1);
    _mintAndDepositIntoFlexClient(_tokenB, _user, _amountB1);

    _advanceTimeTo(_timepoint);

    _mintAndDepositIntoFlexClient(_tokenA, _user, _amountA2);
    _mintAndDepositIntoFlexClient(_tokenB, _user, _amountB2);
    _advanceTimeBy(1);

    uint48 _zeroTimepoint = 0;
    assertEq(flexClient.getPastVoteWeight(_tokenA, _user, _zeroTimepoint), 0);
    assertEq(flexClient.getPastVoteWeight(_tokenB, _user, _zeroTimepoint), 0);
    assertEq(flexClient.getPastVoteWeight(_tokenA, _user, _initTimepoint), _amountA1);
    assertEq(flexClient.getPastVoteWeight(_tokenB, _user, _initTimepoint), _amountB1);
    assertEq(flexClient.getPastVoteWeight(_tokenA, _user, _timepoint), _amountA1 + _amountA2);
    assertEq(flexClient.getPastVoteWeight(_tokenB, _user, _timepoint), _amountB1 + _amountB2);
  }

  struct TokenAmounts {
    uint208 x1;
    uint208 x2;
    uint208 y1;
    uint208 y2;
  }

  function testFuzz_TracksMultipleTokenBalancesForMultipleUsersAtMultipleTimepoints(
    uint256 _seed,
    address _userA,
    address _userB,
    TokenAmounts memory _amtA,
    TokenAmounts memory _amtB,
    uint48 _timepoint
  ) public {
    vm.assume(_userA != address(flexClient));
    vm.assume(_userB != address(flexClient));
    vm.assume(_userA != _userB);
    _timepoint = uint48(bound(_timepoint, _now() + 1, type(uint48).max));

    _amtA.x1 = uint208(bound(_amtA.x1, 0, MAX_VOTES));
    _amtA.x2 = uint208(bound(_amtA.x2, 0, MAX_VOTES - _amtA.x1));
    _amtB.x1 = uint208(bound(_amtA.x1, 0, MAX_VOTES - _amtA.x1 - _amtA.x2));
    _amtB.x2 = uint208(bound(_amtA.x2, 0, MAX_VOTES - _amtA.x1 - _amtA.x2 - _amtB.x1));

    _amtA.y1 = uint208(bound(_amtA.y1, 0, MAX_VOTES));
    _amtA.y2 = uint208(bound(_amtA.y2, 0, MAX_VOTES - _amtA.y1));
    _amtB.y1 = uint208(bound(_amtA.y1, 0, MAX_VOTES - _amtA.y1 - _amtA.y2));
    _amtB.y2 = uint208(bound(_amtA.y2, 0, MAX_VOTES - _amtA.y1 - _amtA.y2 - _amtB.y1));

    (IVotingToken _tokenX, IVotingToken _tokenY) = _randTokens(_seed);

    uint48 _initTimepoint = _now();
    _mintAndDepositIntoFlexClient(_tokenX, _userA, _amtA.x1);
    _mintAndDepositIntoFlexClient(_tokenY, _userA, _amtA.y1);
    _mintAndDepositIntoFlexClient(_tokenX, _userB, _amtB.x1);
    _mintAndDepositIntoFlexClient(_tokenY, _userB, _amtB.y1);

    _advanceTimeTo(_timepoint);

    _mintAndDepositIntoFlexClient(_tokenX, _userA, _amtA.x2);
    _mintAndDepositIntoFlexClient(_tokenY, _userA, _amtA.y2);
    _mintAndDepositIntoFlexClient(_tokenX, _userB, _amtB.x2);
    _mintAndDepositIntoFlexClient(_tokenY, _userB, _amtB.y2);
    _advanceTimeBy(1);

    uint48 _zeroTimepoint = 0;
    assertEq(flexClient.getPastVoteWeight(_tokenX, _userA, _zeroTimepoint), 0);
    assertEq(flexClient.getPastVoteWeight(_tokenY, _userA, _zeroTimepoint), 0);
    assertEq(flexClient.getPastVoteWeight(_tokenX, _userB, _zeroTimepoint), 0);
    assertEq(flexClient.getPastVoteWeight(_tokenY, _userB, _zeroTimepoint), 0);

    assertEq(flexClient.getPastVoteWeight(_tokenX, _userA, _initTimepoint), _amtA.x1);
    assertEq(flexClient.getPastVoteWeight(_tokenY, _userA, _initTimepoint), _amtA.y1);
    assertEq(flexClient.getPastVoteWeight(_tokenX, _userB, _initTimepoint), _amtB.x1);
    assertEq(flexClient.getPastVoteWeight(_tokenY, _userB, _initTimepoint), _amtB.y1);

    assertEq(flexClient.getPastVoteWeight(_tokenX, _userA, _timepoint), _amtA.x1 + _amtA.x2);
    assertEq(flexClient.getPastVoteWeight(_tokenY, _userA, _timepoint), _amtA.y1 + _amtA.y2);
    assertEq(flexClient.getPastVoteWeight(_tokenX, _userB, _timepoint), _amtB.x1 + _amtB.x2);
    assertEq(flexClient.getPastVoteWeight(_tokenY, _userB, _timepoint), _amtB.y1 + _amtB.y2);
  }
}

abstract contract GetPastTotalVoteWeight is FlexVotingClientTest {
  function testFuzz_ReturnsZeroWithoutDeposits(
    uint256 _seed,
    uint48 _future
  ) public view {
    IVotingToken _token = IVotingToken(address(_randToken(_seed)));
    uint48 _zeroTimepoint = 0;
    assertEq(flexClient.getPastTotalVoteWeight(_token, _zeroTimepoint), 0);
    assertEq(flexClient.getPastTotalVoteWeight(_token, _future), 0);
  }

  function testFuzz_ReturnsCurrentValueForFutureTimepoints(
    uint256 _seed,
    address _user,
    uint208 _amount,
    uint48 _future
  ) public {
    vm.assume(_user != address(flexClient));
    _future = uint48(bound(_future, _now() + 1, type(uint48).max));
    _amount = uint208(bound(_amount, 1, MAX_VOTES));
    IVotingToken _token = IVotingToken(address(_randToken(_seed)));

    _mintAndDepositIntoFlexClient(_token, _user, _amount);

    assertEq(flexClient.getPastTotalVoteWeight(_token, _now()), _amount);
    assertEq(flexClient.getPastTotalVoteWeight(_token, _future), _amount);

    _advanceTimeTo(_future);

    assertEq(flexClient.getPastTotalVoteWeight(_token, _now()), _amount);
  }

  function testFuzz_SumsAllUserDeposits(
    uint256 _seed,
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
    IVotingToken _token = IVotingToken(address(_randToken(_seed)));

    _mintAndDepositIntoFlexClient(_token, _userA, _amountA);
    _mintAndDepositIntoFlexClient(_token, _userB, _amountB);

    _advanceTimeBy(1);

    assertEq(flexClient.getPastTotalVoteWeight(_token, _now()), _amountA + _amountB);
  }

  function testFuzz_ReturnsTotalDepositsAtAGivenTimepoint(
    uint256 _seed,
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
    IVotingToken _token = IVotingToken(address(_randToken(_seed)));

    assertEq(flexClient.getPastTotalVoteWeight(_token, _now()), 0);

    _mintAndDepositIntoFlexClient(_token, _userA, _amountA);
    _advanceTimeTo(_future);
    _mintAndDepositIntoFlexClient(_token, _userB, _amountB);

    assertEq(flexClient.getPastTotalVoteWeight(_token, _now() - _future + 1), _amountA);
    assertEq(flexClient.getPastTotalVoteWeight(_token, _now()), _amountA + _amountB);
  }

  struct TokenAmounts {
    uint208 x1;
    uint208 x2;
    uint208 y1;
    uint208 y2;
  }

  function testFuzz_DistinguishesBetweenTokensAtAGivenTimepoint(
    uint256 _seed,
    TokenAmounts memory _amt,
    address _userA,
    address _userB,
    uint48 _future
  ) public {
    vm.assume(_userA != address(flexClient));
    vm.assume(_userB != address(flexClient));
    vm.assume(_userA != _userB);
    uint48 _initTimepoint = _now() + 1;
    _future = uint48(bound(_future, _initTimepoint + 1, type(uint48).max));

    _amt.x1 = uint208(bound(_amt.x1, 0, MAX_VOTES));
    _amt.x2 = uint208(bound(_amt.x2, 0, MAX_VOTES - _amt.x1));
    _amt.y1 = uint208(bound(_amt.y1, 0, MAX_VOTES));
    _amt.y2 = uint208(bound(_amt.y2, 0, MAX_VOTES - _amt.y1));

    (IVotingToken _tokenX, IVotingToken _tokenY) = _randTokens(_seed);

    _mintAndDepositIntoFlexClient(_tokenX, _userA, _amt.x1);
    _mintAndDepositIntoFlexClient(_tokenY, _userB, _amt.y1);

    _advanceTimeTo(_future);

    // Switch up users and amounts.
    _mintAndDepositIntoFlexClient(_tokenX, _userB, _amt.x2);
    _mintAndDepositIntoFlexClient(_tokenY, _userA, _amt.y2);

    uint48 _zeroTimepoint = 0;
    assertEq(flexClient.getPastTotalVoteWeight(_tokenX, _zeroTimepoint), 0);
    assertEq(flexClient.getPastTotalVoteWeight(_tokenY, _zeroTimepoint), 0);
    assertEq(flexClient.getPastTotalVoteWeight(_tokenX, _initTimepoint), _amt.x1);
    assertEq(flexClient.getPastTotalVoteWeight(_tokenY, _initTimepoint), _amt.y1);
    assertEq(flexClient.getPastTotalVoteWeight(_tokenX, _future), _amt.x1 + _amt.x2);
    assertEq(flexClient.getPastTotalVoteWeight(_tokenY, _future), _amt.y1 + _amt.y2);
  }
}

abstract contract Withdraw is FlexVotingClientTest {
  function testFuzz_UserCanWithdrawGovTokens(
    uint256 _seed,
    address _lender,
    address _borrower,
    uint208 _amount
  ) public {
    _amount = uint208(bound(_amount, 0, type(uint208).max));
    vm.assume(_lender != address(flexClient));
    vm.assume(_borrower != address(flexClient));
    vm.assume(_borrower != address(0));
    vm.assume(_lender != _borrower);

    IVotingToken _token = IVotingToken(address(_randToken(_seed)));

    uint256 _initBalance = GovToken(address(_token)).balanceOf(_borrower);
    assertEq(flexClient.deposits(_token, _borrower), 0);
    assertEq(flexClient.borrowTotal(_token, _borrower), 0);

    _mintAndDepositIntoFlexClient(_token, _lender, _amount);
    assertEq(flexClient.deposits(_token, _lender), _amount);

    // Borrow the funds.
    vm.prank(_borrower);
    flexClient.borrow(_token, _amount);

    assertEq(GovToken(address(_token)).balanceOf(_borrower), _initBalance + _amount);
    assertEq(flexClient.borrowTotal(_token, _borrower), _amount);

    // Deposit totals are unaffected.
    assertEq(flexClient.deposits(_token, _lender), _amount);
    assertEq(flexClient.deposits(_token, _borrower), 0);
  }

  function testFuzz_UserCannotWithdrawFundsIfNoneHaveBeenLentInThatToken(
    uint256 _seed,
    address _lender,
    address _borrower,
    uint208 _amount
  ) public {
    _amount = uint208(bound(_amount, 1, type(uint208).max));
    vm.assume(_lender != address(flexClient));
    vm.assume(_borrower != address(flexClient));
    vm.assume(_borrower != address(0));
    vm.assume(_lender != _borrower);

    (IVotingToken _tokenA, IVotingToken _tokenB) = _randTokens(_seed);

    assertEq(flexClient.deposits(_tokenA, _borrower), 0);
    assertEq(flexClient.deposits(_tokenB, _borrower), 0);
    assertEq(flexClient.borrowTotal(_tokenA, _borrower), 0);
    assertEq(flexClient.borrowTotal(_tokenB, _borrower), 0);

    // Lend tokenA.
    _mintAndDepositIntoFlexClient(_tokenA, _lender, _amount);
    assertEq(flexClient.deposits(_tokenA, _lender), _amount);

    // Attempt to borrow tokenB
    vm.expectRevert();
    vm.prank(_borrower);
    flexClient.borrow(_tokenB, _amount);

    // Borrower should not have recieved any funds (because there weren't funds
    // to send).
    assertEq(GovToken(address(_tokenB)).balanceOf(_borrower), 0);
  }

  // `borrow`s affects on vote weights are tested in Vote contract below.
}

abstract contract Deposit is FlexVotingClientTest {
  function testFuzz_UserCanDepositTokens(
    uint256 _seed,
    address _user,
    uint208 _amount
  ) public {
    _amount = uint208(bound(_amount, 0, type(uint208).max));
    vm.assume(_user != address(flexClient));

    IVotingToken _token = IVotingToken(address(_randToken(_seed)));
    GovToken _govToken = GovToken(address(_token));

    uint256 _initBalance = _govToken.balanceOf(_user);
    assertEq(flexClient.deposits(_token, _user), 0);

    _mintAndDepositIntoFlexClient(_token, _user, _amount);

    assertEq(_govToken.balanceOf(address(flexClient)), _amount);
    assertEq(_govToken.balanceOf(_user), _initBalance);
    assertEq(_govToken.getVotes(address(flexClient)), _amount);

    // Confirm internal accounting has updated.
    assertEq(flexClient.deposits(_token, _user), _amount);
  }

  function testFuzz_MultipleTokensCanBeDeposited(
    uint256 _seed,
    address _user,
    uint208 _amountA,
    uint208 _amountB
  ) public {
    _amountA = uint208(bound(_amountA, 0, type(uint208).max));
    _amountB = uint208(bound(_amountB, 0, type(uint208).max));
    vm.assume(_user != address(flexClient));

    (IVotingToken _tokenA, IVotingToken _tokenB) = _randTokens(_seed);

    assertEq(flexClient.deposits(_tokenA, _user), 0);
    assertEq(flexClient.deposits(_tokenB, _user), 0);

    _mintAndDepositIntoFlexClient(_tokenA, _user, _amountA);
    _mintAndDepositIntoFlexClient(_tokenB, _user, _amountB);

    // Confirm internal accounting has differentiated the tokens.
    assertEq(flexClient.deposits(_tokenA, _user), _amountA);
    assertEq(flexClient.deposits(_tokenB, _user), _amountB);
  }

  function testFuzz_DepositsAreCheckpointed(
    uint256 _seed,
    address _user,
    uint208 _amountA,
    uint208 _amountB,
    uint24 _depositDelay
  ) public {
    _amountA = uint208(bound(_amountA, 1, MAX_VOTES));
    _amountB = uint208(bound(_amountB, 0, MAX_VOTES - _amountA));

    IVotingToken _token = IVotingToken(address(_randToken(_seed)));

    // Deposit some gov.
    _mintAndDepositIntoFlexClient(_token, _user, _amountA);
    assertEq(flexClient.deposits(_token, _user), _amountA);

    _advanceTimeBy(1); // Advance so that we can look at checkpoints.

    // We can still retrieve the user's balance at the given time.
    uint256 _checkpoint1 = _now() - 1;
    assertEq(
      flexClient.getPastVoteWeight(_token, _user, _checkpoint1),
      _amountA,
      "user's first deposit was not properly checkpointed"
    );

    uint256 _checkpoint2 = _now() + _depositDelay;
    _advanceTimeTo(_checkpoint2);

    // Deposit some more.
    _mintAndDepositIntoFlexClient(_token, _user, _amountB);
    assertEq(flexClient.deposits(_token, _user), _amountA + _amountB);

    _advanceTimeBy(1); // Advance so that we can look at checkpoints.

    assertEq(
      flexClient.getPastVoteWeight(_token, _user, _checkpoint1),
      _amountA,
      "user's first deposit was not properly checkpointed"
    );
    assertEq(
      flexClient.getPastVoteWeight(_token, _user, _checkpoint2),
      _amountA + _amountB,
      "user's second deposit was not properly checkpointed"
    );
  }
}

abstract contract ExpressVote is FlexVotingClientTest {
  function testFuzz_IncrementsInternalAccouting(
    uint256 _seed,
    address _user,
    uint208 _voteWeight,
    uint8 _supportType
  ) public {
    GCS.VoteType _voteType;
    (_voteWeight, _voteType) = _assumeSafeVoteParams(_user, _voteWeight, _supportType);
    // Cast to avoid having to repeatedly do so below.
    FractionalGovernor _governor = _randGov(_seed);
    IFractionalGovernor _iGovernor = IFractionalGovernor(address(_governor));

    IVotingToken _token = IVotingToken(address(_governor.token()));

    // Deposit some funds.
    _mintAndDepositIntoFlexClient(_token, _user, _voteWeight);

    // Create the proposal.
    uint256 _proposalId = _createAndSubmitProposal(_governor);

    // _user should now be able to express his/her vote on the proposal.
    vm.prank(_user);
    flexClient.expressVote(_iGovernor, _proposalId, uint8(_voteType));
    (uint256 _againstVotesExpressed, uint256 _forVotesExpressed, uint256 _abstainVotesExpressed) =
      flexClient.proposalVotes(_iGovernor, _proposalId);
    assertEq(_forVotesExpressed, _voteType == GCS.VoteType.For ? _voteWeight : 0);
    assertEq(_againstVotesExpressed, _voteType == GCS.VoteType.Against ? _voteWeight : 0);
    assertEq(_abstainVotesExpressed, _voteType == GCS.VoteType.Abstain ? _voteWeight : 0);

    // No votes have been cast yet.
    (uint256 _againstVotes, uint256 _forVotes, uint256 _abstainVotes) =
      _governor.proposalVotes(_proposalId);
    assertEq(_forVotes, 0);
    assertEq(_againstVotes, 0);
    assertEq(_abstainVotes, 0);
  }

  function testFuzz_RevertWhen_DepositingAfterProposal(
    uint256 _seed,
    address _user,
    uint208 _voteWeight,
    uint8 _supportType
  ) public {
    GCS.VoteType _voteType;
    (_voteWeight, _voteType) = _assumeSafeVoteParams(_user, _voteWeight, _supportType);

    FractionalGovernor _governor = _randGov(_seed);
    IVotingToken _token = IVotingToken(address(_governor.token()));
    // Cast to avoid having to repeatedly do so below.
    IFractionalGovernor _iGovernor = IFractionalGovernor(address(_governor));

    // Create the proposal *before* the user deposits anything.
    uint256 _proposalId = _createAndSubmitProposal(_governor);

    // Deposit some funds.
    _mintAndDepositIntoFlexClient(_token, _user, _voteWeight);

    // Now try to express a voting preference on the proposal.
    assertEq(flexClient.deposits(_token, _user), _voteWeight);
    vm.expectRevert(FVC.FlexVotingClient__NoVotingWeight.selector);
    vm.prank(_user);
    flexClient.expressVote(_iGovernor, _proposalId, uint8(_voteType));
  }

  function testFuzz_RevertWhen_NoClientWeightButTokenWeight(
    uint256 _seed,
    address _user,
    uint208 _voteWeight,
    uint8 _supportType
  ) public {
    GCS.VoteType _voteType;
    (_voteWeight, _voteType) = _assumeSafeVoteParams(_user, _voteWeight, _supportType);

    FractionalGovernor _governor = _randGov(_seed);
    IVotingToken _token = IVotingToken(address(_governor.token()));
    // Cast to avoid having to repeatedly do so below.
    IFractionalGovernor _iGovernor = IFractionalGovernor(address(_governor));

    // Mint gov but do not deposit.
    _mintAndApproveFlexClient(GovToken(address(_token)), _user, _voteWeight);
    assertEq(GovToken(address(_token)).balanceOf(_user), _voteWeight);
    assertEq(flexClient.deposits(_token, _user), 0);

    // Create the proposal.
    uint256 _proposalId = _createAndSubmitProposal(_governor);

    // _user should NOT be able to express his/her vote on the proposal.
    vm.expectRevert(FVC.FlexVotingClient__NoVotingWeight.selector);
    vm.prank(_user);
    flexClient.expressVote(_iGovernor, _proposalId, uint8(_voteType));

    // Deposit into the client.
    vm.prank(_user);
    flexClient.deposit(_token, _voteWeight);
    assertEq(flexClient.deposits(_token, _user), _voteWeight);

    // _user should still NOT be able to express his/her vote on the proposal.
    // Despite having a deposit balance, he/she didn't have a balance at the
    // proposal snapshot.
    vm.expectRevert(FVC.FlexVotingClient__NoVotingWeight.selector);
    vm.prank(_user);
    flexClient.expressVote(_iGovernor, _proposalId, uint8(_voteType));
  }

  function testFuzz_RevertOn_DoubleVotes(
    uint256 _seed,
    address _user,
    uint208 _voteWeight,
    uint8 _supportType
  ) public {
    GCS.VoteType _voteType;
    (_voteWeight, _voteType) = _assumeSafeVoteParams(_user, _voteWeight, _supportType);

    FractionalGovernor _governor = _randGov(_seed);
    IVotingToken _token = IVotingToken(address(_governor.token()));
    // Cast to avoid having to repeatedly do so below.
    IFractionalGovernor _iGovernor = IFractionalGovernor(address(_governor));

    // Deposit some funds.
    _mintAndDepositIntoFlexClient(_token, _user, _voteWeight);

    // Create the proposal.
    uint256 _proposalId = _createAndSubmitProposal(_governor);

    // _user should now be able to express his/her vote on the proposal.
    vm.prank(_user);
    flexClient.expressVote(_iGovernor, _proposalId, uint8(_voteType));

    (
      uint256 _againstVotesExpressedInit,
      uint256 _forVotesExpressedInit,
      uint256 _abstainVotesExpressedInit
    ) = flexClient.proposalVotes(_iGovernor, _proposalId);
    assertEq(_forVotesExpressedInit, _voteType == GCS.VoteType.For ? _voteWeight : 0);
    assertEq(_againstVotesExpressedInit, _voteType == GCS.VoteType.Against ? _voteWeight : 0);
    assertEq(_abstainVotesExpressedInit, _voteType == GCS.VoteType.Abstain ? _voteWeight : 0);

    // Vote early and often!
    vm.expectRevert(FVC.FlexVotingClient__AlreadyVoted.selector);
    vm.prank(_user);
    flexClient.expressVote(_iGovernor, _proposalId, uint8(_voteType));

    // No votes changed.
    (uint256 _againstVotesExpressed, uint256 _forVotesExpressed, uint256 _abstainVotesExpressed) =
      flexClient.proposalVotes(_iGovernor, _proposalId);
    assertEq(_forVotesExpressed, _forVotesExpressedInit);
    assertEq(_againstVotesExpressed, _againstVotesExpressedInit);
    assertEq(_abstainVotesExpressed, _abstainVotesExpressedInit);
  }

  function testFuzz_RevertOn_UnknownVoteType(
    uint256 _seed,
    address _user,
    uint208 _voteWeight,
    uint8 _supportType
  ) public {
    // Force vote type to be unrecognized.
    _supportType = uint8(bound(_supportType, MAX_VOTE_TYPE + 1, type(uint8).max));

    _assumeSafeUser(_user);
    _voteWeight = uint208(bound(_voteWeight, 1, MAX_VOTES));

    FractionalGovernor _governor = _randGov(_seed);
    IVotingToken _token = IVotingToken(address(_governor.token()));
    // Cast to avoid having to repeatedly do so below.
    IFractionalGovernor _iGovernor = IFractionalGovernor(address(_governor));

    // Deposit some funds.
    _mintAndDepositIntoFlexClient(_token, _user, _voteWeight);

    // Create the proposal.
    uint256 _proposalId = _createAndSubmitProposal(_governor);

    // Now try to express a voting preference with a bogus support type.
    vm.expectRevert(FVC.FlexVotingClient__InvalidSupportValue.selector);
    vm.prank(_user);
    flexClient.expressVote(_iGovernor, _proposalId, _supportType);
  }

  function testFuzz_RevertOn_UnknownProposal(
    uint256 _seed,
    address _user,
    uint208 _voteWeight,
    uint8 _supportType,
    uint256 _proposalId
  ) public {
    _assumeSafeUser(_user);
    _voteWeight = uint208(bound(_voteWeight, 1, MAX_VOTES));

    FractionalGovernor _governor = _randGov(_seed);
    IVotingToken _token = IVotingToken(address(_governor.token()));

    // Confirm that we've pulled a bogus proposal number.
    // This is the condition Governor.state checks for when raising
    // GovernorNonexistentProposal.
    vm.assume(_governor.proposalSnapshot(_proposalId) == 0);

    // Force vote type to be unrecognized.
    _supportType = uint8(bound(_supportType, MAX_VOTE_TYPE + 1, type(uint8).max));

    // Deposit some funds.
    _mintAndDepositIntoFlexClient(_token, _user, _voteWeight);

    // Create a real proposal to verify the two won't be mixed up when
    // expressing.
    uint256 _id = _createAndSubmitProposal(_governor);
    assert(_proposalId != _id);

    // Now try to express a voting preference on the bogus proposal.
    vm.expectRevert(FVC.FlexVotingClient__NoVotingWeight.selector);
    vm.prank(_user);
    flexClient.expressVote(IFractionalGovernor(address(_governor)), _proposalId, _supportType);
  }

  struct ExpressedVote {
    uint256 seed;
    address user;
    uint208 weight;
    FractionalGovernor gov;
    IVotingToken token;
    uint8 supportType;
    uint256 proposalId;
    uint256 againstVotes;
    uint256 forVotes;
    uint256 abstainVotes;
    uint256 expressedAgainst;
    uint256 expressedFor;
    uint256 expressedAbstain;
  }

  function testFuzz_MultiGovExpressVoteInternalAccouting(
    ExpressedVote memory _voteA,
    ExpressedVote memory _voteB
  ) public {
    // For some reason, it isn't possible to include these vars in the struct.
    GCS.VoteType _voteTypeA;
    GCS.VoteType _voteTypeB;

    _assumeSafeUser(_voteA.user);
    _assumeSafeUser(_voteB.user);
    vm.assume(_voteA.user != _voteB.user);

    _voteA.weight = uint208(bound(_voteA.weight, 1, MAX_VOTES - 1));
    _voteTypeA = _randVoteType(_voteA.supportType);
    _voteB.weight = uint208(bound(_voteB.weight, 1, MAX_VOTES - _voteA.weight));
    _voteTypeB = _randVoteType(_voteB.supportType);

    // Note: govs and tokens could be the same. This is intentional.
    _voteA.gov = _randGov(_voteA.seed);
    _voteB.gov = _randGovAlt(_voteB.seed);
    _voteA.token = IVotingToken(address(_voteA.gov.token()));
    _voteB.token = IVotingToken(address(_voteB.gov.token()));

    // Deposit some funds.
    _mintAndDepositIntoFlexClient(_voteA.token, _voteA.user, _voteA.weight);
    _mintAndDepositIntoFlexClient(_voteB.token, _voteB.user, _voteB.weight);

    // Create the proposals.
    _voteA.proposalId = _createAndSubmitProposal(_voteA.gov);
    if (address(_voteA.gov) != address(_voteB.gov)) {
      _voteB.proposalId = _createAndSubmitProposal(_voteB.gov);
      assertEq(_voteA.proposalId, _voteB.proposalId); // Ids are deterministic.
    } else {
      _voteB.proposalId = _voteA.proposalId;
    }

    // Users should now be able to express their votes on the proposals.
    vm.prank(_voteA.user);
    flexClient.expressVote(
      IFractionalGovernor(address(_voteA.gov)), _voteA.proposalId, uint8(_voteTypeA));
    vm.prank(_voteB.user);
    flexClient.expressVote(
      IFractionalGovernor(address(_voteB.gov)), _voteB.proposalId, uint8(_voteTypeB));

    if (address(_voteA.gov) != address(_voteB.gov)) {
      (
        _voteA.expressedAgainst,
        _voteA.expressedFor,
        _voteA.expressedAbstain
      ) = flexClient.proposalVotes(IFractionalGovernor(address(_voteA.gov)), _voteA.proposalId);
      assertEq(_voteA.expressedFor, _voteTypeA == GCS.VoteType.For ? _voteA.weight : 0);
      assertEq(_voteA.expressedAgainst, _voteTypeA == GCS.VoteType.Against ? _voteA.weight : 0);
      assertEq(_voteA.expressedAbstain, _voteTypeA == GCS.VoteType.Abstain ? _voteA.weight : 0);

      (
        _voteB.expressedAgainst,
        _voteB.expressedFor,
        _voteB.expressedAbstain
      ) = flexClient.proposalVotes(IFractionalGovernor(address(_voteB.gov)), _voteB.proposalId);
      assertEq(_voteB.expressedFor, _voteTypeB == GCS.VoteType.For ? _voteB.weight : 0);
      assertEq(_voteB.expressedAgainst, _voteTypeB == GCS.VoteType.Against ? _voteB.weight : 0);
      assertEq(_voteB.expressedAbstain, _voteTypeB == GCS.VoteType.Abstain ? _voteB.weight : 0);
    } else {
        uint256 expectedAgainst = _voteTypeA == GCS.VoteType.Against ? _voteA.weight : 0;
        expectedAgainst += (_voteTypeB == GCS.VoteType.Against ? _voteB.weight : 0);
        uint256 expectedFor = _voteTypeA == GCS.VoteType.For ? _voteA.weight : 0;
        expectedFor += (_voteTypeB == GCS.VoteType.For ? _voteB.weight : 0);
        uint256 expectedAbstain = _voteTypeA == GCS.VoteType.Abstain ? _voteA.weight : 0;
        expectedAbstain += (_voteTypeB == GCS.VoteType.Abstain ? _voteB.weight : 0);
      (
        uint256 expressedAgainst,
        uint256 expressedFor,
        uint256 expressedAbstain
      ) = flexClient.proposalVotes(IFractionalGovernor(address(_voteA.gov)), _voteA.proposalId);
      assertEq(expressedFor, expectedFor);
      assertEq(expressedAgainst, expectedAgainst);
      assertEq(expressedAbstain, expectedAbstain);
    }
  }
}

abstract contract CastVote is FlexVotingClientTest {
  function testFuzz_SubmitsVotesToGovernor(
    uint256 _seed,
    address _user,
    uint208 _voteWeight,
    uint8 _supportType
  ) public {
    GCS.VoteType _voteType;
    (_voteWeight, _voteType) = _assumeSafeVoteParams(_user, _voteWeight, _supportType);

    // Cast to avoid having to repeatedly do so below.
    FractionalGovernor _governor = _randGov(_seed);
    IFractionalGovernor _iGovernor = IFractionalGovernor(address(_governor));
    IVotingToken _token = IVotingToken(address(_governor.token()));

    // Deposit some funds.
    _mintAndDepositIntoFlexClient(_token, _user, _voteWeight);

    // Create the proposal.
    uint256 _proposalId = _createAndSubmitProposal(_governor);

    // _user should now be able to express his/her vote on the proposal.
    vm.prank(_user);
    flexClient.expressVote(_iGovernor, _proposalId, uint8(_voteType));

    (uint256 _againstVotesExpressed, uint256 _forVotesExpressed, uint256 _abstainVotesExpressed) =
      flexClient.proposalVotes(_iGovernor, _proposalId);

    assertEq(_forVotesExpressed, _voteType == GCS.VoteType.For ? _voteWeight : 0);
    assertEq(_againstVotesExpressed, _voteType == GCS.VoteType.Against ? _voteWeight : 0);
    assertEq(_abstainVotesExpressed, _voteType == GCS.VoteType.Abstain ? _voteWeight : 0);

    // No votes have been cast yet.
    (uint256 _againstVotes, uint256 _forVotes, uint256 _abstainVotes) =
      _governor.proposalVotes(_proposalId);
    assertEq(_forVotes, 0);
    assertEq(_againstVotes, 0);
    assertEq(_abstainVotes, 0);

    // Submit votes on behalf of the flexClient.
    flexClient.castVote(_iGovernor, _proposalId);

    // Governor should now record votes from the flexClient.
    (_againstVotes, _forVotes, _abstainVotes) = _governor.proposalVotes(_proposalId);
    assertEq(_forVotes, _forVotesExpressed);
    assertEq(_againstVotes, _againstVotesExpressed);
    assertEq(_abstainVotes, _abstainVotesExpressed);
  }

  function testFuzz_WeightIsSnapshotDependent(
    uint256 _seed,
    address _user,
    uint208 _voteWeightA,
    uint208 _voteWeightB,
    uint8 _supportType
  ) public {
    GCS.VoteType _voteType;
    (_voteWeightA, _voteType) = _assumeSafeVoteParams(_user, _voteWeightA, _supportType);
    _voteWeightB = _assumeSafeVoteParams(_user, _voteWeightB);

    // Cast to avoid having to repeatedly do so below.
    FractionalGovernor _governor = _randGov(_seed);
    IFractionalGovernor _iGovernor = IFractionalGovernor(address(_governor));
    IVotingToken _token = IVotingToken(address(_governor.token()));

    // Deposit some funds.
    _mintAndDepositIntoFlexClient(_token, _user, _voteWeightA);

    // Create the proposal.
    uint256 _proposalId = _createAndSubmitProposal(_governor);

    // Sometime later the user deposits some more.
    _advanceTimeTo(_governor.proposalDeadline(_proposalId) - 1);
    _mintAndDepositIntoFlexClient(_token, _user, _voteWeightB);

    vm.prank(_user);
    flexClient.expressVote(_iGovernor, _proposalId, uint8(_voteType));

    // The internal proposal vote weight should not reflect the new deposit weight.
    (uint256 _againstVotesExpressed, uint256 _forVotesExpressed, uint256 _abstainVotesExpressed) =
      flexClient.proposalVotes(_iGovernor, _proposalId);
    assertEq(_forVotesExpressed, _voteType == GCS.VoteType.For ? _voteWeightA : 0);
    assertEq(_againstVotesExpressed, _voteType == GCS.VoteType.Against ? _voteWeightA : 0);
    assertEq(_abstainVotesExpressed, _voteType == GCS.VoteType.Abstain ? _voteWeightA : 0);

    // Submit votes on behalf of the flexClient.
    flexClient.castVote(_iGovernor, _proposalId);

    // Votes cast should likewise reflect only the earlier balance.
    (uint256 _againstVotes, uint256 _forVotes, uint256 _abstainVotes) =
      _governor.proposalVotes(_proposalId);
    assertEq(_forVotes, _voteType == GCS.VoteType.For ? _voteWeightA : 0);
    assertEq(_againstVotes, _voteType == GCS.VoteType.Against ? _voteWeightA : 0);
    assertEq(_abstainVotes, _voteType == GCS.VoteType.Abstain ? _voteWeightA : 0);
  }

  function testFuzz_TracksMultipleUsersVotes(
    uint256 _seed,
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

    // Cast to avoid having to repeatedly do so below.
    FractionalGovernor _governor = _randGov(_seed);
    IFractionalGovernor _iGovernor = IFractionalGovernor(address(_governor));
    IVotingToken _token = IVotingToken(address(_governor.token()));

    // Deposit some funds.
    _mintAndDepositIntoFlexClient(_token, _userA, _voteWeightA);
    _mintAndDepositIntoFlexClient(_token, _userB, _voteWeightB);

    // Create the proposal.
    uint256 _proposalId = _createAndSubmitProposal(_governor);

    // users should now be able to express their votes on the proposal.
    vm.prank(_userA);
    flexClient.expressVote(_iGovernor, _proposalId, uint8(GCS.VoteType.Against));
    vm.prank(_userB);
    flexClient.expressVote(_iGovernor, _proposalId, uint8(GCS.VoteType.Abstain));

    (uint256 _againstVotesExpressed, uint256 _forVotesExpressed, uint256 _abstainVotesExpressed) =
      flexClient.proposalVotes(_iGovernor, _proposalId);
    assertEq(_forVotesExpressed, 0);
    assertEq(_againstVotesExpressed, _voteWeightA);
    assertEq(_abstainVotesExpressed, _voteWeightB);

    // The governor should have not recieved any votes yet.
    (uint256 _againstVotes, uint256 _forVotes, uint256 _abstainVotes) =
      _governor.proposalVotes(_proposalId);
    assertEq(_forVotes, 0);
    assertEq(_againstVotes, 0);
    assertEq(_abstainVotes, 0);

    // Submit votes on behalf of the flexClient.
    flexClient.castVote(_iGovernor, _proposalId);

    // Governor should now record votes for the flexClient.
    (_againstVotes, _forVotes, _abstainVotes) = _governor.proposalVotes(_proposalId);
    assertEq(_forVotes, 0);
    assertEq(_againstVotes, _voteWeightA);
    assertEq(_abstainVotes, _voteWeightB);
  }

  struct TracksMultipleGovernorsVars {
    uint256 seed;
    address user;
    uint208 weight;
    uint8 supportType;
    FractionalGovernor gov;
    IFractionalGovernor iGov;
    IVotingToken token;
    GovToken tokenGov;
    uint256 proposalId;
    uint256 againstExpressed;
    uint256 forExpressed;
    uint256 abstainExpressed;
    uint256 againstVotes;
    uint256 forVotes;
    uint256 abstainVotes;
  }

  function testFuzz_TracksMultipleGovernors(
    TracksMultipleGovernorsVars memory _varsA,
    TracksMultipleGovernorsVars memory _varsB
  ) public {
    vm.assume(_varsA.user != _varsB.user);
    _assumeSafeUser(_varsA.user);
    _assumeSafeUser(_varsB.user);
    _varsA.weight = uint208(bound(_varsA.weight, 1, MAX_VOTES - 1));
    _varsB.weight = uint208(bound(_varsB.weight, 1, MAX_VOTES - _varsA.weight));

    // For some reason, it isn't possible to include these vars in the struct.
    GCS.VoteType _voteTypeA = _randVoteType(_varsA.supportType);
    GCS.VoteType _voteTypeB = _randVoteType(_varsB.supportType);

    // Govs and tokens could be the same. This is intentional.
    _varsA.gov = _randGov(_varsA.seed);
    _varsB.gov = _randGov(_varsB.seed);
    _varsA.iGov = IFractionalGovernor(address(_varsA.gov));
    _varsB.iGov = IFractionalGovernor(address(_varsB.gov));
    _varsA.token = IVotingToken(address(_varsA.gov.token()));
    _varsB.token = IVotingToken(address(_varsB.gov.token()));
    _varsA.tokenGov = GovToken(address(_varsA.token));
    _varsB.tokenGov = GovToken(address(_varsB.token));

    // Deposit some funds.
    _mintAndDepositIntoFlexClient(_varsA.token, _varsA.user, _varsA.weight);
    _mintAndDepositIntoFlexClient(_varsB.token, _varsB.user, _varsB.weight);

    // Create the proposal.
    _varsA.proposalId = _createAndSubmitProposal(_varsA.gov);
    if (address(_varsA.gov) != address(_varsB.gov)) {
      _varsB.proposalId = _createAndSubmitProposal(_varsB.gov);
      assertEq(_varsA.proposalId, _varsB.proposalId); // Ids are deterministic.
    } else {
      _varsB.proposalId = _varsA.proposalId;
    }

    // Users should now be able to express their votes on the proposal.
    vm.prank(_varsA.user);
    flexClient.expressVote(_varsA.iGov, _varsA.proposalId, uint8(_voteTypeA));
    vm.prank(_varsB.user);
    flexClient.expressVote(_varsB.iGov, _varsB.proposalId, uint8(_voteTypeB));

    (_varsA.againstExpressed, _varsA.forExpressed, _varsA.abstainExpressed) =
      flexClient.proposalVotes(_varsA.iGov, _varsA.proposalId);
    (_varsB.againstExpressed, _varsB.forExpressed, _varsB.abstainExpressed) =
      flexClient.proposalVotes(_varsB.iGov, _varsB.proposalId);

    if (address(_varsA.gov) != address(_varsB.gov)) {
      if (uint8(_voteTypeA) == uint8(GCS.VoteType.For))
        assertEq(_varsA.forExpressed, _varsA.weight);
      if (uint8(_voteTypeA) == uint8(GCS.VoteType.Against))
        assertEq(_varsA.againstExpressed, _varsA.weight);
      if (uint8(_voteTypeA) == uint8(GCS.VoteType.Abstain))
        assertEq(_varsA.abstainExpressed, _varsA.weight);

      if (uint8(_voteTypeB) == uint8(GCS.VoteType.For))
        assertEq(_varsB.forExpressed, _varsB.weight);
      if (uint8(_voteTypeB) == uint8(GCS.VoteType.Against))
        assertEq(_varsB.againstExpressed, _varsB.weight);
      if (uint8(_voteTypeB) == uint8(GCS.VoteType.Abstain))
        assertEq(_varsB.abstainExpressed, _varsB.weight);
    } else {
      uint256 _expectedAgainst;
      uint256 _expectedFor;
      uint256 _expectedAbstain;

      if (_voteTypeA == GCS.VoteType.Against) _expectedAgainst += _varsA.weight;
      if (_voteTypeA == GCS.VoteType.For) _expectedFor += _varsA.weight;
      if (_voteTypeA == GCS.VoteType.Abstain) _expectedAbstain += _varsA.weight;
      if (_voteTypeB == GCS.VoteType.Against) _expectedAgainst += _varsB.weight;
      if (_voteTypeB == GCS.VoteType.For) _expectedFor += _varsB.weight;
      if (_voteTypeB == GCS.VoteType.Abstain) _expectedAbstain += _varsB.weight;

      assertEq(_varsA.forExpressed, _expectedFor);
      assertEq(_varsA.againstExpressed, _expectedAgainst);
      assertEq(_varsA.abstainExpressed, _expectedAbstain);
    }

    // Submit votes on behalf of the flexClient.
    flexClient.castVote(_varsA.iGov, _varsA.proposalId);
    if (address(_varsA.gov) != address(_varsB.gov)) {
      flexClient.castVote(_varsB.iGov, _varsB.proposalId);
    }

    // Governors should have recorded votes from the flexClient.
    if (address(_varsA.gov) != address(_varsB.gov)) {
      (_varsA.againstVotes, _varsA.forVotes, _varsA.abstainVotes) =
        _varsA.gov.proposalVotes(_varsA.proposalId);
      if (uint8(_voteTypeA) == uint8(GCS.VoteType.For))
        assertEq(_varsA.forVotes, _varsA.weight);
      if (uint8(_voteTypeA) == uint8(GCS.VoteType.Against))
        assertEq(_varsA.againstVotes, _varsA.weight);
      if (uint8(_voteTypeA) == uint8(GCS.VoteType.Abstain))
        assertEq(_varsA.abstainVotes, _varsA.weight);

      (_varsB.againstVotes, _varsB.forVotes, _varsB.abstainVotes) =
        _varsB.gov.proposalVotes(_varsB.proposalId);
      if (uint8(_voteTypeB) == uint8(GCS.VoteType.For))
        assertEq(_varsB.forVotes, _varsB.weight);
      if (uint8(_voteTypeB) == uint8(GCS.VoteType.Against))
        assertEq(_varsB.againstVotes, _varsB.weight);
      if (uint8(_voteTypeB) == uint8(GCS.VoteType.Abstain))
        assertEq(_varsB.abstainVotes, _varsB.weight);
    } else {
      (_varsA.againstVotes, _varsA.forVotes, _varsA.abstainVotes) =
        _varsA.gov.proposalVotes(_varsA.proposalId);

      uint256 _expectedAgainst;
      uint256 _expectedFor;
      uint256 _expectedAbstain;

      if (_voteTypeA == GCS.VoteType.Against) _expectedAgainst += _varsA.weight;
      if (_voteTypeA == GCS.VoteType.For) _expectedFor += _varsA.weight;
      if (_voteTypeA == GCS.VoteType.Abstain) _expectedAbstain += _varsA.weight;
      if (_voteTypeB == GCS.VoteType.Against) _expectedAgainst += _varsB.weight;
      if (_voteTypeB == GCS.VoteType.For) _expectedFor += _varsB.weight;
      if (_voteTypeB == GCS.VoteType.Abstain) _expectedAbstain += _varsB.weight;

      assertEq(_varsA.forVotes, _expectedFor);
      assertEq(_varsA.againstVotes, _expectedAgainst);
      assertEq(_varsA.abstainVotes, _expectedAbstain);
    }
  }

  struct VoteWeightIsScaledTestVars {
    uint256 seed;
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
    _assumeSafeUser(_vars.userA);
    _assumeSafeUser(_vars.userB);
    _assumeSafeUser(_vars.userC);
    _assumeSafeUser(_vars.userD);

    vm.assume(
      _vars.userA != _vars.userB &&
      _vars.userA != _vars.userC &&
      _vars.userA != _vars.userD &&
      _vars.userB != _vars.userC &&
      _vars.userB != _vars.userD &&
      _vars.userC != _vars.userD
    );

    // Cast to avoid having to repeatedly do so below.
    FractionalGovernor _governor = _randGov(_vars.seed);
    IFractionalGovernor _iGovernor = IFractionalGovernor(address(_governor));
    IVotingToken _token = IVotingToken(address(_governor.token()));

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
    _mintAndDepositIntoFlexClient(_token, _vars.userA, _vars.voteWeightA);
    _mintAndDepositIntoFlexClient(_token, _vars.userB, _vars.voteWeightB);
    uint256 _initDepositWeight = GovToken(address(_token)).balanceOf(address(flexClient));

    // Borrow from the flexClient, decreasing its token balance.
    vm.prank(_vars.userC);
    flexClient.borrow(_token, _vars.borrowAmountC);

    // Create the proposal.
    uint256 _proposalId = _createAndSubmitProposal(_governor);

    // Jump ahead to the proposal snapshot to lock in the flexClient's balance.
    _advanceTimeTo(_governor.proposalSnapshot(_proposalId) + 1);
    uint256 _expectedVotingWeight = GovToken(address(_token)).balanceOf(address(flexClient));
    assertLt(_expectedVotingWeight, _initDepositWeight);

    // A+B express votes
    vm.prank(_vars.userA);
    flexClient.expressVote(_iGovernor, _proposalId, _vars.supportTypeA);
    vm.prank(_vars.userB);
    flexClient.expressVote(_iGovernor, _proposalId, _vars.supportTypeB);

    // Borrow more from the flexClient, just to confirm that the vote weight will be based
    // on the snapshot blocktime/number.
    vm.prank(_vars.userD);
    flexClient.borrow(_token, _vars.borrowAmountD);

    // Submit votes on behalf of the flexClient.
    flexClient.castVote(_iGovernor, _proposalId);

    // Vote should be cast as a percentage of the depositer's expressed types, since
    // the actual weight is different from the deposit weight.
    (uint256 _againstVotes, uint256 _forVotes, uint256 _abstainVotes) =
      _governor.proposalVotes(_proposalId);

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

  struct AbandonVoteWeightTestVars {
    uint256 seed;
    address userA;
    address userB;
    address userC;
    uint208 weightA;
    uint208 weightB;
    uint8 supportTypeA;
    uint208 borrowAmount;
    FractionalGovernor gov;
    IFractionalGovernor iGov;
    IVotingToken token;
    GovToken tokenGov;
  }

  // This is important because it ensures you can't *gain* voting weight by
  // getting other people to not vote.
  function testFuzz_AbandonsUnexpressedVotingWeight(
    AbandonVoteWeightTestVars memory _vars
  ) public {

    _assumeSafeUser(_vars.userA);
    _assumeSafeUser(_vars.userB);
    _assumeSafeUser(_vars.userC);

    vm.assume(
      _vars.userA != _vars.userB &&
      _vars.userA != _vars.userC &&
      _vars.userB != _vars.userC
    );

    // Cast to avoid having to repeatedly do so below.
    _vars.gov = _randGov(_vars.seed);
    _vars.iGov = IFractionalGovernor(address(_vars.gov));
    _vars.token = IVotingToken(address(_vars.gov.token()));
    _vars.tokenGov = GovToken(address(_vars.token));

    // Requirements:
    //   voteWeights and borrow each >= 1
    //   voteWeights and borrow each <= uint128.max
    //   _vars.weightA + _vars.weightB < MAX_VOTES
    //   _vars.weightA + _vars.weightB > _vars.borrowAmount
    _vars.weightA = uint208(bound(_vars.weightA, 1, MAX_VOTES - 2));
    _vars.weightB = uint208(bound(_vars.weightB, 1, MAX_VOTES - _vars.weightA - 1));
    _vars.borrowAmount = uint208(bound(_vars.borrowAmount, 1, _vars.weightA + _vars.weightB - 1));
    GCS.VoteType _voteTypeA = _randVoteType(_vars.supportTypeA);

    // Mint and deposit.
    _mintAndDepositIntoFlexClient(_vars.token, _vars.userA, _vars.weightA);
    _mintAndDepositIntoFlexClient(_vars.token, _vars.userB, _vars.weightB);
    uint256 _initDepositWeight = _vars.tokenGov.balanceOf(address(flexClient));

    // Borrow from the flexClient, decreasing its token balance.
    vm.prank(_vars.userC);
    flexClient.borrow(_vars.token, _vars.borrowAmount);

    // Create the proposal.
    uint256 _proposalId = _createAndSubmitProposal(_vars.gov);

    // Jump ahead to the proposal snapshot to lock in the flexClient's balance.
    _advanceTimeTo(_vars.gov.proposalSnapshot(_proposalId) + 1);
    uint256 _totalPossibleVotingWeight = _vars.tokenGov.balanceOf(address(flexClient));

    uint256 _fullVotingWeight = _vars.tokenGov.balanceOf(address(flexClient));
    assertLt(_fullVotingWeight, _initDepositWeight);
    assertEq(_fullVotingWeight, _vars.weightA + _vars.weightB - _vars.borrowAmount);

    // Only user A expresses a vote.
    vm.prank(_vars.userA);
    flexClient.expressVote(_vars.iGov, _proposalId, uint8(_voteTypeA));

    // Submit votes on behalf of the flexClient.
    flexClient.castVote(_vars.iGov, _proposalId);

    // Vote should be cast as a percentage of the depositer's expressed types, since
    // the actual weight is different from the deposit weight.
    (uint256 _againstVotes, uint256 _forVotes, uint256 _abstainVotes) =
      _vars.gov.proposalVotes(_proposalId);

    uint256 _expectedVotingWeightA = (_vars.weightA * _fullVotingWeight) / _initDepositWeight;
    uint256 _expectedVotingWeightB = (_vars.weightB * _fullVotingWeight) / _initDepositWeight;

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

  struct VotingWeightIsUnaffectedByDepositsAfterProposal {
    uint256 seed;
    address userA;
    address userB;
    address userC;
    uint208 weightA;
    uint208 weightB;
    uint8 supportTypeA;
    FractionalGovernor gov;
    IFractionalGovernor iGov;
    IVotingToken token;
    GovToken tokenGov;
  }

  function testFuzz_VotingWeightIsUnaffectedByDepositsAfterProposal(
    VotingWeightIsUnaffectedByDepositsAfterProposal memory _vars
  ) public {
    _assumeSafeUser(_vars.userA);
    _assumeSafeUser(_vars.userB);
    _assumeSafeUser(_vars.userC);

    vm.assume(
      _vars.userA != _vars.userB &&
      _vars.userA != _vars.userC &&
      _vars.userB != _vars.userC
    );

    // Cast to avoid having to repeatedly do so below.
    _vars.gov = _randGov(_vars.seed);
    _vars.iGov = IFractionalGovernor(address(_vars.gov));
    _vars.token = IVotingToken(address(_vars.gov.token()));
    _vars.tokenGov = GovToken(address(_vars.token));

    // We need _vars.weightA + _vars.weightB < MAX_VOTES.
    _vars.weightA = uint208(bound(_vars.weightA, 1, MAX_VOTES - 2));
    _vars.weightB = uint208(bound(_vars.weightB, 1, MAX_VOTES - _vars.weightA - 1));
    GCS.VoteType _voteTypeA = _randVoteType(_vars.supportTypeA);

    // Mint and deposit for just userA.
    _mintAndDepositIntoFlexClient(_vars.token, _vars.userA, _vars.weightA);
    uint256 _initDepositWeight = token.balanceOf(address(flexClient));

    // Create the proposal.
    uint256 _proposalId = _createAndSubmitProposal(_vars.gov);

    // Jump ahead to the proposal snapshot to lock in the flexClient's balance.
    _advanceTimeTo(_vars.gov.proposalSnapshot(_proposalId) + 1);

    // Now mint and deposit for userB.
    _mintGovAndDepositIntoFlexClient(_vars.userB, _vars.weightB);

    uint256 _fullVotingWeight = _vars.tokenGov.balanceOf(address(flexClient));
    assert(_fullVotingWeight > _initDepositWeight);
    assertEq(_fullVotingWeight, _vars.weightA + _vars.weightB);

    // Only user A expresses a vote.
    vm.prank(_vars.userA);
    flexClient.expressVote(_vars.iGov, _proposalId, uint8(_voteTypeA));

    // Submit votes on behalf of the flexClient.
    flexClient.castVote(_vars.iGov, _proposalId);

    (uint256 _againstVotes, uint256 _forVotes, uint256 _abstainVotes) =
      _vars.gov.proposalVotes(_proposalId);

    // We assert the weight is within a range of 1 because scaled weights are sometimes floored.
    if (_voteTypeA == GCS.VoteType.For) assertEq(_forVotes, _vars.weightA);
    if (_voteTypeA == GCS.VoteType.Against) assertEq(_againstVotes, _vars.weightA);
    if (_voteTypeA == GCS.VoteType.Abstain) assertEq(_abstainVotes, _vars.weightA);
  }

  struct CanCallMultipleTimesForTheSameProposalVars {
    uint256 seed;
    address userA;
    address userB;
    uint208 weightA;
    uint208 weightB;
    FractionalGovernor gov;
    IFractionalGovernor iGov;
    IVotingToken token;
    GovToken tokenGov;
  }

  function testFuzz_CanCallMultipleTimesForTheSameProposal(
    CanCallMultipleTimesForTheSameProposalVars memory _vars
  ) public {
    _vars.weightA = uint208(bound(_vars.weightA, 1, type(uint120).max));
    _vars.weightB = uint208(bound(_vars.weightB, 1, type(uint120).max));

    _assumeSafeUser(_vars.userA);
    _assumeSafeUser(_vars.userB);
    vm.assume(_vars.userA != _vars.userB);

    // Cast to avoid having to repeatedly do so below.
    _vars.gov = _randGov(_vars.seed);
    _vars.iGov = IFractionalGovernor(address(_vars.gov));
    _vars.token = IVotingToken(address(_vars.gov.token()));
    _vars.tokenGov = GovToken(address(_vars.token));

    // Deposit some funds.
    _mintAndDepositIntoFlexClient(_vars.token, _vars.userA, _vars.weightA);
    _mintAndDepositIntoFlexClient(_vars.token, _vars.userB, _vars.weightB);

    // Create the proposal.
    uint256 _proposalId = _createAndSubmitProposal(_vars.gov);

    // users should now be able to express their votes on the proposal.
    vm.prank(_vars.userA);
    flexClient.expressVote(_vars.iGov, _proposalId, uint8(GCS.VoteType.Against));

    (uint256 _againstVotesExpressed, uint256 _forVotesExpressed, uint256 _abstainVotesExpressed) =
      flexClient.proposalVotes(_vars.iGov, _proposalId);
    assertEq(_forVotesExpressed, 0);
    assertEq(_againstVotesExpressed, _vars.weightA);
    assertEq(_abstainVotesExpressed, 0);

    // The governor should have not recieved any votes yet.
    (uint256 _againstVotes, uint256 _forVotes, uint256 _abstainVotes) =
      _vars.gov.proposalVotes(_proposalId);
    assertEq(_forVotes, 0);
    assertEq(_againstVotes, 0);
    assertEq(_abstainVotes, 0);

    // Submit votes on behalf of the flexClient.
    flexClient.castVote(_vars.iGov, _proposalId);

    // Governor should now record votes for the flexClient.
    (_againstVotes, _forVotes, _abstainVotes) = _vars.gov.proposalVotes(_proposalId);
    assertEq(_forVotes, 0);
    assertEq(_againstVotes, _vars.weightA);
    assertEq(_abstainVotes, 0);

    // The second user now decides to express and cast.
    vm.prank(_vars.userB);
    flexClient.expressVote(_vars.iGov, _proposalId, uint8(GCS.VoteType.Abstain));
    flexClient.castVote(_vars.iGov, _proposalId);

    // Governor should now record votes for both users.
    (_againstVotes, _forVotes, _abstainVotes) = _vars.gov.proposalVotes(_proposalId);
    assertEq(_forVotes, 0);
    assertEq(_againstVotes, _vars.weightA); // This should be unchanged!
    assertEq(_abstainVotes, _vars.weightB); // Second user's votes are now in.
  }

  function testFuzz_RevertWhen_NoVotesToCast(
    uint256 _seed,
    address _user,
    uint208 _voteWeight,
    uint8 _supportType
  )
    public
  {
    GCS.VoteType _voteType;
    (_voteWeight, _voteType) = _assumeSafeVoteParams(_user, _voteWeight, _supportType);

    // Cast to avoid having to repeatedly do so below.
    FractionalGovernor _governor = _randGov(_seed);
    IFractionalGovernor _iGovernor = IFractionalGovernor(address(_governor));
    IVotingToken _token = IVotingToken(address(_governor.token()));

    // Deposit some funds.
    _mintAndDepositIntoFlexClient(_token, _user, _voteWeight);

    // Create the proposal.
    uint256 _proposalId = _createAndSubmitProposal(_governor);

    // No one has expressed, there are no votes to cast.
    vm.expectRevert(FVC.FlexVotingClient__NoVotesExpressed.selector);
    flexClient.castVote(_iGovernor, _proposalId);

    // _user expresses his/her vote on the proposal.
    vm.prank(_user);
    flexClient.expressVote(_iGovernor, _proposalId, uint8(_voteType));

    // Submit votes on behalf of the flexClient.
    flexClient.castVote(_iGovernor, _proposalId);

    // All votes have been cast, there's nothing new to send to the governor.
    vm.expectRevert(FVC.FlexVotingClient__NoVotesExpressed.selector);
    flexClient.castVote(_iGovernor, _proposalId);
  }

  function testFuzz_RevertIf_AfterVotingPeriod(
    uint256 _seed,
    address _user,
    uint208 _voteWeight,
    uint8 _supportType
  ) public {
    GCS.VoteType _voteType;
    (_voteWeight, _voteType) = _assumeSafeVoteParams(_user, _voteWeight, _supportType);

    // Cast to avoid having to repeatedly do so below.
    FractionalGovernor _governor = _randGov(_seed);
    IFractionalGovernor _iGovernor = IFractionalGovernor(address(_governor));
    IVotingToken _token = IVotingToken(address(_governor.token()));

    // Deposit some funds.
    _mintAndDepositIntoFlexClient(_token, _user, _voteWeight);

    // Create the proposal.
    uint256 _proposalId = _createAndSubmitProposal(_governor);

    // Express vote preference.
    vm.prank(_user);
    flexClient.expressVote(_iGovernor, _proposalId, uint8(_voteType));

    // Jump ahead so that we're outside of the proposal's voting period.
    _advanceTimeTo(_governor.proposalDeadline(_proposalId) + 1);
    IGovernor.ProposalState _status = IGovernor.ProposalState(uint32(_governor.state(_proposalId)));

    // We should not be able to castVote at this point.
    vm.expectRevert(
      abi.encodeWithSelector(
        IGovernor.GovernorUnexpectedProposalState.selector,
        _proposalId,
        _status,
        bytes32(1 << uint8(IGovernor.ProposalState.Active))
      )
    );
    flexClient.castVote(_iGovernor, _proposalId);
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
    assertEq(flexClient.getPastTotalVoteWeight(_now() - 1), _depositAmount);
  }
}

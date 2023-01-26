// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {FractionalPool, IVotingToken, IFractionalGovernor} from "../src/FractionalPool.sol";
import "./GovToken.sol";
import "./FractionalGovernor.sol";
import "./ProposalReceiverMock.sol";

contract FractionalPoolTest is Test {
  enum ProposalState {
    Pending,
    Active,
    Canceled,
    Defeated,
    Succeeded,
    Queued,
    Expired,
    Executed
  }

  enum VoteType {
    Against,
    For,
    Abstain
  }

  FractionalPool pool;
  GovToken token;
  FractionalGovernor governor;
  ProposalReceiverMock receiver;

  function setUp() public {
    token = new GovToken();
    vm.label(address(token), "token");

    governor = new FractionalGovernor("Governor", IVotes(token));
    vm.label(address(governor), "governor");

    pool = new FractionalPool(IVotingToken(address(token)), IFractionalGovernor(address(governor)));
    vm.label(address(pool), "pool");

    receiver = new ProposalReceiverMock();
    vm.label(address(receiver), "receiver");
  }

  function _mintGovAndApprovePool(address _holder, uint256 _amount) public {
    vm.assume(_holder != address(0));
    token.exposed_mint(_holder, _amount);
    vm.prank(_holder);
    token.approve(address(pool), type(uint256).max);
  }

  function _mintGovAndDepositIntoPool(address _address, uint256 _amount) internal {
    _mintGovAndApprovePool(_address, _amount);
    vm.prank(_address);
    pool.deposit(_amount);
  }

  function _createAndSubmitProposal() internal returns (uint256 proposalId) {
    // proposal will underflow if we're on the zero block
    if (block.number == 0) vm.roll(42);

    // create a proposal
    bytes memory receiverCallData = abi.encodeWithSignature("mockReceiverFunction()");
    address[] memory targets = new address[](1);
    uint256[] memory values = new uint256[](1);
    bytes[] memory calldatas = new bytes[](1);
    targets[0] = address(receiver);
    values[0] = 0; // no ETH will be sent
    calldatas[0] = receiverCallData;

    // submit the proposal
    proposalId = governor.propose(targets, values, calldatas, "A great proposal");
    assertEq(uint256(governor.state(proposalId)), uint256(ProposalState.Pending));

    // advance proposal to active state
    vm.roll(governor.proposalSnapshot(proposalId) + 1);
    assertEq(uint256(governor.state(proposalId)), uint256(ProposalState.Active));
  }

  function _commonFuzzerAssumptions(address _address, uint256 _voteWeight)
    public
    view
    returns (uint256)
  {
    return _commonFuzzerAssumptions(_address, _voteWeight, uint8(VoteType.Against));
  }

  function _commonFuzzerAssumptions(address _address, uint256 _voteWeight, uint8 _supportType)
    public
    view
    returns (uint256)
  {
    vm.assume(_address != address(pool));
    vm.assume(_supportType <= uint8(VoteType.Abstain)); // couldn't get fuzzer to work w/ the enum
    // This max is a limitation of the fractional governance protocol storage.
    return bound(_voteWeight, 1, type(uint128).max);
  }
}

contract Deployment is FractionalPoolTest {
  function test_FractionalPoolDeployment() public {
    assertEq(token.name(), "Governance Token");
    assertEq(token.symbol(), "GOV");

    assertEq(address(pool.TOKEN()), address(token));
    assertEq(token.delegates(address(pool)), address(pool));

    assertEq(governor.name(), "Governor");
    assertEq(address(governor.token()), address(token));
  }
}

contract Deposit is FractionalPoolTest {
  function test_UserCanDepositGovTokens(address _holder, uint256 _amount) public {
    _amount = bound(_amount, 0, type(uint224).max);
    vm.assume(_holder != address(pool));
    uint256 initialBalance = token.balanceOf(_holder);

    _mintGovAndDepositIntoPool(_holder, _amount);

    assertEq(token.balanceOf(address(pool)), _amount);
    assertEq(token.balanceOf(_holder), initialBalance);
    assertEq(token.getVotes(address(pool)), _amount);
  }

  function testFuzz_DepositsAreCheckpointed(
    address _holder,
    uint256 _amountA,
    uint256 _amountB,
    uint24 _depositDelay
  ) public {
    _amountA = bound(_amountA, 1, type(uint128).max);
    _amountB = bound(_amountB, 1, type(uint128).max);

    // Deposit some gov.
    _mintGovAndDepositIntoPool(_holder, _amountA);

    vm.roll(block.number + 42); // advance so that we can look at checkpoints

    // We can still retrieve the user's balance at the given time.
    assertEq(
      pool.getPastDeposits(_holder, block.number - 1),
      _amountA,
      "user's first deposit was not properly checkpointed"
    );

    uint256 newBlockNum = block.number + _depositDelay;
    vm.roll(newBlockNum);

    // Deposit some more.
    _mintGovAndDepositIntoPool(_holder, _amountB);

    vm.roll(block.number + 42); // advance so that we can look at checkpoints
    assertEq(
      pool.getPastDeposits(_holder, block.number - 1),
      _amountA + _amountB,
      "user's second deposit was not properly checkpointed"
    );
  }
}

// TODO: Withdraw testing

contract Vote is FractionalPoolTest {
  function testFuzz_UserCanCastVotes(address _hodler, uint256 _voteWeight, uint8 _supportType)
    public
  {
    _voteWeight = _commonFuzzerAssumptions(_hodler, _voteWeight, _supportType);

    // Deposit some funds.
    _mintGovAndDepositIntoPool(_hodler, _voteWeight);

    // create the proposal
    uint256 _proposalId = _createAndSubmitProposal();

    // _holder should now be able to express his/her vote on the proposal
    vm.prank(_hodler);
    pool.expressVote(_proposalId, _supportType);
    (uint256 _againstVotesExpressed, uint256 _forVotesExpressed, uint256 _abstainVotesExpressed) =
      pool.proposalVotes(_proposalId);
    assertEq(_forVotesExpressed, _supportType == uint8(VoteType.For) ? _voteWeight : 0);
    assertEq(_againstVotesExpressed, _supportType == uint8(VoteType.Against) ? _voteWeight : 0);
    assertEq(_abstainVotesExpressed, _supportType == uint8(VoteType.Abstain) ? _voteWeight : 0);

    // no votes have been cast yet
    (uint256 _againstVotes, uint256 _forVotes, uint256 _abstainVotes) =
      governor.proposalVotes(_proposalId);
    assertEq(_forVotes, 0);
    assertEq(_againstVotes, 0);
    assertEq(_abstainVotes, 0);

    // wait until after the voting period
    vm.roll(pool.internalVotingPeriodEnd(_proposalId) + 1);

    // submit votes on behalf of the pool
    pool.castVote(_proposalId);

    // governor should now record votes from the pool
    (_againstVotes, _forVotes, _abstainVotes) = governor.proposalVotes(_proposalId);
    assertEq(_forVotes, _forVotesExpressed);
    assertEq(_againstVotes, _againstVotesExpressed);
    assertEq(_abstainVotes, _abstainVotesExpressed);
  }

  function testFuzz_UserCannotExpressVotesWithoutWeightInPool(
    address _hodler,
    uint256 _voteWeight,
    uint8 _supportType
  ) public {
    _voteWeight = _commonFuzzerAssumptions(_hodler, _voteWeight, _supportType);

    // Mint gov but do not deposit
    _mintGovAndApprovePool(_hodler, _voteWeight);
    assertEq(token.balanceOf(_hodler), _voteWeight);
    assertEq(pool.deposits(_hodler), 0);

    // create the proposal
    uint256 _proposalId = _createAndSubmitProposal();

    // _holder should NOT be able to express his/her vote on the proposal
    vm.expectRevert(bytes("no weight"));
    vm.prank(_hodler);
    pool.expressVote(_proposalId, uint8(_supportType));
  }

  function testFuzz_UserCannotCastAfterVotingPeriod(
    address _hodler,
    uint256 _voteWeight,
    uint8 _supportType
  ) public {
    _voteWeight = _commonFuzzerAssumptions(_hodler, _voteWeight, _supportType);

    // Deposit some funds.
    _mintGovAndDepositIntoPool(_hodler, _voteWeight);

    // Create the proposal.
    uint256 _proposalId = _createAndSubmitProposal();

    // Express vote preference.
    vm.prank(_hodler);
    pool.expressVote(_proposalId, _supportType);

    // Jump ahead so that we're outside of the proposal's voting period.
    vm.roll(governor.proposalDeadline(_proposalId) + 1);

    // We should not be able to castVote at this point.
    vm.expectRevert(bytes("Governor: vote not currently active"));
    pool.castVote(_proposalId);
  }

  function testFuzz_NoDoubleVoting(address _hodler, uint256 _voteWeight, uint8 _supportType) public {
    _voteWeight = _commonFuzzerAssumptions(_hodler, _voteWeight, _supportType);

    // Deposit some funds.
    _mintGovAndDepositIntoPool(_hodler, _voteWeight);

    // create the proposal
    uint256 _proposalId = _createAndSubmitProposal();

    // _holder should now be able to express his/her vote on the proposal
    vm.prank(_hodler);
    pool.expressVote(_proposalId, _supportType);

    (
      uint256 _againstVotesExpressedInit,
      uint256 _forVotesExpressedInit,
      uint256 _abstainVotesExpressedInit
    ) = pool.proposalVotes(_proposalId);
    assertEq(_forVotesExpressedInit, _supportType == uint8(VoteType.For) ? _voteWeight : 0);
    assertEq(_againstVotesExpressedInit, _supportType == uint8(VoteType.Against) ? _voteWeight : 0);
    assertEq(_abstainVotesExpressedInit, _supportType == uint8(VoteType.Abstain) ? _voteWeight : 0);

    // vote early and often
    vm.expectRevert(bytes("already voted"));
    vm.prank(_hodler);
    pool.expressVote(_proposalId, _supportType);

    // no votes changed
    (uint256 _againstVotesExpressed, uint256 _forVotesExpressed, uint256 _abstainVotesExpressed) =
      pool.proposalVotes(_proposalId);
    assertEq(_forVotesExpressed, _forVotesExpressedInit);
    assertEq(_againstVotesExpressed, _againstVotesExpressedInit);
    assertEq(_abstainVotesExpressed, _abstainVotesExpressedInit);
  }

  function testFuzz_UsersCannotExpressVotesPriorToDepositing(
    address _hodler,
    uint256 _voteWeight,
    uint8 _supportType
  ) public {
    _voteWeight = _commonFuzzerAssumptions(_hodler, _voteWeight, _supportType);

    // Create the proposal *before* the user deposits anything.
    uint256 _proposalId = _createAndSubmitProposal();

    // Deposit some funds.
    _mintGovAndDepositIntoPool(_hodler, _voteWeight);

    // Now try to express a voting preference on the proposal.
    assertEq(pool.deposits(_hodler), _voteWeight);
    vm.expectRevert(bytes("no weight"));
    vm.prank(_hodler);
    pool.expressVote(_proposalId, _supportType);
  }

  function testFuzz_VotingWeightIsSnapshotDependent(
    address _hodler,
    uint256 _voteWeightA,
    uint256 _voteWeightB,
    uint8 _supportType
  ) public {
    _voteWeightA = _commonFuzzerAssumptions(_hodler, _voteWeightA, _supportType);
    _voteWeightB = _commonFuzzerAssumptions(_hodler, _voteWeightB, _supportType);

    // Deposit some funds.
    _mintGovAndDepositIntoPool(_hodler, _voteWeightA);

    // Create the proposal.
    uint256 _proposalId = _createAndSubmitProposal();

    // Sometime later the user deposits some more.
    vm.roll(governor.proposalDeadline(_proposalId) - 1);
    _mintGovAndDepositIntoPool(_hodler, _voteWeightB);

    vm.prank(_hodler);
    pool.expressVote(_proposalId, _supportType);

    // The internal proposal vote weight should not reflect the new deposit weight.
    (uint256 _againstVotesExpressed, uint256 _forVotesExpressed, uint256 _abstainVotesExpressed) =
      pool.proposalVotes(_proposalId);
    assertEq(_forVotesExpressed, _supportType == uint8(VoteType.For) ? _voteWeightA : 0);
    assertEq(_againstVotesExpressed, _supportType == uint8(VoteType.Against) ? _voteWeightA : 0);
    assertEq(_abstainVotesExpressed, _supportType == uint8(VoteType.Abstain) ? _voteWeightA : 0);

    // Submit votes on behalf of the pool.
    pool.castVote(_proposalId);

    // Votes cast should likewise reflect only the earlier balance.
    (uint256 _againstVotes, uint256 _forVotes, uint256 _abstainVotes) =
      governor.proposalVotes(_proposalId);
    assertEq(_forVotes, _supportType == uint8(VoteType.For) ? _voteWeightA : 0);
    assertEq(_againstVotes, _supportType == uint8(VoteType.Against) ? _voteWeightA : 0);
    assertEq(_abstainVotes, _supportType == uint8(VoteType.Abstain) ? _voteWeightA : 0);
  }

  function testFuzz_MultipleUsersCanCastVotes(
    address _hodlerA,
    address _hodlerB,
    uint256 _voteWeightA,
    uint256 _voteWeightB
  ) public {
    // This max is a limitation of the fractional governance protocol storage.
    _voteWeightA = bound(_voteWeightA, 1, type(uint120).max);
    _voteWeightB = bound(_voteWeightB, 1, type(uint120).max);

    vm.assume(_hodlerA != address(pool));
    vm.assume(_hodlerB != address(pool));
    vm.assume(_hodlerA != _hodlerB);

    // Deposit some funds.
    _mintGovAndDepositIntoPool(_hodlerA, _voteWeightA);
    _mintGovAndDepositIntoPool(_hodlerB, _voteWeightB);

    // create the proposal
    uint256 _proposalId = _createAndSubmitProposal();

    // Hodlers should now be able to express their votes on the proposal
    vm.prank(_hodlerA);
    pool.expressVote(_proposalId, uint8(VoteType.Against));
    vm.prank(_hodlerB);
    pool.expressVote(_proposalId, uint8(VoteType.Abstain));

    (uint256 _againstVotesExpressed, uint256 _forVotesExpressed, uint256 _abstainVotesExpressed) =
      pool.proposalVotes(_proposalId);
    assertEq(_forVotesExpressed, 0);
    assertEq(_againstVotesExpressed, _voteWeightA);
    assertEq(_abstainVotesExpressed, _voteWeightB);

    // the governor should have not recieved any votes yet
    (uint256 _againstVotes, uint256 _forVotes, uint256 _abstainVotes) =
      governor.proposalVotes(_proposalId);
    assertEq(_forVotes, 0);
    assertEq(_againstVotes, 0);
    assertEq(_abstainVotes, 0);

    // wait until after the voting period
    vm.roll(pool.internalVotingPeriodEnd(_proposalId) + 1);

    // submit votes on behalf of the pool
    pool.castVote(_proposalId);

    // governor should now record votes for the pool
    (_againstVotes, _forVotes, _abstainVotes) = governor.proposalVotes(_proposalId);
    assertEq(_forVotes, 0);
    assertEq(_againstVotes, _voteWeightA);
    assertEq(_abstainVotes, _voteWeightB);
  }

  function testFuzz_UserCannotMakeThePoolCastVotesImmediatelyAfterVoting(
    address _hodler,
    uint256 _voteWeight,
    uint8 _supportType
  ) public {
    _voteWeight = _commonFuzzerAssumptions(_hodler, _voteWeight, _supportType);

    // Deposit some funds.
    _mintGovAndDepositIntoPool(_hodler, _voteWeight);

    // Create the proposal.
    uint256 _proposalId = _createAndSubmitProposal();

    // Express vote.
    vm.prank(_hodler);
    pool.expressVote(_proposalId, _supportType);

    // The pool's internal voting period has not passed
    assert(pool.internalVotingPeriodEnd(_proposalId) > block.number);

    // Try to submit votes on behalf of the pool.
    vm.expectRevert(bytes("cannot castVote yet"));
    pool.castVote(_proposalId);
  }

  function testFuzz_CannotCastVotesTwice(address _hodler, uint256 _voteWeight, uint8 _supportType)
    public
  {
    _voteWeight = _commonFuzzerAssumptions(_hodler, _voteWeight, _supportType);

    // Deposit some funds.
    _mintGovAndDepositIntoPool(_hodler, _voteWeight);

    // Create the proposal.
    uint256 _proposalId = _createAndSubmitProposal();

    // _holder should now be able to express his/her vote on the proposal
    vm.prank(_hodler);
    pool.expressVote(_proposalId, _supportType);

    // Wait until after the voting period.
    vm.roll(pool.internalVotingPeriodEnd(_proposalId) + 1);

    // Submit votes on behalf of the pool.
    pool.castVote(_proposalId);

    // Try to submit them again.
    vm.expectRevert(bytes("GovernorCountingFractional: all weight cast"));
    pool.castVote(_proposalId);
  }

  struct VoteWeightIsScaledTestVars {
    address userA;
    address userB;
    address userC;
    address userD;
    uint256 voteWeightA;
    uint8 supportTypeA;
    uint256 voteWeightB;
    uint8 supportTypeB;
    uint256 borrowAmountC;
    uint256 borrowAmountD;
  }

  function testFuzz_VoteWeightIsScaledBasedOnPoolBalance(VoteWeightIsScaledTestVars memory _vars)
    public
  {
    _vars.userA = address(0xbeef);
    _vars.userB = address(0xbabe);
    _vars.userC = address(0xf005ba11);
    _vars.userD = address(0xba5eba11);

    _vars.supportTypeA = uint8(bound(_vars.supportTypeA, 0, uint8(VoteType.Abstain)));
    _vars.supportTypeB = uint8(bound(_vars.supportTypeB, 0, uint8(VoteType.Abstain)));

    _vars.voteWeightA = bound(_vars.voteWeightA, 1e4, type(uint128).max - 1e4 - 1);
    _vars.voteWeightB = bound(_vars.voteWeightB, 1e4, type(uint128).max - _vars.voteWeightA - 1);

    uint256 _maxBorrowWeight = _vars.voteWeightA + _vars.voteWeightB;
    _vars.borrowAmountC = bound(_vars.borrowAmountC, 1, _maxBorrowWeight - 1);
    _vars.borrowAmountD = bound(_vars.borrowAmountD, 1, _maxBorrowWeight - _vars.borrowAmountC);

    // These are here just as a sanity check that all of the bounding above worked.
    vm.assume(_vars.voteWeightA + _vars.voteWeightB < type(uint128).max);
    vm.assume(_vars.voteWeightA + _vars.voteWeightB >= _vars.borrowAmountC + _vars.borrowAmountD);

    // Mint and deposit.
    _mintGovAndDepositIntoPool(_vars.userA, _vars.voteWeightA);
    _mintGovAndDepositIntoPool(_vars.userB, _vars.voteWeightB);
    uint256 _initDepositWeight = token.balanceOf(address(pool));

    // Borrow from the pool, decreasing its token balance.
    vm.prank(_vars.userC);
    pool.borrow(_vars.borrowAmountC);

    // Create the proposal.
    uint256 _proposalId = _createAndSubmitProposal();

    // Jump ahead to the proposal snapshot to lock in the pool's balance.
    vm.roll(governor.proposalSnapshot(_proposalId) + 1);
    uint256 _expectedVotingWeight = token.balanceOf(address(pool));
    assert(_expectedVotingWeight < _initDepositWeight);

    // A+B express votes
    vm.prank(_vars.userA);
    pool.expressVote(_proposalId, _vars.supportTypeA);
    vm.prank(_vars.userB);
    pool.expressVote(_proposalId, _vars.supportTypeB);

    // Borrow more from the pool, just to confirm that the vote weight will be based
    // on the snapshot blocktime/number.
    vm.prank(_vars.userD);
    pool.borrow(_vars.borrowAmountD);

    // Wait until after the pool's voting period closes.
    vm.roll(pool.internalVotingPeriodEnd(_proposalId) + 1);

    // Submit votes on behalf of the pool.
    pool.castVote(_proposalId);

    // Vote should be cast as a percentage of the depositer's expressed types, since
    // the actual weight is different from the deposit weight.
    (uint256 _againstVotes, uint256 _forVotes, uint256 _abstainVotes) =
      governor.proposalVotes(_proposalId);

    // These can differ because votes are rounded.
    assertApproxEqAbs(_againstVotes + _forVotes + _abstainVotes, _expectedVotingWeight, 1);

    if (_vars.supportTypeA == _vars.supportTypeB) {
      assertEq(_forVotes, _vars.supportTypeA == uint8(VoteType.For) ? _expectedVotingWeight : 0);
      assertEq(
        _againstVotes, _vars.supportTypeA == uint8(VoteType.Against) ? _expectedVotingWeight : 0
      );
      assertEq(
        _abstainVotes, _vars.supportTypeA == uint8(VoteType.Abstain) ? _expectedVotingWeight : 0
      );
    } else {
      uint256 _expectedVotingWeightA =
        (_vars.voteWeightA * _expectedVotingWeight) / _initDepositWeight;
      uint256 _expectedVotingWeightB =
        (_vars.voteWeightB * _expectedVotingWeight) / _initDepositWeight;

      // We assert the weight is within a range of 1 because scaled weights are sometimes floored.
      if (_vars.supportTypeA == uint8(VoteType.For)) {
        assertApproxEqAbs(_forVotes, _expectedVotingWeightA, 1);
      }
      if (_vars.supportTypeB == uint8(VoteType.For)) {
        assertApproxEqAbs(_forVotes, _expectedVotingWeightB, 1);
      }
      if (_vars.supportTypeA == uint8(VoteType.Against)) {
        assertApproxEqAbs(_againstVotes, _expectedVotingWeightA, 1);
      }
      if (_vars.supportTypeB == uint8(VoteType.Against)) {
        assertApproxEqAbs(_againstVotes, _expectedVotingWeightB, 1);
      }
      if (_vars.supportTypeA == uint8(VoteType.Abstain)) {
        assertApproxEqAbs(_abstainVotes, _expectedVotingWeightA, 1);
      }
      if (_vars.supportTypeB == uint8(VoteType.Abstain)) {
        assertApproxEqAbs(_abstainVotes, _expectedVotingWeightB, 1);
      }
    }
  }

  function testFuzz_VotingWeightIsAbandonedIfSomeoneDoesntExpress(
    uint256 _voteWeightA,
    uint256 _voteWeightB,
    uint8 _supportTypeA,
    uint256 _borrowAmount
  ) public {
    // We need to do this to prevent:
    // "CompilerError: Stack too deep, try removing local variables."
    address[3] memory _userArray = [
      address(0xbeef), // userA
      address(0xbabe), // userB
      address(0xf005ba11) // userC
    ];
    _voteWeightA = _commonFuzzerAssumptions(_userArray[0], _voteWeightA, _supportTypeA);
    _voteWeightB = _commonFuzzerAssumptions(_userArray[1], _voteWeightB);
    _borrowAmount = _commonFuzzerAssumptions(_userArray[2], _borrowAmount);

    _voteWeightA = bound(_voteWeightA, 0, type(uint128).max);
    _voteWeightB = bound(_voteWeightB, 0, type(uint128).max - _voteWeightA);
    vm.assume(_voteWeightA + _voteWeightB < type(uint128).max);
    vm.assume(_voteWeightA + _voteWeightB > _borrowAmount);

    // Mint and deposit.
    _mintGovAndDepositIntoPool(_userArray[0], _voteWeightA);
    _mintGovAndDepositIntoPool(_userArray[1], _voteWeightB);
    uint256 _initDepositWeight = token.balanceOf(address(pool));

    // Borrow from the pool, decreasing its token balance.
    vm.prank(_userArray[2]);
    pool.borrow(_borrowAmount);

    // Create the proposal.
    uint256 _proposalId = _createAndSubmitProposal();

    // Jump ahead to the proposal snapshot to lock in the pool's balance.
    vm.roll(governor.proposalSnapshot(_proposalId) + 1);
    uint256 _totalPossibleVotingWeight = token.balanceOf(address(pool));

    uint256 _fullVotingWeight = token.balanceOf(address(pool));
    assert(_fullVotingWeight < _initDepositWeight);
    assertEq(_fullVotingWeight, _voteWeightA + _voteWeightB - _borrowAmount);

    // Only user A expresses a vote.
    vm.prank(_userArray[0]);
    pool.expressVote(_proposalId, _supportTypeA);

    // Wait until after the pool's voting period closes.
    vm.roll(pool.internalVotingPeriodEnd(_proposalId) + 1);

    // Submit votes on behalf of the pool.
    pool.castVote(_proposalId);

    // Vote should be cast as a percentage of the depositer's expressed types, since
    // the actual weight is different from the deposit weight.
    (uint256 _againstVotes, uint256 _forVotes, uint256 _abstainVotes) =
      governor.proposalVotes(_proposalId);

    uint256 _expectedVotingWeightA = (_voteWeightA * _fullVotingWeight) / _initDepositWeight;
    uint256 _expectedVotingWeightB = (_voteWeightB * _fullVotingWeight) / _initDepositWeight;

    // The pool *could* have voted with this much weight.
    assertApproxEqAbs(
      _totalPossibleVotingWeight, _expectedVotingWeightA + _expectedVotingWeightB, 1
    );

    // Actually, though, the pool did not vote with all of the weight it could have.
    // VoterB's votes were never cast because he/she did not express his/her preference.
    assertApproxEqAbs(
      _againstVotes + _forVotes + _abstainVotes, // The total actual weight.
      _expectedVotingWeightA, // VoterB's weight has been abandoned, only A's is counted.
      1
    );

    // We assert the weight is within a range of 1 because scaled weights are sometimes floored.
    if (_supportTypeA == uint8(VoteType.For)) {
      assertApproxEqAbs(_forVotes, _expectedVotingWeightA, 1);
    }
    if (_supportTypeA == uint8(VoteType.Against)) {
      assertApproxEqAbs(_againstVotes, _expectedVotingWeightA, 1);
    }
    if (_supportTypeA == uint8(VoteType.Abstain)) {
      assertApproxEqAbs(_abstainVotes, _expectedVotingWeightA, 1);
    }
  }

  function testFuzz_VotingWeightIsUnaffectedByDepositsAfterProposal(
    uint256 _voteWeightA,
    uint256 _voteWeightB,
    uint8 _supportTypeA
  ) public {
    // We need to do this to prevent:
    // "CompilerError: Stack too deep, try removing local variables."
    address[3] memory _userArray = [
      address(0xbeef), // userA
      address(0xbabe), // userB
      address(0xf005ba11) // userC
    ];
    _voteWeightA = _commonFuzzerAssumptions(_userArray[0], _voteWeightA, _supportTypeA);
    _voteWeightB = _commonFuzzerAssumptions(_userArray[1], _voteWeightB);

    vm.assume(_voteWeightA + _voteWeightB < type(uint128).max);

    // Mint and deposit for just userA.
    _mintGovAndDepositIntoPool(_userArray[0], _voteWeightA);
    uint256 _initDepositWeight = token.balanceOf(address(pool));

    // Create the proposal.
    uint256 _proposalId = _createAndSubmitProposal();

    // Jump ahead to the proposal snapshot to lock in the pool's balance.
    vm.roll(governor.proposalSnapshot(_proposalId) + 1);

    // Now mint and deposit for userB.
    _mintGovAndDepositIntoPool(_userArray[1], _voteWeightB);

    uint256 _fullVotingWeight = token.balanceOf(address(pool));
    assert(_fullVotingWeight > _initDepositWeight);
    assertEq(_fullVotingWeight, _voteWeightA + _voteWeightB);

    // Only user A expresses a vote.
    vm.prank(_userArray[0]);
    pool.expressVote(_proposalId, _supportTypeA);

    // Wait until after the pool's voting period closes.
    vm.roll(pool.internalVotingPeriodEnd(_proposalId) + 1);

    // Submit votes on behalf of the pool.
    pool.castVote(_proposalId);

    (uint256 _againstVotes, uint256 _forVotes, uint256 _abstainVotes) =
      governor.proposalVotes(_proposalId);

    // We assert the weight is within a range of 1 because scaled weights are sometimes floored.
    if (_supportTypeA == uint8(VoteType.For)) assertEq(_forVotes, _voteWeightA);
    if (_supportTypeA == uint8(VoteType.Against)) assertEq(_againstVotes, _voteWeightA);
    if (_supportTypeA == uint8(VoteType.Abstain)) assertEq(_abstainVotes, _voteWeightA);
  }

  //TODO what if someone tries to express a vote after the voting window?
  // seems like there's not much point preventing it
}

contract Borrow is FractionalPoolTest {
  function testFuzz_UsersCanBorrowTokens(
    address _lender,
    uint256 _lendAmount,
    address _borrower,
    uint256 _borrowAmount
  ) public {
    vm.assume(_borrower != address(0));
    _lendAmount = _commonFuzzerAssumptions(_lender, _lendAmount);
    _borrowAmount = _commonFuzzerAssumptions(_borrower, _borrowAmount);
    vm.assume(_lendAmount > _borrowAmount);

    // Deposit some funds.
    _mintGovAndDepositIntoPool(_lender, _lendAmount);

    // Borrow some funds.
    uint256 _initBalance = token.balanceOf(_borrower);
    vm.prank(_borrower);
    pool.borrow(_borrowAmount);

    // Tokens should have been transferred.
    assertEq(token.balanceOf(_borrower), _initBalance + _borrowAmount);
    assertEq(token.balanceOf(address(pool)), _lendAmount - _borrowAmount);

    // Borrow total has been tracked.
    assertEq(pool.borrowTotal(_borrower), _borrowAmount);

    // The deposit balance of the lender should not have changed.
    assertEq(pool.deposits(_lender), _lendAmount);

    // The total deposit snapshot should not have changed.
    uint256 _blockAtTimeOfBorrow = block.number;
    vm.roll(_blockAtTimeOfBorrow + 42); // Advance so the block is mined.
    assertEq(pool.getPastTotalDeposits(_blockAtTimeOfBorrow), _lendAmount);
  }
}

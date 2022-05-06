// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import { DSTestPlus } from "solmate/test/utils/DSTestPlus.sol";
import { Vm } from "forge-std/Vm.sol";
import { FractionalPool, IVotingToken, IFractionalGovernor } from "../src/FractionalPool.sol";
import "./GovToken.sol";
import "./FractionalGovernor.sol";
import "./ProposalReceiverMock.sol";


contract FractionalPoolTest is DSTestPlus {
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

    Vm vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

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
        token.THIS_IS_JUST_A_TEST_HOOK_mint(_holder, _amount);
        vm.prank(_holder);
        token.approve(address(pool), type(uint256).max);
    }

    function _mintGovAndDepositIntoPool(address _address, uint256 _amount) internal {
      _mintGovAndApprovePool(_address, _amount);
      vm.prank(_address);
      pool.deposit(_amount);
    }

    function _createAndSubmitProposal() internal returns(uint256 proposalId) {
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
      assertEq(uint(governor.state(proposalId)), uint(ProposalState.Pending));

      // advance proposal to active state
      vm.roll(governor.proposalSnapshot(proposalId) + 1);
      assertEq(uint(governor.state(proposalId)), uint(ProposalState.Active));
    }

    function _commonFuzzerAssumptions(address _address, uint256 _voteWeight) public returns(uint256) {
      return _commonFuzzerAssumptions(_address, _voteWeight, uint8(VoteType.Against));
    }

    function _commonFuzzerAssumptions(address _address, uint256 _voteWeight, uint8 _supportType) public returns(uint256) {
        vm.assume(_address != address(pool));
        vm.assume(_supportType <= uint8(VoteType.Abstain)); // couldn't get fuzzer to work w/ the enum
        // This max is a limitation of the fractional governance protocol storage.
        return bound(_voteWeight, 1, type(uint128).max);
    }

    function _assertWithinRange(uint256 amount, uint256 target, uint256 range) public {
      if (amount > target) assert(amount - target <= range);
      if (amount < target) assert(target - amount <= range);
      if (amount == target) assertEq(amount, target);
    }
}

contract Deployment is FractionalPoolTest {

    function test_FractionalPoolDeployment() public {
        assertEq(token.name(), "Governance Token");
        assertEq(token.symbol(), "GOV");

        assertEq(address(pool.token()), address(token));
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
      address _holderA,
      address _holderB,
      uint256 _amountA,
      uint256 _amountB,
      uint24 _depositDelay
    ) public {
        _amountA = bound(_amountA, 1, type(uint128).max);
        _amountB = bound(_amountB, 1, type(uint128).max);
        vm.assume(_holderA != _holderB);

        _mintGovAndDepositIntoPool(_holderA, _amountA);
        assertEq(token.balanceOf(_holderA), 0); // they've all been deposited
        assert(token.balanceOf(address(pool)) > token.balanceOf(_holderA));

        vm.roll(block.number + 42); // advance so that we can look at checkpoints

        // We can still retrieve the user's balance at the given time.
        assertEq(pool.getPastDeposits(_holderA, block.number - 1), _amountA);

        uint256 newBlockNum = block.number + _depositDelay;
        vm.roll(newBlockNum);

        // Deposit some more.
        _mintGovAndDepositIntoPool(_holderA, _amountB);

        vm.roll(block.number + 42); // advance so that we can look at checkpoints
        assertEq(pool.getPastDeposits(_holderA, block.number - 1), _amountA + _amountB);
    }

}

contract Vote is FractionalPoolTest {
    function testFuzz_UserCanCastVotes(
      address _hodler,
      uint256 _voteWeight,
      uint8 _supportType
    ) public {
        _voteWeight = _commonFuzzerAssumptions(_hodler, _voteWeight, _supportType);

        // Deposit some funds.
        _mintGovAndDepositIntoPool(_hodler, _voteWeight);

        // create the proposal
        uint256 _proposalId = _createAndSubmitProposal();

        // _holder should now be able to express his/her vote on the proposal
        vm.prank(_hodler);
        pool.expressVote(_proposalId, _supportType);
        (
          uint256 _againstVotesExpressed,
          uint256 _forVotesExpressed,
          uint256 _abstainVotesExpressed
        ) = pool.proposalVotes(_proposalId);
        assertEq(_forVotesExpressed, _supportType == uint8(VoteType.For) ? _voteWeight : 0);
        assertEq(_againstVotesExpressed, _supportType == uint8(VoteType.Against) ? _voteWeight : 0);
        assertEq(_abstainVotesExpressed, _supportType == uint8(VoteType.Abstain) ? _voteWeight : 0);

        // no votes have been cast yet
        (uint256 _againstVotes, uint256 _forVotes, uint256 _abstainVotes) = governor.proposalVotes(_proposalId);
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

    function testFuzz_UserCannotCastWithoutWeightInPool(
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

    function testFuzz_NoDoubleVoting(
      address _hodler,
      uint256 _voteWeight,
      uint8 _supportType
    ) public {
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
        (
          uint256 _againstVotesExpressed,
          uint256 _forVotesExpressed,
          uint256 _abstainVotesExpressed
        ) = pool.proposalVotes(_proposalId);
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
        (
          uint256 _againstVotesExpressed,
          uint256 _forVotesExpressed,
          uint256 _abstainVotesExpressed
        ) = pool.proposalVotes(_proposalId);
        assertEq(_forVotesExpressed,     _supportType == uint8(VoteType.For)     ? _voteWeightA : 0);
        assertEq(_againstVotesExpressed, _supportType == uint8(VoteType.Against) ? _voteWeightA : 0);
        assertEq(_abstainVotesExpressed, _supportType == uint8(VoteType.Abstain) ? _voteWeightA : 0);

        // Submit votes on behalf of the pool.
        pool.castVote(_proposalId);

        // Votes cast should likewise reflect only the earlier balance.
        (uint _againstVotes, uint _forVotes, uint _abstainVotes) = governor.proposalVotes(_proposalId);
        assertEq(_forVotes,     _supportType == uint8(VoteType.For)     ? _voteWeightA : 0);
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

        (
          uint256 _againstVotesExpressed,
          uint256 _forVotesExpressed,
          uint256 _abstainVotesExpressed
        ) = pool.proposalVotes(_proposalId);
        assertEq(_forVotesExpressed, 0);
        assertEq(_againstVotesExpressed, _voteWeightA);
        assertEq(_abstainVotesExpressed, _voteWeightB);

        // the governor should have not recieved any votes yet
        (uint256 _againstVotes, uint256 _forVotes, uint256 _abstainVotes) = governor.proposalVotes(_proposalId);
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

    function testFuzz_CannotCastVotesTwice(
      address _hodler,
      uint256 _voteWeight,
      uint8 _supportType
    ) public {
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
        vm.expectRevert(bytes("GovernorCountingFractional: vote already cast"));
        pool.castVote(_proposalId);
    }

    function testFuzz_VoteWeightIsScaledBasedOnPoolBalance(
      uint256 _voteWeightA,
      uint8 _supportTypeA,
      uint256 _voteWeightB,
      uint8 _supportTypeB,
      uint256 _borrowAmountC,
      uint256 _borrowAmountD
    ) public {
        // We need to do this to prevent:
        // "CompilerError: Stack too deep, try removing local variables."
        address[4] memory _userArray = [
          address(0xbeef), // userA
          address(0xbabe), // userB
          address(0xf005ba11), // userC
          address(0xba5eba11) // userD
        ];
        _voteWeightA = _commonFuzzerAssumptions(_userArray[0], _voteWeightA, _supportTypeA);
        _voteWeightB = _commonFuzzerAssumptions(_userArray[1], _voteWeightB, _supportTypeB);
        _borrowAmountC = _commonFuzzerAssumptions(_userArray[2], _borrowAmountC);
        _borrowAmountD = _commonFuzzerAssumptions(_userArray[3], _borrowAmountD);
        vm.assume(_voteWeightA + _voteWeightB < type(uint128).max);
        vm.assume(_voteWeightA + _voteWeightB > _borrowAmountC + _borrowAmountD);

        // Mint and deposit.
        _mintGovAndDepositIntoPool(_userArray[0], _voteWeightA);
        _mintGovAndDepositIntoPool(_userArray[1], _voteWeightB);
        uint256 _initDepositWeight = token.balanceOf(address(pool));

        // Borrow from the pool, decreasing its token balance.
        vm.prank(_userArray[2]);
        pool.borrow(_borrowAmountC);

        // Create the proposal.
        uint256 _proposalId = _createAndSubmitProposal();

        // Jump ahead to the proposal snapshot to lock in the pool's balance.
        vm.roll(governor.proposalSnapshot(_proposalId) + 1);
        uint256 _expectedVotingWeight = token.balanceOf(address(pool));
        assert(_expectedVotingWeight < _initDepositWeight);

        // A+B express votes
        vm.prank(_userArray[0]);
        pool.expressVote(_proposalId, _supportTypeA);
        vm.prank(_userArray[1]);
        pool.expressVote(_proposalId, _supportTypeB);

        // Borrow more from the pool, just to confirm that the vote weight will be based
        // on the snapshot blocktime/number.
        vm.prank(_userArray[3]);
        pool.borrow(_borrowAmountD);

        // Wait until after the pool's voting period closes.
        vm.roll(pool.internalVotingPeriodEnd(_proposalId) + 1);

        // Submit votes on behalf of the pool.
        pool.castVote(_proposalId);

        // Vote should be cast as a percentage of the depositer's expressed types, since
        // the actual weight is different from the deposit weight.
        (
          uint256 _againstVotes,
          uint256 _forVotes,
          uint256 _abstainVotes
        ) = governor.proposalVotes(_proposalId);

        assertEq(_againstVotes + _forVotes + _abstainVotes, _expectedVotingWeight);

        if (_supportTypeA == _supportTypeB) {
          assertEq(_forVotes,     _supportTypeA == uint8(VoteType.For)     ? _expectedVotingWeight : 0);
          assertEq(_againstVotes, _supportTypeA == uint8(VoteType.Against) ? _expectedVotingWeight : 0);
          assertEq(_abstainVotes, _supportTypeA == uint8(VoteType.Abstain) ? _expectedVotingWeight : 0);
        } else {
          uint256 _expectedVotingWeightA = (_voteWeightA * _expectedVotingWeight) / _initDepositWeight;
          uint256 _expectedVotingWeightB = (_voteWeightB * _expectedVotingWeight) / _initDepositWeight;

          if (_supportTypeA == uint8(VoteType.For)) _assertWithinRange(_forVotes, _expectedVotingWeightA, 1);
          if (_supportTypeB == uint8(VoteType.For)) _assertWithinRange(_forVotes, _expectedVotingWeightB, 1);
          if (_supportTypeA == uint8(VoteType.Against)) _assertWithinRange(_againstVotes, _expectedVotingWeightA, 1);
          if (_supportTypeB == uint8(VoteType.Against)) _assertWithinRange(_againstVotes, _expectedVotingWeightB, 1);
          if (_supportTypeA == uint8(VoteType.Abstain)) _assertWithinRange(_abstainVotes, _expectedVotingWeightA, 1);
          if (_supportTypeB == uint8(VoteType.Abstain)) _assertWithinRange(_abstainVotes, _expectedVotingWeightB, 1);
        }
    }

    //TODO what if someone tries to express a vote after the voting window?
    // seems like there's not much point preventing it
}

contract Borrow is FractionalPoolTest {
  // does checkpoint the total deposit amount
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

      // Withdrawal total has been tracked
      assertEq(pool.borrowTotal(_borrower), _borrowAmount);

      // The deposit balance of the lender should not have changed.
      assertEq(pool.deposits(_lender), _lendAmount);
  }
}

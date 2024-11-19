// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {IVotes} from "@openzeppelin/contracts/governance/utils/IVotes.sol";
import {IGovernor} from "@openzeppelin/contracts/governance/Governor.sol";

import {IVotingToken} from "src/interfaces/IVotingToken.sol";
import {IFractionalGovernor} from "src/interfaces/IFractionalGovernor.sol";
import {GovernorCountingFractional as GCF} from "src/GovernorCountingFractional.sol";
import {MockFlexVotingClient} from "test/MockFlexVotingClient.sol";
import {GovToken} from "test/GovToken.sol";
import {FractionalGovernor} from "test/FractionalGovernor.sol";
import {ProposalReceiverMock} from "test/ProposalReceiverMock.sol";

contract FlexVotingClientTest is Test {
  MockFlexVotingClient flexClient;
  GovToken token;
  FractionalGovernor governor;
  ProposalReceiverMock receiver;

  // This max is a limitation of GovernorCountingFractional's vote storage size.
  // See GovernorCountingFractional.ProposalVote struct.
  uint256 MAX_VOTES = type(uint128).max;

  function setUp() public {
    token = new GovToken();
    vm.label(address(token), "token");

    governor = new FractionalGovernor("Governor", IVotes(token));
    vm.label(address(governor), "governor");

    flexClient = new MockFlexVotingClient(address(governor));
    vm.label(address(flexClient), "flexClient");

    receiver = new ProposalReceiverMock();
    vm.label(address(receiver), "receiver");
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
    if (block.number == 0) vm.roll(42);

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
    vm.roll(governor.proposalSnapshot(proposalId) + 1);
    assertEq(uint8(governor.state(proposalId)), uint8(IGovernor.ProposalState.Active));
  }

  function _assumeSafeUser(address _user) internal view {
    vm.assume(_user != address(flexClient));
    vm.assume(_user != address(0));
  }

  function _randVoteType(uint8 _seed) public pure returns (GCF.VoteType) {
    return GCF.VoteType(
      uint8(bound(uint256(_seed), uint256(type(GCF.VoteType).min), uint256(type(GCF.VoteType).max)))
    );
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
    returns (uint208 _boundedWeight, GCF.VoteType _boundedSupport)
  {
    _assumeSafeUser(_account);

    _boundedSupport = _randVoteType(_supportType);

    // This max is a limitation of the fractional governance protocol storage.
    _boundedWeight = uint208(bound(_voteWeight, 1, MAX_VOTES));
  }
}

contract Deployment is FlexVotingClientTest {
  function test_FlexVotingClientDeployment() public view {
    assertEq(token.name(), "Governance Token");
    assertEq(token.symbol(), "GOV");

    assertEq(address(flexClient.GOVERNOR()), address(governor));
    assertEq(token.delegates(address(flexClient)), address(flexClient));

    assertEq(governor.name(), "Governor");
    assertEq(address(governor.token()), address(token));
  }
}

contract Constructor is FlexVotingClientTest {
  function test_SetsGovernor() public view {
    assertEq(address(flexClient.GOVERNOR()), address(governor));
  }

  function test_SelfDelegates() public view {
    assertEq(token.delegates(address(flexClient)), address(flexClient));
  }
}

// Contract name has a leading underscore for scopelint spec support.
contract _RawBalanceOf is FlexVotingClientTest {
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
contract _CastVoteReasonString is FlexVotingClientTest {
  function test_ReturnsDescriptiveString() public {
    assertEq(
      flexClient.exposed_castVoteReasonString(), "rolled-up vote from governance token holders"
    );
  }
}

// Contract name has a leading underscore for scopelint spec support.
contract _SelfDelegate is FlexVotingClientTest {
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
contract _CheckpointRawBalanceOf is FlexVotingClientTest {
  function testFuzz_StoresTheRawBalanceWithTheBlockNumber(
    address _user,
    uint208 _amount,
    uint48 _blockNum
  ) public {
    vm.assume(_user != address(flexClient));
    _blockNum = uint48(bound(_blockNum, block.number + 1, type(uint48).max));
    _amount = uint208(bound(_amount, 1, MAX_VOTES));

    flexClient.exposed_setDeposits(_user, _amount);
    assertEq(flexClient.getPastRawBalance(_user, _blockNum), 0);

    vm.roll(_blockNum);
    flexClient.exposed_checkpointRawBalanceOf(_user);
    assertEq(flexClient.getPastRawBalance(_user, _blockNum), _amount);
  }
}

contract GetPastRawBalance is FlexVotingClientTest {
  function testFuzz_ReturnsZeroForUsersWithoutDeposits(
    address _depositor,
    address _nonDepositor,
    uint208 _amount
  ) public {
    vm.assume(_depositor != address(flexClient));
    vm.assume(_nonDepositor != address(flexClient));
    vm.assume(_nonDepositor != _depositor);
    _amount = uint208(bound(_amount, 1, MAX_VOTES));

    vm.roll(block.number + 1);
    assertEq(flexClient.getPastRawBalance(_depositor, 0), 0);
    assertEq(flexClient.getPastRawBalance(_nonDepositor, 0), 0);

    _mintGovAndDepositIntoFlexClient(_depositor, _amount);
    vm.roll(block.number + 1);

    assertEq(flexClient.getPastRawBalance(_depositor, block.number - 1), _amount);
    assertEq(flexClient.getPastRawBalance(_nonDepositor, block.number - 1), 0);
  }

  function testFuzz_ReturnsCurrentValueForFutureBlocks(
    address _user,
    uint208 _amount,
    uint48 _blockNum
  ) public {
    vm.assume(_user != address(flexClient));
    _blockNum = uint48(bound(_blockNum, block.number + 1, type(uint48).max));
    _amount = uint208(bound(_amount, 1, MAX_VOTES));

    _mintGovAndDepositIntoFlexClient(_user, _amount);

    assertEq(flexClient.getPastRawBalance(_user, block.number), _amount);
    assertEq(flexClient.getPastRawBalance(_user, _blockNum), _amount);
    vm.roll(_blockNum);
    assertEq(flexClient.getPastRawBalance(_user, block.number), _amount);
  }

  function testFuzz_ReturnsUserBalanceAtAGivenBlock(
    address _user,
    uint208 _amountA,
    uint208 _amountB,
    uint48 _blockNum
  ) public {
    vm.assume(_user != address(flexClient));
    _blockNum = uint48(bound(_blockNum, block.number + 1, type(uint48).max));
    _amountA = uint208(bound(_amountA, 1, MAX_VOTES));
    _amountB = uint208(bound(_amountB, 0, MAX_VOTES - _amountA));

    _mintGovAndDepositIntoFlexClient(_user, _amountA);
    vm.roll(_blockNum);
    _mintGovAndDepositIntoFlexClient(_user, _amountB);
    vm.roll(block.number + 1);

    uint48 _zeroBlock = 0;
    uint48 _initBlock = 1;
    assertEq(flexClient.getPastRawBalance(_user, _zeroBlock), 0);
    assertEq(flexClient.getPastRawBalance(_user, _initBlock), _amountA);
    assertEq(flexClient.getPastRawBalance(_user, _blockNum), _amountA + _amountB);
  }
}

contract GetPastTotalBalance is FlexVotingClientTest {
  function test_ReturnsZeroWithoutDeposits() public view {
    uint48 _zeroBlock = 0;
    uint48 _futureBlock = uint48(block.number) + 42;
    assertEq(flexClient.getPastTotalBalance(_zeroBlock), 0);
    assertEq(flexClient.getPastTotalBalance(_futureBlock), 0);
  }

  function testFuzz_ReturnsCurrentValueForFutureBlocks(
    address _user,
    uint208 _amount,
    uint48 _blockNum
  ) public {
    vm.assume(_user != address(flexClient));
    _blockNum = uint48(bound(_blockNum, block.number + 1, type(uint48).max));
    _amount = uint208(bound(_amount, 1, MAX_VOTES));

    _mintGovAndDepositIntoFlexClient(_user, _amount);

    assertEq(flexClient.getPastTotalBalance(block.number), _amount);
    assertEq(flexClient.getPastTotalBalance(_blockNum), _amount);
    vm.roll(_blockNum);
    assertEq(flexClient.getPastTotalBalance(block.number), _amount);
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

    vm.roll(block.number + 1);

    assertEq(flexClient.getPastTotalBalance(block.number), _amountA + _amountB);
  }

  function testFuzz_ReturnsTotalDepositsAtAGivenBlock(
    address _userA,
    uint208 _amountA,
    address _userB,
    uint208 _amountB,
    uint48 _blockNum
  ) public {
    vm.assume(_userA != address(flexClient));
    vm.assume(_userB != address(flexClient));
    vm.assume(_userA != _userB);
    _blockNum = uint48(bound(_blockNum, block.number + 1, type(uint48).max));

    _amountA = uint208(bound(_amountA, 1, MAX_VOTES));
    _amountB = uint208(bound(_amountB, 0, MAX_VOTES - _amountA));

    assertEq(flexClient.getPastTotalBalance(block.number), 0);

    _mintGovAndDepositIntoFlexClient(_userA, _amountA);
    vm.roll(_blockNum);
    _mintGovAndDepositIntoFlexClient(_userB, _amountB);

    assertEq(flexClient.getPastTotalBalance(block.number - _blockNum + 1), _amountA);
    assertEq(flexClient.getPastTotalBalance(block.number), _amountA + _amountB);
  }
  // parallel of last test for getPastRawBalance
}

contract Withdraw is FlexVotingClientTest {
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

contract Deposit is FlexVotingClientTest {
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

    vm.roll(block.number + 42); // Advance so that we can look at checkpoints.

    // We can still retrieve the user's balance at the given time.
    uint256 _checkpoint1 = block.number - 1;
    assertEq(
      flexClient.getPastRawBalance(_user, _checkpoint1),
      _amountA,
      "user's first deposit was not properly checkpointed"
    );

    uint256 newBlockNum = block.number + _depositDelay;
    vm.roll(newBlockNum);

    // Deposit some more.
    _mintGovAndDepositIntoFlexClient(_user, _amountB);
    assertEq(flexClient.deposits(_user), _amountA + _amountB);

    vm.roll(block.number + 42); // Advance so that we can look at checkpoints.

    assertEq(
      flexClient.getPastRawBalance(_user, _checkpoint1),
      _amountA,
      "user's first deposit was not properly checkpointed"
    );
    assertEq(
      flexClient.getPastRawBalance(_user, block.number - 1),
      _amountA + _amountB,
      "user's second deposit was not properly checkpointed"
    );
  }
}

contract ExpressVote is FlexVotingClientTest {
  function testFuzz_IncrementsInternalAccouting(
    address _user,
    uint208 _voteWeight,
    uint8 _supportType
  ) public {
    GCF.VoteType _voteType;
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
    assertEq(_forVotesExpressed, _voteType == GCF.VoteType.For ? _voteWeight : 0);
    assertEq(_againstVotesExpressed, _voteType == GCF.VoteType.Against ? _voteWeight : 0);
    assertEq(_abstainVotesExpressed, _voteType == GCF.VoteType.Abstain ? _voteWeight : 0);

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
    GCF.VoteType _voteType;
    (_voteWeight, _voteType) = _assumeSafeVoteParams(_user, _voteWeight, _supportType);

    // Create the proposal *before* the user deposits anything.
    uint256 _proposalId = _createAndSubmitProposal();

    // Deposit some funds.
    _mintGovAndDepositIntoFlexClient(_user, _voteWeight);

    // Now try to express a voting preference on the proposal.
    assertEq(flexClient.deposits(_user), _voteWeight);
    vm.expectRevert(bytes("no weight"));
    vm.prank(_user);
    flexClient.expressVote(_proposalId, uint8(_voteType));
  }

  function testFuzz_RevertWhen_NoClientWeightButTokenWeight(
    address _user,
    uint208 _voteWeight,
    uint8 _supportType
  ) public {
    GCF.VoteType _voteType;
    (_voteWeight, _voteType) = _assumeSafeVoteParams(_user, _voteWeight, _supportType);

    // Mint gov but do not deposit.
    _mintGovAndApproveFlexClient(_user, _voteWeight);
    assertEq(token.balanceOf(_user), _voteWeight);
    assertEq(flexClient.deposits(_user), 0);

    // Create the proposal.
    uint256 _proposalId = _createAndSubmitProposal();

    // _user should NOT be able to express his/her vote on the proposal.
    vm.expectRevert(bytes("no weight"));
    vm.prank(_user);
    flexClient.expressVote(_proposalId, uint8(_voteType));

    // Deposit into the client.
    vm.prank(_user);
    flexClient.deposit(_voteWeight);
    assertEq(flexClient.deposits(_user), _voteWeight);

    // _user should still NOT be able to express his/her vote on the proposal.
    // Despite having a deposit balance, he/she didn't have a balance at the
    // proposal snapshot.
    vm.expectRevert(bytes("no weight"));
    vm.prank(_user);
    flexClient.expressVote(_proposalId, uint8(_voteType));
  }

  function testFuzz_RevertOn_DoubleVotes(address _user, uint208 _voteWeight, uint8 _supportType)
    public
  {
    GCF.VoteType _voteType;
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
    assertEq(_forVotesExpressedInit, _voteType == GCF.VoteType.For ? _voteWeight : 0);
    assertEq(_againstVotesExpressedInit, _voteType == GCF.VoteType.Against ? _voteWeight : 0);
    assertEq(_abstainVotesExpressedInit, _voteType == GCF.VoteType.Abstain ? _voteWeight : 0);

    // Vote early and often!
    vm.expectRevert(bytes("already voted"));
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
    _supportType = uint8(bound(_supportType, uint256(type(GCF.VoteType).max) + 1, type(uint8).max));

    vm.assume(_user != address(flexClient));
    // This max is a limitation of the fractional governance protocol storage.
    _voteWeight = uint208(bound(_voteWeight, 1, MAX_VOTES));

    // Deposit some funds.
    _mintGovAndDepositIntoFlexClient(_user, _voteWeight);

    // Create the proposal.
    uint256 _proposalId = _createAndSubmitProposal();

    // Now try to express a voting preference with a bogus support type.
    vm.expectRevert(bytes("invalid support value, must be included in VoteType enum"));
    vm.prank(_user);
    flexClient.expressVote(_proposalId, _supportType);
  }

  function testFuzz_RevertOn_UnknownProposal(
    address _user,
    uint208 _voteWeight,
    uint8 _supportType,
    uint256 _proposalId
  )
    public
  {
    _assumeSafeUser(_user);
    _voteWeight = uint208(bound(_voteWeight, 1, MAX_VOTES));

    // Confirm that we've pulled a bogus proposal number.
    // This is the condition Governor.state checks for when raising
    // GovernorNonexistentProposal.
    vm.assume(governor.proposalSnapshot(_proposalId) == 0);

    // Force vote type to be unrecognized.
    _supportType = uint8(bound(_supportType, uint256(type(GCF.VoteType).max) + 1, type(uint8).max));

    // Deposit some funds.
    _mintGovAndDepositIntoFlexClient(_user, _voteWeight);

    // Create a real proposal to verify the two won't be mixed up when
    // expressing.
    uint256 _id = _createAndSubmitProposal();
    assert(_proposalId != _id);

    // Now try to express a voting preference on the bogus proposal.
    vm.expectRevert("no weight");
    vm.prank(_user);
    flexClient.expressVote(_proposalId, _supportType);
  }
}

contract CastVote is FlexVotingClientTest {
  function testFuzz_SubmitsVotesToGovernor(address _user, uint208 _voteWeight, uint8 _supportType)
    public
  {
    GCF.VoteType _voteType;
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
    assertEq(_forVotesExpressed, _voteType == GCF.VoteType.For ? _voteWeight : 0);
    assertEq(_againstVotesExpressed, _voteType == GCF.VoteType.Against ? _voteWeight : 0);
    assertEq(_abstainVotesExpressed, _voteType == GCF.VoteType.Abstain ? _voteWeight : 0);

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
    GCF.VoteType _voteType;
    (_voteWeightA, _voteType) = _assumeSafeVoteParams(_user, _voteWeightA, _supportType);
    _voteWeightB = _assumeSafeVoteParams(_user, _voteWeightB);

    // Deposit some funds.
    _mintGovAndDepositIntoFlexClient(_user, _voteWeightA);

    // Create the proposal.
    uint256 _proposalId = _createAndSubmitProposal();

    // Sometime later the user deposits some more.
    vm.roll(governor.proposalDeadline(_proposalId) - 1);
    _mintGovAndDepositIntoFlexClient(_user, _voteWeightB);

    vm.prank(_user);
    flexClient.expressVote(_proposalId, uint8(_voteType));

    // The internal proposal vote weight should not reflect the new deposit weight.
    (uint256 _againstVotesExpressed, uint256 _forVotesExpressed, uint256 _abstainVotesExpressed) =
      flexClient.proposalVotes(_proposalId);
    assertEq(_forVotesExpressed, _voteType == GCF.VoteType.For ? _voteWeightA : 0);
    assertEq(_againstVotesExpressed, _voteType == GCF.VoteType.Against ? _voteWeightA : 0);
    assertEq(_abstainVotesExpressed, _voteType == GCF.VoteType.Abstain ? _voteWeightA : 0);

    // Submit votes on behalf of the flexClient.
    flexClient.castVote(_proposalId);

    // Votes cast should likewise reflect only the earlier balance.
    (uint256 _againstVotes, uint256 _forVotes, uint256 _abstainVotes) =
      governor.proposalVotes(_proposalId);
    assertEq(_forVotes, _voteType == GCF.VoteType.For ? _voteWeightA : 0);
    assertEq(_againstVotes, _voteType == GCF.VoteType.Against ? _voteWeightA : 0);
    assertEq(_abstainVotes, _voteType == GCF.VoteType.Abstain ? _voteWeightA : 0);
  }

  function testFuzz_TracksMultipleUsersVotes(
    address _userA,
    address _userB,
    uint208 _voteWeightA,
    uint208 _voteWeightB
  ) public {
    // This max is a limitation of the fractional governance protocol storage.
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
    flexClient.expressVote(_proposalId, uint8(GCF.VoteType.Against));
    vm.prank(_userB);
    flexClient.expressVote(_proposalId, uint8(GCF.VoteType.Abstain));

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

    _vars.supportTypeA = uint8(bound(_vars.supportTypeA, 0, uint256(type(GCF.VoteType).max)));
    _vars.supportTypeB = uint8(bound(_vars.supportTypeB, 0, uint256(type(GCF.VoteType).max)));

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
    vm.roll(governor.proposalSnapshot(_proposalId) + 1);
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
      assertEq(_forVotes, _vars.supportTypeA == uint8(GCF.VoteType.For) ? _expectedVotingWeight : 0);
      assertEq(
        _againstVotes, _vars.supportTypeA == uint8(GCF.VoteType.Against) ? _expectedVotingWeight : 0
      );
      assertEq(
        _abstainVotes, _vars.supportTypeA == uint8(GCF.VoteType.Abstain) ? _expectedVotingWeight : 0
      );
    } else {
      uint256 _expectedVotingWeightA =
        (_vars.voteWeightA * _expectedVotingWeight) / _initDepositWeight;
      uint256 _expectedVotingWeightB =
        (_vars.voteWeightB * _expectedVotingWeight) / _initDepositWeight;

      // We assert the weight is within a range of 1 because scaled weights are sometimes floored.
      if (_vars.supportTypeA == uint8(GCF.VoteType.For)) {
        assertApproxEqAbs(_forVotes, _expectedVotingWeightA, 1);
      }
      if (_vars.supportTypeB == uint8(GCF.VoteType.For)) {
        assertApproxEqAbs(_forVotes, _expectedVotingWeightB, 1);
      }
      if (_vars.supportTypeA == uint8(GCF.VoteType.Against)) {
        assertApproxEqAbs(_againstVotes, _expectedVotingWeightA, 1);
      }
      if (_vars.supportTypeB == uint8(GCF.VoteType.Against)) {
        assertApproxEqAbs(_againstVotes, _expectedVotingWeightB, 1);
      }
      if (_vars.supportTypeA == uint8(GCF.VoteType.Abstain)) {
        assertApproxEqAbs(_abstainVotes, _expectedVotingWeightA, 1);
      }
      if (_vars.supportTypeB == uint8(GCF.VoteType.Abstain)) {
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
    GCF.VoteType _voteTypeA = _randVoteType(_supportTypeA);

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
    vm.roll(governor.proposalSnapshot(_proposalId) + 1);
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
    if (_voteTypeA == GCF.VoteType.For) assertApproxEqAbs(_forVotes, _expectedVotingWeightA, 1);
    if (_voteTypeA == GCF.VoteType.Against) {
      assertApproxEqAbs(_againstVotes, _expectedVotingWeightA, 1);
    }
    if (_voteTypeA == GCF.VoteType.Abstain) {
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
    GCF.VoteType _voteTypeA = _randVoteType(_supportTypeA);

    // Mint and deposit for just userA.
    _mintGovAndDepositIntoFlexClient(_users[0], _voteWeightA);
    uint256 _initDepositWeight = token.balanceOf(address(flexClient));

    // Create the proposal.
    uint256 _proposalId = _createAndSubmitProposal();

    // Jump ahead to the proposal snapshot to lock in the flexClient's balance.
    vm.roll(governor.proposalSnapshot(_proposalId) + 1);

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
    if (_voteTypeA == GCF.VoteType.For) assertEq(_forVotes, _voteWeightA);
    if (_voteTypeA == GCF.VoteType.Against) assertEq(_againstVotes, _voteWeightA);
    if (_voteTypeA == GCF.VoteType.Abstain) assertEq(_abstainVotes, _voteWeightA);
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
    flexClient.expressVote(_proposalId, uint8(GCF.VoteType.Against));

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
    flexClient.expressVote(_proposalId, uint8(GCF.VoteType.Abstain));
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
    GCF.VoteType _voteType;
    (_voteWeight, _voteType) = _assumeSafeVoteParams(_user, _voteWeight, _supportType);

    // Deposit some funds.
    _mintGovAndDepositIntoFlexClient(_user, _voteWeight);

    // Create the proposal.
    uint256 _proposalId = _createAndSubmitProposal();

    // No one has expressed, there are no votes to cast.
    vm.expectRevert(bytes("no votes expressed"));
    flexClient.castVote(_proposalId);

    // _user expresses his/her vote on the proposal.
    vm.prank(_user);
    flexClient.expressVote(_proposalId, uint8(_voteType));

    // Submit votes on behalf of the flexClient.
    flexClient.castVote(_proposalId);

    // All votes have been cast, there's nothing new to send to the governor.
    vm.expectRevert(bytes("no votes expressed"));
    flexClient.castVote(_proposalId);
  }

  function testFuzz_RevertWhen_AfterVotingPeriod(
    address _user,
    uint208 _voteWeight,
    uint8 _supportType
  ) public {
    GCF.VoteType _voteType;
    (_voteWeight, _voteType) = _assumeSafeVoteParams(_user, _voteWeight, _supportType);

    // Deposit some funds.
    _mintGovAndDepositIntoFlexClient(_user, _voteWeight);

    // Create the proposal.
    uint256 _proposalId = _createAndSubmitProposal();

    // Express vote preference.
    vm.prank(_user);
    flexClient.expressVote(_proposalId, uint8(_voteType));

    // Jump ahead so that we're outside of the proposal's voting period.
    vm.roll(governor.proposalDeadline(_proposalId) + 1);
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

contract Borrow is FlexVotingClientTest {
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

    // The total deposit snapshot should not have changed.
    uint256 _blockAtTimeOfBorrow = block.number;
    vm.roll(_blockAtTimeOfBorrow + 42); // Advance so the block is mined.
    assertEq(flexClient.getPastTotalBalance(_blockAtTimeOfBorrow), _depositAmount);
  }
}

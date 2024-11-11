// SPDX-License-Identifier: MIT
pragma solidity >=0.8.10;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {IVotes} from "@openzeppelin/contracts/governance/utils/IVotes.sol";
import {IGovernor} from "@openzeppelin/contracts/governance/Governor.sol";

import {IVotingToken} from "../src/interfaces/IVotingToken.sol";
import {IFractionalGovernor} from "../src/interfaces/IFractionalGovernor.sol";
import {MockFlexVotingClient} from "./MockFlexVotingClient.sol";
import {GovToken} from "./GovToken.sol";
import {FractionalGovernor} from "./FractionalGovernor.sol";
import {ProposalReceiverMock} from "./ProposalReceiverMock.sol";

contract FlexVotingClientTest is Test {
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

  MockFlexVotingClient flexClient;
  GovToken token;
  FractionalGovernor governor;
  ProposalReceiverMock receiver;

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
    assertEq(uint256(governor.state(proposalId)), uint256(ProposalState.Pending));

    // Advance proposal to active state.
    vm.roll(governor.proposalSnapshot(proposalId) + 1);
    assertEq(uint256(governor.state(proposalId)), uint256(ProposalState.Active));
  }

  function _commonFuzzerAssumptions(address _address, uint208 _voteWeight)
    public
    view
    returns (uint208)
  {
    return _commonFuzzerAssumptions(_address, _voteWeight, uint8(VoteType.Against));
  }

  function _commonFuzzerAssumptions(address _address, uint208 _voteWeight, uint8 _supportType)
    public
    view
    returns (uint208)
  {
    vm.assume(_address != address(flexClient));
    vm.assume(_supportType <= uint8(VoteType.Abstain)); // couldn't get fuzzer to work w/ the enum
    // This max is a limitation of the fractional governance protocol storage.
    return uint208(bound(_voteWeight, 1, type(uint128).max));
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

contract Withdraw is FlexVotingClientTest {
  function testFuzz_UserCanWithdrawGovTokens(
    address _lender,
    address _borrower,
    uint208 _amount
  ) public {
    _amount = uint208(bound(_amount, 0, type(uint208).max));
    vm.assume(_lender != address(flexClient));
    vm.assume(_borrower != address(flexClient));
    vm.assume(_borrower != address(0));

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
    _amountA = uint208(bound(_amountA, 1, type(uint128).max));
    _amountB = uint208(bound(_amountB, 1, type(uint128).max));

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

contract Vote is FlexVotingClientTest {
  function testFuzz_UserCanCastVotes(
    address _user,
    uint208 _voteWeight,
    uint8 _supportType
  ) public {
    _voteWeight = _commonFuzzerAssumptions(_user, _voteWeight, _supportType);

    // Deposit some funds.
    _mintGovAndDepositIntoFlexClient(_user, _voteWeight);

    // Create the proposal.
    uint256 _proposalId = _createAndSubmitProposal();

    // _user should now be able to express his/her vote on the proposal.
    vm.prank(_user);
    flexClient.expressVote(_proposalId, _supportType);
    (
      uint256 _againstVotesExpressed,
      uint256 _forVotesExpressed,
      uint256 _abstainVotesExpressed
    ) = flexClient.proposalVotes(_proposalId);
    assertEq(_forVotesExpressed, _supportType == uint8(VoteType.For) ? _voteWeight : 0);
    assertEq(_againstVotesExpressed, _supportType == uint8(VoteType.Against) ? _voteWeight : 0);
    assertEq(_abstainVotesExpressed, _supportType == uint8(VoteType.Abstain) ? _voteWeight : 0);

    // No votes have been cast yet.
    (uint256 _againstVotes, uint256 _forVotes, uint256 _abstainVotes) =
      governor.proposalVotes(_proposalId);
    assertEq(_forVotes, 0);
    assertEq(_againstVotes, 0);
    assertEq(_abstainVotes, 0);

    // submit votes on behalf of the flexClient
    flexClient.castVote(_proposalId);

    // governor should now record votes from the flexClient
    (_againstVotes, _forVotes, _abstainVotes) = governor.proposalVotes(_proposalId);
    assertEq(_forVotes, _forVotesExpressed);
    assertEq(_againstVotes, _againstVotesExpressed);
    assertEq(_abstainVotes, _abstainVotesExpressed);
  }

  function testFuzz_UserCannotExpressVotesWithoutWeightInPool(
    address _user,
    uint208 _voteWeight,
    uint8 _supportType
  ) public {
    _voteWeight = _commonFuzzerAssumptions(_user, _voteWeight, _supportType);

    // Mint gov but do not deposit.
    _mintGovAndApproveFlexClient(_user, _voteWeight);
    assertEq(token.balanceOf(_user), _voteWeight);
    assertEq(flexClient.deposits(_user), 0);

    // Create the proposal.
    uint256 _proposalId = _createAndSubmitProposal();

    // _user should NOT be able to express his/her vote on the proposal.
    vm.expectRevert(bytes("no weight"));
    vm.prank(_user);
    flexClient.expressVote(_proposalId, uint8(_supportType));
  }

  function testFuzz_UserCannotCastAfterVotingPeriod(
    address _user,
    uint208 _voteWeight,
    uint8 _supportType
  ) public {
    _voteWeight = _commonFuzzerAssumptions(_user, _voteWeight, _supportType);

    // Deposit some funds.
    _mintGovAndDepositIntoFlexClient(_user, _voteWeight);

    // Create the proposal.
    uint256 _proposalId = _createAndSubmitProposal();

    // Express vote preference.
    vm.prank(_user);
    flexClient.expressVote(_proposalId, _supportType);

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

  function testFuzz_NoDoubleVoting(
    address _user,
    uint208 _voteWeight,
    uint8 _supportType
  ) public {
    _voteWeight = _commonFuzzerAssumptions(_user, _voteWeight, _supportType);

    // Deposit some funds.
    _mintGovAndDepositIntoFlexClient(_user, _voteWeight);

    // Create the proposal.
    uint256 _proposalId = _createAndSubmitProposal();

    // _user should now be able to express his/her vote on the proposal.
    vm.prank(_user);
    flexClient.expressVote(_proposalId, _supportType);

    (
      uint256 _againstVotesExpressedInit,
      uint256 _forVotesExpressedInit,
      uint256 _abstainVotesExpressedInit
    ) = flexClient.proposalVotes(_proposalId);
    assertEq(_forVotesExpressedInit, _supportType == uint8(VoteType.For) ? _voteWeight : 0);
    assertEq(_againstVotesExpressedInit, _supportType == uint8(VoteType.Against) ? _voteWeight : 0);
    assertEq(_abstainVotesExpressedInit, _supportType == uint8(VoteType.Abstain) ? _voteWeight : 0);

    // Vote early and often!
    vm.expectRevert(bytes("already voted"));
    vm.prank(_user);
    flexClient.expressVote(_proposalId, _supportType);

    // No votes changed.
    (uint256 _againstVotesExpressed, uint256 _forVotesExpressed, uint256 _abstainVotesExpressed) =
      flexClient.proposalVotes(_proposalId);
    assertEq(_forVotesExpressed, _forVotesExpressedInit);
    assertEq(_againstVotesExpressed, _againstVotesExpressedInit);
    assertEq(_abstainVotesExpressed, _abstainVotesExpressedInit);
  }

  function testFuzz_UsersCannotExpressVotesPriorToDepositing(
    address _user,
    uint208 _voteWeight,
    uint8 _supportType
  ) public {
    _voteWeight = _commonFuzzerAssumptions(_user, _voteWeight, _supportType);

    // Create the proposal *before* the user deposits anything.
    uint256 _proposalId = _createAndSubmitProposal();

    // Deposit some funds.
    _mintGovAndDepositIntoFlexClient(_user, _voteWeight);

    // Now try to express a voting preference on the proposal.
    assertEq(flexClient.deposits(_user), _voteWeight);
    vm.expectRevert(bytes("no weight"));
    vm.prank(_user);
    flexClient.expressVote(_proposalId, _supportType);
  }

  function testFuzz_UsersMustExpressWithKnownVoteType(
    address _user,
    uint208 _voteWeight,
    uint8 _supportType
  ) public {
    // Force vote type to be unrecognized.
    vm.assume(_supportType > uint8(VoteType.Abstain));

    vm.assume(_user != address(flexClient));
    // This max is a limitation of the fractional governance protocol storage.
    _voteWeight = uint208(bound(_voteWeight, 1, type(uint128).max));

    // Deposit some funds.
    _mintGovAndDepositIntoFlexClient(_user, _voteWeight);

    // Create the proposal.
    uint256 _proposalId = _createAndSubmitProposal();

    // Now try to express a voting preference with a bogus support type.
    vm.expectRevert(bytes("invalid support value, must be included in VoteType enum"));
    vm.prank(_user);
    flexClient.expressVote(_proposalId, _supportType);
  }

  function testFuzz_VotingWeightIsSnapshotDependent(
    address _user,
    uint208 _voteWeightA,
    uint208 _voteWeightB,
    uint8 _supportType
  ) public {
    _voteWeightA = _commonFuzzerAssumptions(_user, _voteWeightA, _supportType);
    _voteWeightB = _commonFuzzerAssumptions(_user, _voteWeightB, _supportType);

    // Deposit some funds.
    _mintGovAndDepositIntoFlexClient(_user, _voteWeightA);

    // Create the proposal.
    uint256 _proposalId = _createAndSubmitProposal();

    // Sometime later the user deposits some more.
    vm.roll(governor.proposalDeadline(_proposalId) - 1);
    _mintGovAndDepositIntoFlexClient(_user, _voteWeightB);

    vm.prank(_user);
    flexClient.expressVote(_proposalId, _supportType);

    // The internal proposal vote weight should not reflect the new deposit weight.
    (uint256 _againstVotesExpressed, uint256 _forVotesExpressed, uint256 _abstainVotesExpressed) =
      flexClient.proposalVotes(_proposalId);
    assertEq(_forVotesExpressed, _supportType == uint8(VoteType.For) ? _voteWeightA : 0);
    assertEq(_againstVotesExpressed, _supportType == uint8(VoteType.Against) ? _voteWeightA : 0);
    assertEq(_abstainVotesExpressed, _supportType == uint8(VoteType.Abstain) ? _voteWeightA : 0);

    // Submit votes on behalf of the flexClient.
    flexClient.castVote(_proposalId);

    // Votes cast should likewise reflect only the earlier balance.
    (uint256 _againstVotes, uint256 _forVotes, uint256 _abstainVotes) =
      governor.proposalVotes(_proposalId);
    assertEq(_forVotes, _supportType == uint8(VoteType.For) ? _voteWeightA : 0);
    assertEq(_againstVotes, _supportType == uint8(VoteType.Against) ? _voteWeightA : 0);
    assertEq(_abstainVotes, _supportType == uint8(VoteType.Abstain) ? _voteWeightA : 0);
  }

  function testFuzz_MultipleUsersCanCastVotes(
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
    flexClient.expressVote(_proposalId, uint8(VoteType.Against));
    vm.prank(_userB);
    flexClient.expressVote(_proposalId, uint8(VoteType.Abstain));

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

  function testFuzz_VoteWeightIsScaledBasedOnPoolBalance(VoteWeightIsScaledTestVars memory _vars)
    public
  {
    _vars.userA = address(0xbeef);
    _vars.userB = address(0xbabe);
    _vars.userC = address(0xf005ba11);
    _vars.userD = address(0xba5eba11);

    _vars.supportTypeA = uint8(bound(_vars.supportTypeA, 0, uint8(VoteType.Abstain)));
    _vars.supportTypeB = uint8(bound(_vars.supportTypeB, 0, uint8(VoteType.Abstain)));

    _vars.voteWeightA = uint208(bound(_vars.voteWeightA, 1e4, type(uint128).max - 1e4 - 1));
    _vars.voteWeightB = uint208(bound(_vars.voteWeightB, 1e4, type(uint128).max - _vars.voteWeightA - 1));

    uint208 _maxBorrowWeight = _vars.voteWeightA + _vars.voteWeightB;
    _vars.borrowAmountC = uint208(bound(_vars.borrowAmountC, 1, _maxBorrowWeight - 1));
    _vars.borrowAmountD = uint208(bound(_vars.borrowAmountD, 1, _maxBorrowWeight - _vars.borrowAmountC));

    // These are here just as a sanity check that all of the bounding above worked.
    vm.assume(_vars.voteWeightA + _vars.voteWeightB < type(uint128).max);
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

  // This is important because it ensures you can't *gain* voting weight by
  // getting other people to not vote.
  function testFuzz_VotingWeightIsAbandonedIfSomeoneDoesntExpress(
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
    _voteWeightA = _commonFuzzerAssumptions(_users[0], _voteWeightA, _supportTypeA);
    _voteWeightB = _commonFuzzerAssumptions(_users[1], _voteWeightB);
    _borrowAmount = _commonFuzzerAssumptions(_users[2], _borrowAmount);

    _voteWeightA = uint208(bound(_voteWeightA, 0, type(uint128).max));
    _voteWeightB = uint208(bound(_voteWeightB, 0, type(uint128).max - _voteWeightA));
    vm.assume(_voteWeightA + _voteWeightB < type(uint128).max);
    vm.assume(_voteWeightA + _voteWeightB > _borrowAmount);

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
    flexClient.expressVote(_proposalId, _supportTypeA);

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
    _voteWeightA = _commonFuzzerAssumptions(_users[0], _voteWeightA, _supportTypeA);
    _voteWeightB = _commonFuzzerAssumptions(_users[1], _voteWeightB);

    vm.assume(_voteWeightA + _voteWeightB < type(uint128).max);

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
    flexClient.expressVote(_proposalId, _supportTypeA);

    // Submit votes on behalf of the flexClient.
    flexClient.castVote(_proposalId);

    (uint256 _againstVotes, uint256 _forVotes, uint256 _abstainVotes) =
      governor.proposalVotes(_proposalId);

    // We assert the weight is within a range of 1 because scaled weights are sometimes floored.
    if (_supportTypeA == uint8(VoteType.For)) assertEq(_forVotes, _voteWeightA);
    if (_supportTypeA == uint8(VoteType.Against)) assertEq(_againstVotes, _voteWeightA);
    if (_supportTypeA == uint8(VoteType.Abstain)) assertEq(_abstainVotes, _voteWeightA);
  }

  function testFuzz_CanCastVotesMultipleTimesForTheSameProposal(
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
    flexClient.expressVote(_proposalId, uint8(VoteType.Against));

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
    flexClient.expressVote(_proposalId, uint8(VoteType.Abstain));
    flexClient.castVote(_proposalId);

    // Governor should now record votes for both users.
    (_againstVotes, _forVotes, _abstainVotes) = governor.proposalVotes(_proposalId);
    assertEq(_forVotes, 0);
    assertEq(_againstVotes, _voteWeightA); // This should be unchanged!
    assertEq(_abstainVotes, _voteWeightB); // Second user's votes are now in.
  }

}

contract Borrow is FlexVotingClientTest {
  function testFuzz_UsersCanBorrowTokens(
    address _depositer,
    uint208 _depositAmount,
    address _borrower,
    uint208 _borrowAmount
  ) public {
    vm.assume(_borrower != address(0));
    _depositAmount = _commonFuzzerAssumptions(_depositer, _depositAmount);
    _borrowAmount = _commonFuzzerAssumptions(_borrower, _borrowAmount);
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

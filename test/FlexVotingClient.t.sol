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

  function _mintGovAndApproveFlexClient(address _holder, uint208 _amount) public {
    vm.assume(_holder != address(0));
    token.exposed_mint(_holder, _amount);
    vm.prank(_holder);
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

// TODO deposit
// TODO withdraw

contract Vote is FlexVotingClientTest {
  function testFuzz_UserCanCastVotes(
    address _holder,
    uint208 _voteWeight,
    uint8 _supportType
  ) public {
    _voteWeight = _commonFuzzerAssumptions(_holder, _voteWeight, _supportType);

    // Deposit some funds.
    _mintGovAndDepositIntoFlexClient(_holder, _voteWeight);

    // Create the proposal.
    uint256 _proposalId = _createAndSubmitProposal();

    // _holder should now be able to express his/her vote on the proposal.
    vm.prank(_holder);
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
    address _holder,
    uint208 _voteWeight,
    uint8 _supportType
  ) public {
    _voteWeight = _commonFuzzerAssumptions(_holder, _voteWeight, _supportType);

    // Mint gov but do not deposit.
    _mintGovAndApproveFlexClient(_holder, _voteWeight);
    assertEq(token.balanceOf(_holder), _voteWeight);
    assertEq(flexClient.deposits(_holder), 0);

    // Create the proposal.
    uint256 _proposalId = _createAndSubmitProposal();

    // _holder should NOT be able to express his/her vote on the proposal.
    vm.expectRevert(bytes("no weight"));
    vm.prank(_holder);
    flexClient.expressVote(_proposalId, uint8(_supportType));
  }

  function testFuzz_UserCannotCastAfterVotingPeriod(
    address _holder,
    uint208 _voteWeight,
    uint8 _supportType
  ) public {
    _voteWeight = _commonFuzzerAssumptions(_holder, _voteWeight, _supportType);

    // Deposit some funds.
    _mintGovAndDepositIntoFlexClient(_holder, _voteWeight);

    // Create the proposal.
    uint256 _proposalId = _createAndSubmitProposal();

    // Express vote preference.
    vm.prank(_holder);
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
    address _hodler,
    uint208 _voteWeight,
    uint8 _supportType
  ) public {
    _voteWeight = _commonFuzzerAssumptions(_hodler, _voteWeight, _supportType);

    // Deposit some funds.
    _mintGovAndDepositIntoFlexClient(_hodler, _voteWeight);

    // Create the proposal.
    uint256 _proposalId = _createAndSubmitProposal();

    // _holder should now be able to express his/her vote on the proposal.
    vm.prank(_hodler);
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
    vm.prank(_hodler);
    flexClient.expressVote(_proposalId, _supportType);

    // No votes changed.
    (uint256 _againstVotesExpressed, uint256 _forVotesExpressed, uint256 _abstainVotesExpressed) =
      flexClient.proposalVotes(_proposalId);
    assertEq(_forVotesExpressed, _forVotesExpressedInit);
    assertEq(_againstVotesExpressed, _againstVotesExpressedInit);
    assertEq(_abstainVotesExpressed, _abstainVotesExpressedInit);
  }

  function testFuzz_UsersCannotExpressVotesPriorToDepositing(
    address _hodler,
    uint208 _voteWeight,
    uint8 _supportType
  ) public {
    _voteWeight = _commonFuzzerAssumptions(_hodler, _voteWeight, _supportType);

    // Create the proposal *before* the user deposits anything.
    uint256 _proposalId = _createAndSubmitProposal();

    // Deposit some funds.
    _mintGovAndDepositIntoFlexClient(_hodler, _voteWeight);

    // Now try to express a voting preference on the proposal.
    assertEq(flexClient.deposits(_hodler), _voteWeight);
    vm.expectRevert(bytes("no weight"));
    vm.prank(_hodler);
    flexClient.expressVote(_proposalId, _supportType);
  }

  function testFuzz_VotingWeightIsSnapshotDependent(
    address _hodler,
    uint208 _voteWeightA,
    uint208 _voteWeightB,
    uint8 _supportType
  ) public {
    _voteWeightA = _commonFuzzerAssumptions(_hodler, _voteWeightA, _supportType);
    _voteWeightB = _commonFuzzerAssumptions(_hodler, _voteWeightB, _supportType);

    // Deposit some funds.
    _mintGovAndDepositIntoFlexClient(_hodler, _voteWeightA);

    // Create the proposal.
    uint256 _proposalId = _createAndSubmitProposal();

    // Sometime later the user deposits some more.
    vm.roll(governor.proposalDeadline(_proposalId) - 1);
    _mintGovAndDepositIntoFlexClient(_hodler, _voteWeightB);

    vm.prank(_hodler);
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
    address _hodlerA,
    address _hodlerB,
    uint208 _voteWeightA,
    uint208 _voteWeightB
  ) public {
    // This max is a limitation of the fractional governance protocol storage.
    _voteWeightA = uint208(bound(_voteWeightA, 1, type(uint120).max));
    _voteWeightB = uint208(bound(_voteWeightB, 1, type(uint120).max));

    vm.assume(_hodlerA != address(flexClient));
    vm.assume(_hodlerB != address(flexClient));
    vm.assume(_hodlerA != _hodlerB);

    // Deposit some funds.
    _mintGovAndDepositIntoFlexClient(_hodlerA, _voteWeightA);
    _mintGovAndDepositIntoFlexClient(_hodlerB, _voteWeightB);

    // Create the proposal.
    uint256 _proposalId = _createAndSubmitProposal();

    // Hodlers should now be able to express their votes on the proposal.
    vm.prank(_hodlerA);
    flexClient.expressVote(_proposalId, uint8(VoteType.Against));
    vm.prank(_hodlerB);
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

  // TODO Can call castVotes multiple times.
}

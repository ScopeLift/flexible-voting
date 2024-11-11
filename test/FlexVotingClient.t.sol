// SPDX-License-Identifier: MIT
pragma solidity >=0.8.10;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {IVotes} from "@openzeppelin/contracts/governance/utils/IVotes.sol";

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

    // create the proposal
    uint256 _proposalId = _createAndSubmitProposal();

    // _holder should now be able to express his/her vote on the proposal
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

    // no votes have been cast yet
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

  // TODO voting multiple times
}

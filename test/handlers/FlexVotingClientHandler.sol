// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console2} from "forge-std/Test.sol";
import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {IVotes} from "@openzeppelin/contracts/governance/utils/IVotes.sol";
import {IGovernor} from "@openzeppelin/contracts/governance/Governor.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

import {GovernorCountingFractional as GCF} from "src/GovernorCountingFractional.sol";
import {IVotingToken} from "src/interfaces/IVotingToken.sol";
import {IFractionalGovernor} from "src/interfaces/IFractionalGovernor.sol";
import {MockFlexVotingClient} from "test/MockFlexVotingClient.sol";
import {GovToken} from "test/GovToken.sol";
import {FractionalGovernor} from "test/FractionalGovernor.sol";
import {ProposalReceiverMock} from "test/ProposalReceiverMock.sol";

contract FlexVotingClientHandler is Test {
  using EnumerableSet for EnumerableSet.AddressSet;
  using EnumerableSet for EnumerableSet.UintSet;

  MockFlexVotingClient flexClient;
  GovToken token;
  FractionalGovernor governor;
  ProposalReceiverMock receiver;

  EnumerableSet.UintSet internal _proposals;
  EnumerableSet.AddressSet internal _voters;
  EnumerableSet.AddressSet internal _actors;
  address internal currentActor;

  struct CallCounts {
    uint256 count;
  }
  mapping(bytes32 => CallCounts) public calls;

  uint256 public ghost_depositSum;
  uint256 public ghost_withdrawSum;
  uint128 public ghost_mintedTokens;
  mapping(address => uint128) public ghost_accountDeposits;

  // Maps actors to proposal ids to number of times they've voted on the proposal.
  // E.g. actorProposalVotes[0xBEEF][42] == the number of times 0xBEEF voted on
  // proposal 42.
  mapping(address => mapping(uint256 => uint256)) public ghost_actorProposalVotes;
  uint256 public ghost_doubleVoteActors;

  constructor(
    GovToken _token,
    FractionalGovernor _governor,
    MockFlexVotingClient _client,
    ProposalReceiverMock _receiver
  ) {
    token = _token;
    flexClient = _client;
    governor = _governor;
    receiver = _receiver;
  }

  modifier countCall(bytes32 key) {
    calls[key].count++;
    _;
  }

  modifier createActor() {
    vm.assume(_validActorAddress(msg.sender));
    currentActor = msg.sender;
    _actors.add(msg.sender);
    _;
  }

  modifier maybeCreateVoter() {
    if (_proposals.length() == 0) _voters.add(currentActor);
    _;
  }

  modifier useActor(uint256 actorIndexSeed) {
    currentActor = _randAdress(_actors, actorIndexSeed);
    _;
  }

  modifier useVoter(uint256 _voterSeed) {
    currentActor = _randAdress(_voters, _voterSeed);
    _;
  }

  function _randAdress(EnumerableSet.AddressSet storage _addressSet, uint256 _seed) internal returns (address) {
    uint256 len = _addressSet.length();
    return len > 0 ?  _addressSet.at(_seed % len) : address(0);
  }

  function lastProposal() external returns (uint256) {
    return _proposals.at(_proposals.length() - 1);
  }

  function _randProposal(uint256 _seed) internal returns (uint256) {
    uint256 len = _proposals.length();
    return len > 0 ? _proposals.at(_seed % len) : 0;
  }

  function _validActorAddress(address _user) internal returns (bool) {
    return _user != address(0) &&
      _user != address(flexClient) &&
      _user != address(governor) &&
      _user != address(receiver) &&
      _user != address(token);
  }

  function _remainingTokens() internal returns (uint128) {
    return type(uint128).max - ghost_mintedTokens;
  }

  function proposalLength() public returns(uint256) {
    return _proposals.length();
  }

  // TODO This always creates a new actor. Should it?
  function deposit(
    uint208 _amount
  ) createActor maybeCreateVoter countCall("deposit") external {
    vm.assume(_remainingTokens() > 0);
    _amount = uint208(_bound(_amount, 0, _remainingTokens()));

    // Some actors won't have the tokens they need. This is deliberate.
    if (_amount <= _remainingTokens()) {
      token.exposed_mint(currentActor, _amount);
      ghost_mintedTokens += uint128(_amount);
    }

    vm.startPrank(currentActor);
    // TODO we're pre-approving every depositi, should we?
    token.approve(address(flexClient), uint256(_amount));
    flexClient.deposit(_amount);
    vm.stopPrank();

    ghost_depositSum += _amount;
    ghost_accountDeposits[currentActor] += uint128(_amount);
  }

  // TODO we restrict withdrawals to addresses that have balances, should we?
  function withdraw(
    uint256 _userSeed,
    uint208 _amount
  )
    useActor(_userSeed)
    countCall("withdraw")
    external
  {
    // TODO we limit withdrawals to the total amount deposited, should we?
    //   instead we could limit the caller to withdraw some portion of its balance
    //   or we could let the caller attempt to withdraw any uint208
    _amount = uint208(_bound(_amount, 0, ghost_accountDeposits[currentActor]));

    vm.prank(currentActor);
    flexClient.withdraw(_amount);

    ghost_withdrawSum += _amount;
    ghost_accountDeposits[currentActor] -= uint128(_amount);
  }

  function propose(
    string memory _proposalName,
    uint256 _seed
  ) countCall("propose") external {
    // Proposal will underflow if we're on the zero block
    if (block.number == 0) vm.roll(1);
    if (this.proposalLength() > 3) return;

    // Create a proposal
    bytes memory receiverCallData = abi.encodeWithSignature("mockReceiverFunction()");
    address[] memory targets = new address[](1);
    uint256[] memory values = new uint256[](1);
    bytes[] memory calldatas = new bytes[](1);
    targets[0] = address(receiver);
    values[0] = 0; // No ETH will be sent.
    calldatas[0] = receiverCallData;

    // Submit the proposal.
    vm.prank(msg.sender);
    uint256 _id = governor.propose(targets, values, calldatas, _proposalName);
    _proposals.add(_id);

    // Roll the clock to get voting started.
    vm.roll(governor.proposalSnapshot(_id) + 1);
  }

  // TODO restrict expressVote to addresses that deposited BEFORE proposal.
  function expressVote(
    uint256 _proposalId,
    uint8 _support,
    uint256 _userSeed
  ) useVoter(_userSeed) countCall("expressVote") external {
    if (_proposals.length() == 0) return;

    // TODO should we allow people to try to vote with bogus support types?
    _support = uint8(_bound(
      uint256(_support),
      uint256(type(GCF.VoteType).min),
      uint256(type(GCF.VoteType).max)
    ));
    // TODO should users only express on proposals created after they had deposits?
    _proposalId = _randProposal(_proposalId);
    vm.prank(currentActor);
    flexClient.expressVote(_proposalId, _support);

    ghost_actorProposalVotes[currentActor][_proposalId] += 1;
    if (ghost_actorProposalVotes[currentActor][_proposalId] > 1) {
      ghost_doubleVoteActors += 1;
    }
  }

  function castVote(uint256 _proposalId) countCall("castVote") external {
    // If someone tries to castVotes when there is no proposal it just reverts.
    if (_proposals.length() == 0) return;

    _proposalId = _randProposal(_proposalId);
    vm.prank(msg.sender);
    flexClient.castVote(_proposalId);
  }

  function callSummary() external {
    console2.log("\nCall summary:");
    console2.log("-------------------");
    console2.log("deposit:", calls["deposit"].count);
    console2.log("withdraw:", calls["withdraw"].count);
    console2.log("expressVote:", calls["expressVote"].count);
    console2.log("castVote:", calls["castVote"].count);
    console2.log("propose:", calls["propose"].count);
    console2.log("-------------------");
    console2.log("actor count:", _actors.length());
    console2.log("voter count:", _voters.length());
    console2.log("proposal count:", _proposals.length());
    console2.log("amount deposited:", ghost_depositSum);
    console2.log("amount withdrawn:", ghost_withdrawSum);
    console2.log("amount remaining:", _remainingTokens());
    console2.log("-------------------");

  }
}

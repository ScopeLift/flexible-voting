// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console2} from "forge-std/Test.sol";
import {IVotes} from "@openzeppelin/contracts/governance/utils/IVotes.sol";
import {IGovernor} from "@openzeppelin/contracts/governance/Governor.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {GovernorCountingSimple as GCS} from
  "@openzeppelin/contracts/governance/extensions/GovernorCountingSimple.sol";

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

  uint128 public MAX_TOKENS = type(uint128).max;

  // The number of actors that must exist before we allow a proposal to be
  // created.
  uint8 public PROPOSAL_THRESHOLD = 70;

  EnumerableSet.UintSet internal proposals;
  EnumerableSet.AddressSet internal voters;
  EnumerableSet.AddressSet internal actors;
  address internal currentActor;

  // Maps proposalIds to sets of users that have expressed votes but not yet had
  // them cast.
  mapping(uint256 => EnumerableSet.AddressSet) internal pendingVotes;

  // Maps proposalId to votes cast by this contract on the proposal.
  mapping(uint256 => uint256) public ghost_votesCast;

  // Maps proposalId to aggregate deposit weight held by users whose expressed
  // votes were cast.
  mapping(uint256 => uint256) public ghost_depositsCast;

  struct CallCounts {
    uint256 count;
  }

  mapping(bytes32 => CallCounts) public calls;

  uint256 public ghost_depositSum;
  uint256 public ghost_withdrawSum;
  uint128 public ghost_mintedTokens;
  mapping(address => uint128) public ghost_accountDeposits;

  // Maps actors to proposal ids to number of times they've expressed votes on the proposal.
  // E.g. actorExpressedVotes[0xBEEF][42] == the number of times 0xBEEF
  // expressed a voting preference on proposal 42.
  mapping(address => mapping(uint256 => uint256)) public ghost_actorExpressedVotes;

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

  modifier maybeCreateActor(uint256 _seed) {
    vm.assume(_validActorAddress(msg.sender));

    if (actors.length() > 0 && _seed % 9 == 0) {
      // Use an existing actor 10% of the time.
      currentActor = _randAddress(actors, _seed);
    } else {
      // Create a new actor 90% of the time.
      currentActor = msg.sender;
      actors.add(msg.sender);
    }

    _;
  }

  modifier maybeCreateVoter() {
    if (proposals.length() == 0) voters.add(currentActor);
    _;
  }

  modifier useActor(uint256 actorIndexSeed) {
    currentActor = _randAddress(actors, actorIndexSeed);
    _;
  }

  modifier useVoter(uint256 _voterSeed) {
    currentActor = _randAddress(voters, _voterSeed);
    _;
  }

  function hasPendingVotes(address _user, uint256 _proposalId) external view returns (bool) {
    return pendingVotes[_proposalId].contains(_user);
  }

  function _randAddress(EnumerableSet.AddressSet storage _addressSet, uint256 _seed)
    internal
    view
    returns (address)
  {
    uint256 len = _addressSet.length();
    return len > 0 ? _addressSet.at(_seed % len) : address(0);
  }

  function getProposals() external view returns (uint256[] memory) {
    return proposals.values();
  }

  function getVoters() external view returns (address[] memory) {
    return voters.values();
  }

  function getActors() external view returns (address[] memory) {
    return actors.values();
  }

  function lastProposal() external view returns (uint256) {
    if (proposals.length() == 0) return 0;
    return proposals.at(proposals.length() - 1);
  }

  function lastActor() external view returns (address) {
    if (actors.length() == 0) return address(0);
    return actors.at(actors.length() - 1);
  }

  function lastVoter() external view returns (address) {
    if (voters.length() == 0) return address(0);
    return voters.at(voters.length() - 1);
  }

  function _randProposal(uint256 _seed) internal view returns (uint256) {
    uint256 len = proposals.length();
    return len > 0 ? proposals.at(_seed % len) : 0;
  }

  // forgefmt: disable-start
  function _validActorAddress(address _user) internal view returns (bool) {
    return _user != address(0) &&
      _user != address(flexClient) &&
      _user != address(governor) &&
      _user != address(receiver) &&
      _user != address(token);
  }
  // forgefmt: disable-end

  function remainingTokens() public view returns (uint128) {
    return MAX_TOKENS - ghost_mintedTokens;
  }

  function proposal(uint256 _index) public view returns (uint256) {
    return proposals.at(_index);
  }

  function proposalLength() public view returns (uint256) {
    return proposals.length();
  }

  function actorsLength() public view returns (uint256) {
    return actors.length();
  }

  // Simulate the passage of time, which materially changes governance behavior.
  function roll(uint256 _seed) external countCall("roll") {
    vm.assume(proposals.length() > 0);
    uint256 _blocks = _bound(_seed, 1, governor.votingPeriod() / 10);
    vm.roll(block.number + _blocks);
  }

  // NOTE: This always creates a new actor.
  function deposit(uint208 _amount)
    external
    maybeCreateActor(_amount)
    maybeCreateVoter
    countCall("deposit")
  {
    vm.assume(remainingTokens() > 0);
    _amount = uint208(_bound(_amount, 0, remainingTokens()));

    // Some actors won't have the tokens they need. This is deliberate.
    if (_amount <= remainingTokens()) {
      token.exposed_mint(currentActor, _amount);
      ghost_mintedTokens += uint128(_amount);
    }

    vm.startPrank(currentActor);
    // NOTE: We're pre-approving every deposit.
    token.approve(address(flexClient), uint256(_amount));
    flexClient.deposit(_amount);
    vm.stopPrank();

    ghost_depositSum += _amount;
    ghost_accountDeposits[currentActor] += uint128(_amount);
  }

  // NOTE: We restrict withdrawals to addresses that have balances.
  function withdraw(uint256 _userSeed, uint208 _amount)
    external
    useActor(_userSeed)
    countCall("withdraw")
  {
    // NOTE: We limit withdrawals to the account's deposit balance.
    _amount = uint208(_bound(_amount, 0, ghost_accountDeposits[currentActor]));

    vm.startPrank(currentActor);
    flexClient.withdraw(_amount);
    vm.stopPrank();

    ghost_withdrawSum += _amount;
    ghost_accountDeposits[currentActor] -= uint128(_amount);
  }

  function propose(string memory _proposalName)
    external
    countCall("propose")
    returns (uint256 _proposalId)
  {
    // Require there to be depositors.
    if (actors.length() < PROPOSAL_THRESHOLD) return 0;

    // Don't dilute the pool of proposals.
    if (this.proposalLength() > 4) return 0;

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
    _proposalId = governor.propose(targets, values, calldatas, _proposalName);
    proposals.add(_proposalId);

    // Roll the clock to get voting started.
    vm.roll(governor.proposalSnapshot(_proposalId) + 1);
  }

  // We only allow users to express on proposals created after they had
  // deposits. Should we let other users try to express too?
  function expressVote(uint256 _proposalSeed, uint8 _support, uint256 _userSeed)
    external
    useVoter(_userSeed)
    countCall("expressVote")
    returns (address _actor)
  {
    _actor = currentActor;
    if (proposals.length() == 0) return (_actor);

    // NOTE: We don't allow people to try to vote with bogus support types.
    _support = uint8(
      _bound(uint256(_support), uint256(type(GCS.VoteType).min), uint256(type(GCS.VoteType).max))
    );
    uint256 _proposalId = _randProposal(_proposalSeed);
    vm.startPrank(currentActor);
    flexClient.expressVote(_proposalId, _support);
    vm.stopPrank();

    pendingVotes[_proposalId].add(currentActor);

    ghost_actorExpressedVotes[currentActor][_proposalId] += 1;
  }

  struct CastVoteVars {
    uint256 initAgainstVotes;
    uint256 initForVotes;
    uint256 initAbstainVotes;
    uint256 newAgainstVotes;
    uint256 newForVotes;
    uint256 newAbstainVotes;
    uint256 voteDelta;
    uint256 aggDepositWeight;
  }

  function castVote(uint256 _proposalId) external countCall("castVote") {
    // If someone tries to castVotes when there is no proposal it just reverts.
    if (proposals.length() == 0) return;

    CastVoteVars memory _vars;

    _proposalId = _randProposal(_proposalId);

    (_vars.initAgainstVotes, _vars.initForVotes, _vars.initAbstainVotes) =
      governor.proposalVotes(_proposalId);

    vm.startPrank(msg.sender);
    flexClient.castVote(_proposalId);
    vm.stopPrank();

    (_vars.newAgainstVotes, _vars.newForVotes, _vars.newAbstainVotes) =
      governor.proposalVotes(_proposalId);

    // The voters who just had votes cast for them.
    EnumerableSet.AddressSet storage _voters = pendingVotes[_proposalId];

    // The aggregate voting weight just cast.
    _vars.voteDelta = (_vars.newAgainstVotes + _vars.newForVotes + _vars.newAbstainVotes)
      - (_vars.initAgainstVotes + _vars.initForVotes + _vars.initAbstainVotes);
    ghost_votesCast[_proposalId] += _vars.voteDelta;

    // The aggregate deposit weight just cast.
    for (uint256 i; i < _voters.length(); i++) {
      address _voter = _voters.at(i);
      // We need deposits less withdrawals for the user AT proposal time.
      _vars.aggDepositWeight +=
        flexClient.getPastVoteWeight(_voter, governor.proposalSnapshot(_proposalId));
    }
    ghost_depositsCast[_proposalId] += _vars.aggDepositWeight;

    // Delete the pending votes.
    EnumerableSet.AddressSet storage set = pendingVotes[_proposalId];
    // We need to iterate backwards b/c set.remove changes order.
    for (uint256 i = set.length(); i > 0; i--) {
      set.remove(set.at(i - 1));
    }
  }

  function callSummary() external view {
    console2.log("\nCall summary:");
    console2.log("-------------------");
    console2.log("deposit:", calls["deposit"].count);
    console2.log("withdraw:", calls["withdraw"].count);
    console2.log("expressVote:", calls["expressVote"].count);
    console2.log("castVote:", calls["castVote"].count);
    console2.log("propose:", calls["propose"].count);
    console2.log("roll:", calls["roll"].count);
    console2.log("-------------------");
    console2.log("actor count:", actors.length());
    console2.log("voter count:", voters.length());
    console2.log("proposal count:", proposals.length());
    console2.log("amount deposited:", ghost_depositSum);
    console2.log("amount withdrawn:", ghost_withdrawSum);
    console2.log("amount remaining:", remainingTokens());
    console2.log("-------------------");
    for (uint256 i; i < proposals.length(); i++) {
      uint256 _proposalId = proposals.at(i);
      (uint256 _againstVotes, uint256 _forVotes, uint256 _abstainVotes) =
        governor.proposalVotes(_proposalId);
      console2.log("proposal", i);
      console2.log("  forVotes    ", _forVotes);
      console2.log("  againstVotes", _againstVotes);
      console2.log("  abstainVotes", _abstainVotes);
      console2.log("  votesCast   ", ghost_votesCast[_proposalId]);
      console2.log("  depositsCast", ghost_depositsCast[_proposalId]);
    }
    console2.log("-------------------");
  }
}

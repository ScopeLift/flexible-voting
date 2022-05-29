// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import { DSTestPlus } from "solmate/test/utils/DSTestPlus.sol";
import { Vm } from "forge-std/Vm.sol";
import { FractionalPool, IVotingToken, IFractionalGovernor } from "../src/FractionalPool.sol";
import "openzeppelin-contracts/contracts/governance/compatibility/GovernorCompatibilityBravo.sol";
import "solmate/utils/FixedPointMathLib.sol";

import "./GovToken.sol";
import "./FractionalGovernor.sol";
import "./ProposalReceiverMock.sol";

contract GovernorCountingFractionalTest is DSTestPlus {

    using FixedPointMathLib for uint128;

    event MockFunctionCalled();
    event VoteCast(address indexed voter, uint256 proposalId, uint8 support, uint256 weight, string reason);
    event VoteCastWithParams(
        address indexed voter,
        uint256 proposalId,
        uint8 support,
        uint256 weight,
        string reason,
        bytes params
    );
    event ProposalExecuted(uint256 proposalId);
    event ProposalCreated(
        uint256 proposalId,
        address proposer,
        address[] targets,
        uint256[] values,
        string[] signatures,
        bytes[] calldatas,
        uint256 startBlock,
        uint256 endBlock,
        string description
    );
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

    Vm vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    struct FractionalVoteSplit {
      uint256 percentFor; // wad
      uint256 percentAgainst; // wad
      uint256 percentAbstain; // wad
    }

    struct Voter {
      address addr;
      uint128 weight;
      uint8 support;
      FractionalVoteSplit voteSplit;
    }

    struct Proposal {
      uint256 id;
      address[] targets;
      uint256[] values;
      bytes[] calldatas;
      string description;
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

    /// ----------------------
    /// BEGIN HELPER FUNCTIONS
    /// ----------------------

    function _getSimpleProposal() internal view returns(Proposal memory) {
      address[] memory targets = new address[](1);
      uint256[] memory values = new uint256[](1);
      bytes[] memory calldatas = new bytes[](1);
      targets[0] = address(receiver);
      values[0] = 0; // no ETH will be sent
      calldatas[0] = abi.encodeWithSignature("mockRecieverFunction()");
      string memory description = "A modest proposal";
      uint256 proposalId = governor.hashProposal(targets, values, calldatas, keccak256(bytes(description)));

      return Proposal(proposalId, targets, values, calldatas, description);
    }

    function _createAndSubmitProposal() internal returns(uint256 proposalId) {
      // proposal will underflow if we're on the zero block
      vm.roll(block.number + 1);

      // Build a proposal.
      Proposal memory _proposal = _getSimpleProposal();

      vm.expectEmit(true, true, true, true);
      emit ProposalCreated(
        _proposal.id,
        address(this),
        _proposal.targets,
        _proposal.values,
        new string[](_proposal.targets.length), // Signatures
        _proposal.calldatas,
        block.number + governor.votingDelay(),
        block.number + governor.votingDelay() + governor.votingPeriod(),
        _proposal.description
      );

      // Submit the proposal.
      proposalId = governor.propose(_proposal.targets, _proposal.values, _proposal.calldatas, _proposal.description);
      assertEq(uint(governor.state(proposalId)), uint(ProposalState.Pending));

      // Advance proposal to active state.
      vm.roll(governor.proposalSnapshot(proposalId) + 1);
      assertEq(uint(governor.state(proposalId)), uint(ProposalState.Active));
    }

    function _executeProposal() internal {
      Proposal memory _rawProposalInfo = _getSimpleProposal();

      vm.expectEmit(true, false, false, false);
      emit ProposalExecuted(_rawProposalInfo.id);

      // Ensure that the other contract is invoked.
      vm.expectEmit(false, false, false, false);
      emit MockFunctionCalled();

      governor.execute(
        _rawProposalInfo.targets,
        _rawProposalInfo.values,
        _rawProposalInfo.calldatas,
        keccak256(bytes(_rawProposalInfo.description))
      );
    }

    function _setupNominalVoters(
      uint120[4] memory weights,
      uint8[4] memory supportTypes
    ) internal returns(Voter[4] memory voters) {
      Voter memory voter;
      for (uint8 _i; _i < voters.length; _i++) {
        voter = voters[_i];
        voter.addr = address(uint160(uint(keccak256(abi.encodePacked(weights[_i], _i))))); // Generate random address;
        voter.weight = uint128(bound(weights[_i], 1, type(uint120).max)); // uint120 prevents overflow of uint128 vote slots;
        voter.support = uint8(bound(supportTypes[_i], 0, uint8(GovernorCompatibilityBravo.VoteType.Abstain)));
      }
    }

    function _randomSupportType() public returns (uint8) {
      // 42 is out of range, forcing bound to return a random value.
      return uint8(bound(42, 0, uint8(GovernorCompatibilityBravo.VoteType.Abstain)));
    }

    function _randomVoteSplit() public returns (FractionalVoteSplit memory _voteSplit) {
      _voteSplit.percentFor = bound(1e19, 0, 1e18); // 1e19 is just used to ensure we get a random value
      _voteSplit.percentAgainst = bound(1e19, 0, 1e18 - _voteSplit.percentFor);
      _voteSplit.percentAbstain = 1e18 - _voteSplit.percentFor - _voteSplit.percentAgainst;
    }

    // Setups up a 4-Voter array with specified weights, random supportTypes, and random voteSplits.
    function _setupFractionalVoters(uint120[4] memory weights) internal returns(Voter[4] memory) {
      return _setupFractionalVoters(
        weights,
        [_randomVoteSplit(), _randomVoteSplit(), _randomVoteSplit(), _randomVoteSplit()]
      );
    }

    function _setupFractionalVoters(
      uint120[4] memory weights,
      FractionalVoteSplit[4] memory voteSplits
    ) internal returns(Voter[4] memory voters) {
      // SupportTypes don't actually matter for fractional voters, so we randomize them.
      uint8[4] memory supportTypes = [_randomSupportType(), _randomSupportType(), _randomSupportType(), _randomSupportType()];

      voters = _setupNominalVoters(weights, supportTypes);

      Voter memory voter;
      for (uint8 _i; _i < voters.length; _i++) {
        voter = voters[_i];
        FractionalVoteSplit memory split = voteSplits[_i];
        // If the voteSplit has not been initialized, we don't change it. This allows us
        // to have a *mixed* array of voters, where some vote fractionally and some don't.
        if (_isVoteSplitInitialized(split)) {
          require(split.percentFor + split.percentAgainst + split.percentAbstain == 1e18, "split must add to 100%");
          voter.voteSplit = split;
        }
      }
    }

    function _mintAndDelegateToVoters(Voter[4] memory voters) internal returns(
      uint128 forVotes,
      uint128 againstVotes,
      uint128 abstainVotes
    ) {
      Voter memory voter;

      for(uint8 _i = 0; _i < voters.length; _i++) {
        voter = voters[_i];

        // Mint tokens for the user.
        token.THIS_IS_JUST_A_TEST_HOOK_mint(voter.addr, voter.weight);

        // Self-delegate the tokens.
        vm.prank(voter.addr);
        token.delegate(voter.addr);

        if (voter.voteSplit.percentFor > 0) {
          forVotes     += uint128(voter.weight.mulWadDown(voter.voteSplit.percentFor));
          againstVotes += uint128(voter.weight.mulWadDown(voter.voteSplit.percentAgainst));
          abstainVotes += uint128(voter.weight.mulWadDown(voter.voteSplit.percentAbstain));
        } else {
          if (voter.support == uint8(GovernorCompatibilityBravo.VoteType.For)) forVotes += voter.weight;
          if (voter.support == uint8(GovernorCompatibilityBravo.VoteType.Against)) againstVotes += voter.weight;
          if (voter.support == uint8(GovernorCompatibilityBravo.VoteType.Abstain)) abstainVotes += voter.weight;
        }
      }
    }

    function _isVoteSplitInitialized(FractionalVoteSplit memory voteSplit) public pure returns(bool){
      return voteSplit.percentFor > 0
        || voteSplit.percentAgainst > 0
        || voteSplit.percentAbstain > 0;
    }

    function _castVotes(Voter[4] memory voters, uint256 _proposalId) internal {
      Voter memory voter;
      for(uint8 _i = 0; _i < voters.length; _i++) {
        voter = voters[_i];

        assert(!governor.hasVoted(_proposalId, voter.addr));

        bytes memory fractionalizedVotes;
        FractionalVoteSplit memory voteSplit = voter.voteSplit;

        if (_isVoteSplitInitialized(voteSplit)) {
          fractionalizedVotes = abi.encodePacked(
            uint128(voter.weight.mulWadDown(voteSplit.percentFor)),
            uint128(voter.weight.mulWadDown(voteSplit.percentAgainst)),
            uint128(voter.weight.mulWadDown(voteSplit.percentAbstain))
          );
          vm.expectEmit(true, false, false, true);
          emit VoteCastWithParams(voter.addr, _proposalId, voter.support, voter.weight, 'Yay', fractionalizedVotes);
        } else {
          vm.expectEmit(true, false, false, true);
          emit VoteCast(voter.addr, _proposalId, voter.support, voter.weight, 'Yay');
        }

        vm.prank(voter.addr);
        governor.castVoteWithReasonAndParams(_proposalId, voter.support, 'Yay', fractionalizedVotes);

        assert(governor.hasVoted(_proposalId, voter.addr));
      }
    }

    function _fractionalGovernorHappyPathTest(Voter[4] memory voters) public {
      uint256 _initGovBalance = address(governor).balance;
      uint256 _initReceiverBalance = address(receiver).balance;

      (uint128 forVotes, uint128 againstVotes, uint128 abstainVotes) = _mintAndDelegateToVoters(voters);
      uint256 _proposalId = _createAndSubmitProposal();
      _castVotes(voters, _proposalId);

      // Jump ahead so that we're outside of the proposal's voting period.
      vm.roll(governor.proposalDeadline(_proposalId) + 1);

      (
        uint256 againstVotesCast,
        uint256 forVotesCast,
        uint256 abstainVotesCast
      ) = governor.proposalVotes(_proposalId);

      assertEq(againstVotes, againstVotesCast);
      assertEq(forVotes, forVotesCast);
      assertEq(abstainVotes, abstainVotesCast);

      ProposalState status = ProposalState(uint32(governor.state(_proposalId)));
      if (forVotes > againstVotes && forVotes >= governor.quorum(block.number)) {
        assertEq(uint8(status), uint8(ProposalState.Succeeded));
        _executeProposal();
      } else {
        assertEq(uint8(status), uint8(ProposalState.Defeated));

        Proposal memory _rawProposalInfo = _getSimpleProposal();
        vm.expectRevert(bytes('Governor: proposal not successful'));
        governor.execute(
          _rawProposalInfo.targets,
          _rawProposalInfo.values,
          _rawProposalInfo.calldatas,
          keccak256(bytes(_rawProposalInfo.description))
        );
      }

      // No ETH should have moved.
      assertEq(address(governor).balance, _initGovBalance);
      assertEq(address(receiver).balance, _initReceiverBalance);
    }

    /// --------------------
    /// END HELPER FUNCTIONS
    /// --------------------

    function testFuzz_Deployment(uint256 _blockNumber) public {
      assertEq(governor.name(), "Governor");
      assertEq(address(governor.token()), address(token));
      assertEq(governor.votingDelay(), 4);
      assertEq(governor.votingPeriod(), 100);
      assertEq(governor.quorum(_blockNumber), 10e18);
      assertEq(governor.COUNTING_MODE(), 'support=bravo&quorum=bravo&params=fractional');
    }

    function testFuzz_NominalBehaviorIsUnaffected(uint120[4] memory weights, uint8[4] memory supportTypes) public {
      Voter[4] memory voters = _setupNominalVoters(weights, supportTypes);
      _fractionalGovernorHappyPathTest(voters);
    }

    function testFuzz_VotingWithFractionalizedParams(uint120[4] memory weights) public {
      Voter[4] memory voters = _setupFractionalVoters(weights);
      _fractionalGovernorHappyPathTest(voters);
    }

    function testFuzz_VotingWithMixedFractionalAndNominalVoters(
      uint120[4] memory weights,
      bool[4] memory userIsFractional
    ) public {
      FractionalVoteSplit[4] memory voteSplits;
      for(uint _i; _i < userIsFractional.length; _i++) {
        // If the user is not a fractional user, we don't define a vote split. This will
        // cause them to cast their vote nominally.
        if (userIsFractional[_i]) voteSplits[_i] = _randomVoteSplit();
      }
      Voter[4] memory voters = _setupFractionalVoters(weights, voteSplits);
      _fractionalGovernorHappyPathTest(voters);
    }

}

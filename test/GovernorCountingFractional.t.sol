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

    using FixedPointMathLib for uint256;

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

    Vm vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    // We use a min of 1e4 to avoid flooring votes to 0.
    uint256 constant MIN_VOTE_WEIGHT = 1e4;
    // This is the vote storage slot size on the Fractional Governor contract.
    uint256 constant MAX_VOTE_WEIGHT = type(uint128).max;

    struct FractionalVoteSplit {
      uint256 percentFor; // wad
      uint256 percentAgainst; // wad
      uint256 percentAbstain; // wad
    }

    struct Voter {
      address addr;
      uint256 weight;
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
      assertEq(uint(governor.state(proposalId)), uint(IGovernor.ProposalState.Pending));

      // Advance proposal to active state.
      vm.roll(governor.proposalSnapshot(proposalId) + 1);
      assertEq(uint(governor.state(proposalId)), uint(IGovernor.ProposalState.Active));
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

    function _setupNominalVoters(uint256[4] memory weights) internal returns(Voter[4] memory voters) {
      Voter memory voter;
      for (uint8 _i; _i < voters.length; _i++) {
        voter = voters[_i];
        voter.addr = _randomAddress(weights[_i], _i);
        voter.weight = bound(weights[_i], MIN_VOTE_WEIGHT, MAX_VOTE_WEIGHT / 4);
        voter.support = _randomSupportType(weights[_i]);
      }
    }

    function _randomAddress(uint salt1) public view returns(address) {
      return address(uint160(uint(keccak256(abi.encodePacked(salt1, block.number)))));
    }
    function _randomAddress(uint salt1, uint salt2) public pure returns(address) {
      return address(uint160(uint(keccak256(abi.encodePacked(salt1, salt2)))));
    }

    function _randomSupportType(uint salt) public returns (uint8) {
      return uint8(bound(salt, 0, uint8(GovernorCompatibilityBravo.VoteType.Abstain)));
    }

    function _randomVoteSplit(FractionalVoteSplit memory _voteSplit) public returns(FractionalVoteSplit memory) {
      _voteSplit.percentFor = bound(_voteSplit.percentFor, 0, 1e18);
      _voteSplit.percentAgainst = bound(_voteSplit.percentAgainst, 0, (1e18 - _voteSplit.percentFor));
      _voteSplit.percentAbstain = 1e18 - (_voteSplit.percentFor + _voteSplit.percentAgainst);
      return _voteSplit;
    }

    // Sets up up a 4-Voter array with specified weights and voteSplits, and random supportTypes.
    function _setupFractionalVoters(
      uint256[4] memory weights,
      FractionalVoteSplit[4] memory voteSplits
    ) internal returns(Voter[4] memory voters) {
      voters = _setupNominalVoters(weights);

      Voter memory voter;
      for (uint8 _i; _i < voters.length; _i++) {
        voter = voters[_i];
        FractionalVoteSplit memory split = voteSplits[_i];
        // If the voteSplit has been initialized, we use it.
        if (_isVotingFractionally(split)) {
          // If the values are valid, _randomVoteSplit won't change them.
          voter.voteSplit = _randomVoteSplit(split);
        }
      }
    }

    function _mintAndDelegateToVoter(Voter memory voter) internal {
      // Mint tokens for the user.
      token.THIS_IS_JUST_A_TEST_HOOK_mint(voter.addr, voter.weight);

      // Self-delegate the tokens.
      vm.prank(voter.addr);
      token.delegate(voter.addr);
    }

    function _mintAndDelegateToVoters(Voter[4] memory voters) internal returns(
      uint256 forVotes,
      uint256 againstVotes,
      uint256 abstainVotes
    ) {
      Voter memory voter;

      for(uint8 _i = 0; _i < voters.length; _i++) {
        voter = voters[_i];
        _mintAndDelegateToVoter(voter);

        if (_isVotingFractionally(voter.voteSplit)) {
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

    // If we've set up the voteSplit, this voter will vote fractionally
    function _isVotingFractionally(FractionalVoteSplit memory voteSplit) public pure returns(bool){
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

        if (_isVotingFractionally(voteSplit)) {
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

      (uint256 forVotes, uint256 againstVotes, uint256 abstainVotes) = _mintAndDelegateToVoters(voters);
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

      IGovernor.ProposalState status = IGovernor.ProposalState(uint32(governor.state(_proposalId)));
      if (forVotes > againstVotes && forVotes >= governor.quorum(block.number)) {
        assertEq(uint8(status), uint8(IGovernor.ProposalState.Succeeded));
        _executeProposal();
      } else {
        assertEq(uint8(status), uint8(IGovernor.ProposalState.Defeated));

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
      assertEq(governor.votingPeriod(), 50_400);
      assertEq(governor.quorum(_blockNumber), 10e18);
      assertEq(governor.COUNTING_MODE(), 'support=bravo&quorum=bravo&params=fractional');
    }

    function testFuzz_NominalBehaviorIsUnaffected(uint256[4] memory weights) public {
      Voter[4] memory voters = _setupNominalVoters(weights);
      _fractionalGovernorHappyPathTest(voters);
    }

    function testFuzz_VotingWithFractionalizedParams(
      uint256[4] memory weights,
      FractionalVoteSplit[4] memory _voteSplits
    ) public {
      Voter[4] memory voters = _setupFractionalVoters(weights, _voteSplits);
      _fractionalGovernorHappyPathTest(voters);
    }

    function testFuzz_VoteSplitsCanBeMaxedOut(uint256[4] memory weights, uint8 maxSplit) public {
      maxSplit = uint8(bound(maxSplit, 0, 2));

      Voter[4] memory voters = _setupNominalVoters(weights);

      // We don't actually want these users to vote.
      voters[1].weight = 0;
      voters[2].weight = 0;
      voters[3].weight = 0;

      // Set one of the splits to 100% and all of the others to 0%.
      uint forSplit; uint againstSplit; uint abstainSplit;
      if (maxSplit == 0) forSplit = 1.0e18;
      if (maxSplit == 1) againstSplit = 1.0e18;
      if (maxSplit == 2) abstainSplit = 1.0e18;
      voters[0].voteSplit = FractionalVoteSplit(forSplit, againstSplit, abstainSplit);

      _fractionalGovernorHappyPathTest(voters);
    }

    function testFuzz_VotingWithMixedFractionalAndNominalVoters(
      uint256[4] memory weights,
      FractionalVoteSplit[4] memory voteSplits,
      bool[4] memory userIsFractional
    ) public {
      FractionalVoteSplit memory _emptyVoteSplit;
      for(uint _i; _i < userIsFractional.length; _i++) {
        if (userIsFractional[_i]) {
          // If the user *is* a fractional user, we randomize the splits and make sure they sum to 1e18.
          voteSplits[_i] = _randomVoteSplit(voteSplits[_i]);
        } else {
        // If the user is *not* a fractional user, we clear the split info from the array. This will
        // cause them to cast their vote nominally.
          voteSplits[_i] = _emptyVoteSplit;
        }
      }
      Voter[4] memory voters = _setupFractionalVoters(weights, voteSplits);
      _fractionalGovernorHappyPathTest(voters);
    }

    function testFuzz_FractionalVotingCannotExceedOverallWeight(
      uint256[4] memory weights,
      FractionalVoteSplit[4] memory voteSplits,
      uint256 exceedPercentage,
      uint256 voteTypeToExceed
    ) public {
      exceedPercentage = bound(exceedPercentage, 0.01e18, 1e18); // Between 1 & 100 percent as a wad
      voteTypeToExceed = _randomSupportType(voteTypeToExceed);

      for(uint _i; _i < voteSplits.length; _i++) {
        voteSplits[_i] = _randomVoteSplit(voteSplits[_i]);
      }

      Voter[4] memory voters = _setupFractionalVoters(weights, voteSplits);
      Voter memory voter = voters[0];
      FractionalVoteSplit memory voteSplit = voter.voteSplit;

      if (voteTypeToExceed == 0) voteSplit.percentFor += exceedPercentage;
      if (voteTypeToExceed == 1) voteSplit.percentAgainst += exceedPercentage;
      if (voteTypeToExceed == 2) voteSplit.percentAbstain += exceedPercentage;

      assertGt(voteSplit.percentFor + voteSplit.percentAgainst + voteSplit.percentAbstain, 1e18);

      _mintAndDelegateToVoters(voters);
      uint256 _proposalId = _createAndSubmitProposal();
      bytes memory fractionalizedVotes;

      fractionalizedVotes = abi.encodePacked(
        uint128(voter.weight.mulWadDown(voteSplit.percentFor)),
        uint128(voter.weight.mulWadDown(voteSplit.percentAgainst)),
        uint128(voter.weight.mulWadDown(voteSplit.percentAbstain))
      );

      vm.prank(voter.addr);
      vm.expectRevert("GovernorCountingFractional: votes exceed weight");
      governor.castVoteWithReasonAndParams(_proposalId, voter.support, 'Yay', fractionalizedVotes);
    }

    function testFuzz_OverFlowWeightIsHandledForNominalVoters(uint256 _weight) public {
      Voter memory voter;
      voter.addr = _randomAddress(_weight);
      // The weight cannot overflow the max supply for the token, but must overflow the
      // max for the GovernorFractional contract.
      voter.weight = bound(_weight, MAX_VOTE_WEIGHT, token.THIS_IS_JUST_A_TEST_HOOK_maxSupply());
      voter.support = _randomSupportType(_weight);

      _mintAndDelegateToVoter(voter);
      uint256 _proposalId = _createAndSubmitProposal();

      bytes memory emptyVotingParams;
      vm.prank(voter.addr);
      vm.expectRevert("SafeCast: value doesn't fit in 128 bits");
      governor.castVoteWithReasonAndParams(_proposalId, voter.support, 'Yay', emptyVotingParams);
    }

    function testFuzz_OverFlowWeightIsHandledForFractionalVoters(
      uint256 _weight,
      bool[3] calldata voteTypeToOverflow
    ) public {
      Voter memory voter;
      voter.addr = _randomAddress(_weight);
      // The weight cannot overflow the max supply for the token, but must overflow the
      // max for the GovernorFractional contract.
      voter.weight = bound(_weight, MAX_VOTE_WEIGHT, token.THIS_IS_JUST_A_TEST_HOOK_maxSupply());

      _mintAndDelegateToVoter(voter);
      uint256 _proposalId = _createAndSubmitProposal();

      uint256 forVotes;
      uint256 againstVotes;
      uint256 abstainVotes;

      if (voteTypeToOverflow[0]) forVotes = voter.weight;
      if (voteTypeToOverflow[1]) againstVotes = voter.weight;
      if (voteTypeToOverflow[2]) abstainVotes = voter.weight;

      bytes memory fractionalizedVotes = abi.encodePacked(forVotes, againstVotes, abstainVotes);
      vm.prank(voter.addr);
      vm.expectRevert("GovernorCountingFractional: invalid voteData");
      governor.castVoteWithReasonAndParams(_proposalId, voter.support, 'Weeee', fractionalizedVotes);
    }

    function testFuzz_ParamLengthIsChecked(
      uint256 _weight,
      FractionalVoteSplit memory _voteSplit,
      uint256 invalidParamLength
    ) public {
      invalidParamLength = bound(invalidParamLength, 1, 256);
      vm.assume(invalidParamLength != 48);
      bytes memory fractionalVoteData = new bytes(invalidParamLength);

      Voter memory voter;
      voter.weight = bound(_weight, MIN_VOTE_WEIGHT, MAX_VOTE_WEIGHT);
      voter.voteSplit = _randomVoteSplit(_voteSplit);
      voter.addr = _randomAddress(_weight);

      _mintAndDelegateToVoter(voter);
      uint256 _proposalId = _createAndSubmitProposal();

      vm.expectRevert("GovernorCountingFractional: invalid voteData");
      governor.castVoteWithReasonAndParams(_proposalId, voter.support, 'Weeee', fractionalVoteData);
    }

    function test_QuorumDoesNotIncludeAbstainVotes() public {
      uint256 _weight = governor.quorum(block.number);
      FractionalVoteSplit memory _voteSplit;
      _voteSplit.percentAbstain = 1e18; // All votes go to ABSTAIN.

      _quorumTest(_weight, _voteSplit, uint32(IGovernor.ProposalState.Defeated));
    }

    function test_QuorumDoesIncludeForVotes() public {
      uint256 _weight = governor.quorum(block.number);
      FractionalVoteSplit memory _voteSplit;
      _voteSplit.percentFor = 1e18; // All votes go to FOR.

      _quorumTest(_weight, _voteSplit, uint32(IGovernor.ProposalState.Succeeded));
    }

    function testFuzz_Quorum(uint256 _weight, FractionalVoteSplit memory _voteSplit) public {
      uint256 _quorum = governor.quorum(block.number);
      _weight = bound(_weight, _quorum, MAX_VOTE_WEIGHT);
      _voteSplit = _randomVoteSplit(_voteSplit);

      uint128 _forVotes = uint128(_weight.mulWadDown(_voteSplit.percentFor));
      uint128 _againstVotes = uint128(_weight.mulWadDown(_voteSplit.percentAgainst));

      uint32 _expectedState;
      if (_forVotes >= _quorum && _forVotes > _againstVotes) {
        _expectedState = uint32(IGovernor.ProposalState.Succeeded);
      } else {
        _expectedState = uint32(IGovernor.ProposalState.Defeated);
      }

      _quorumTest(_weight, _voteSplit, _expectedState);
    }

    function _quorumTest(
      uint256 _weight,
      FractionalVoteSplit memory _voteSplit,
      uint32 _expectedState
    ) internal {
      // Build the voter.
      Voter memory _voter;
      _voter.weight = _weight;
      _voter.voteSplit = _voteSplit;
      _voter.addr = _randomAddress(_weight);

      // Mint, delegate, and propose.
      _mintAndDelegateToVoter(_voter);
      uint256 _proposalId = _createAndSubmitProposal();

      // Cast votes.
      bytes memory fractionalizedVotes = abi.encodePacked(
        uint128(_voter.weight.mulWadDown(_voteSplit.percentFor)),
        uint128(_voter.weight.mulWadDown(_voteSplit.percentAgainst)),
        uint128(_voter.weight.mulWadDown(_voteSplit.percentAbstain))
      );
      vm.prank(_voter.addr);
      governor.castVoteWithReasonAndParams(_proposalId, _voter.support, 'Idaho', fractionalizedVotes);

      // Jump ahead so that we're outside of the proposal's voting period.
      vm.roll(governor.proposalDeadline(_proposalId) + 1);
      uint32 _state = uint32(governor.state(_proposalId));
      assertEq(_state, _expectedState);
    }

    function testFuzz_CanCastWithPartialWeight(
      uint256 _salt,
      FractionalVoteSplit memory _voteSplit
    ) public {
      // Build a partial weight vote split.
      _voteSplit = _randomVoteSplit(_voteSplit);
      uint256 _percentKeep = bound(_salt, 0.9e18, 0.99e18); // 90% to 99%
      _voteSplit.percentFor = _voteSplit.percentFor.mulWadDown(_percentKeep);
      _voteSplit.percentAgainst = _voteSplit.percentAgainst.mulWadDown(_percentKeep);
      _voteSplit.percentAbstain = _voteSplit.percentAbstain.mulWadDown(_percentKeep);
      assertGt(1e18, _voteSplit.percentFor + _voteSplit.percentAgainst + _voteSplit.percentAbstain);

      // Build the voter.
      Voter memory _voter;
      _voter.addr = _randomAddress(_salt);
      _voter.weight = bound(_salt, MIN_VOTE_WEIGHT, MAX_VOTE_WEIGHT);
      _voter.voteSplit = _voteSplit;

      // Mint, delegate, and propose.
      _mintAndDelegateToVoter(_voter);
      uint256 _proposalId = _createAndSubmitProposal();

      // The important thing is just that the abstain votes *cannot* be inferred from
      // the for-votes and against-votes, e.g. by subtracting them from the total weight.
      uint128 _forVotes = uint128(_voter.weight.mulWadDown(_voteSplit.percentFor));
      uint128 _againstVotes = uint128(_voter.weight.mulWadDown(_voteSplit.percentAgainst));
      uint128 _abstainVotes = uint128(_voter.weight.mulWadDown(_voteSplit.percentAbstain));
      assertGt(_voter.weight - _forVotes - _againstVotes, _abstainVotes);

      // Cast votes.
      bytes memory fractionalizedVotes = abi.encodePacked(_forVotes, _againstVotes, _abstainVotes);
      vm.prank(_voter.addr);
      governor.castVoteWithReasonAndParams(_proposalId, _voter.support, 'Lobster', fractionalizedVotes);

      (
        uint256 _actualAgainstVotes,
        uint256 _actualForVotes,
        uint256 _actualAbstainVotes
      ) = governor.proposalVotes(_proposalId);
      assertEq(_forVotes, _actualForVotes);
      assertEq(_againstVotes, _actualAgainstVotes);
      assertEq(_abstainVotes, _actualAbstainVotes);
    }
}

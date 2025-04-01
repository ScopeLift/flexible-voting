// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {Checkpoints} from "@openzeppelin/contracts/utils/structs/Checkpoints.sol";
import {IFractionalGovernor} from "src/interfaces/IFractionalGovernor.sol";
import {IVotingToken} from "src/interfaces/IVotingToken.sol";
import {FlexVotingBase} from "src/FlexVotingBase.sol";

/// @notice This is an abstract contract designed to make it easy to build clients
/// for governance systems that inherit from GovernorCountingFractional, a.k.a.
/// Flexible Voting governors.
///
/// This contract extends FlexVotingBase, adding two features:
///   (a) the ability for depositors to express voting preferences on
///       {Governor}'s proposals, and
///   (b) the ability to cast fractional, rolled up votes on behalf of depositors.
abstract contract FlexVotingClient is FlexVotingBase {
  using Checkpoints for Checkpoints.Trace208;
  using SafeCast for uint256;

  /// @notice The voting options. The order of options should match that of the
  /// voting options in the corresponding {Governor} contract.
  enum VoteType {
    Against,
    For,
    Abstain
  }

  /// @notice Data structure to store vote preferences expressed by depositors.
  struct ProposalVote {
    uint128 againstVotes;
    uint128 forVotes;
    uint128 abstainVotes;
  }

  /// @dev Map governor to proposalId to an address to whether they have voted on the proposal.
  mapping(IFractionalGovernor => mapping(uint256 => mapping(address => bool))) private proposalVoterHasVoted;

  /// @notice Map governor to proposalId to vote totals expressed on the proposal.
  mapping(IFractionalGovernor => mapping(uint256 => mapping(uint256 => ProposalVote))) public proposalVotes;

  /// Constant used by OZ's implementation of {GovernorCountingFractional} to
  /// signal fractional voting.
  /// https://github.com/OpenZeppelin/openzeppelin-contracts/blob/7b74442c5e87ea51dde41c7f18a209fa5154f1a4/contracts/governance/extensions/GovernorCountingFractional.sol#L37
  uint8 internal constant VOTE_TYPE_FRACTIONAL = 255;

  error FlexVotingClient__NoVotingWeight();
  error FlexVotingClient__AlreadyVoted();
  error FlexVotingClient__InvalidSupportValue();
  error FlexVotingClient__NoVotesExpressed();

  /// @dev Used as the `reason` param when submitting a vote to `_governor`.
  function _castVoteReasonString(IFractionalGovernor /*_governor*/) internal virtual returns (string memory) {
    return "rolled-up vote from governance token holders";
  }

  /// @notice Allow the caller to express their voting preference for a given
  /// proposal. Their preference is recorded internally but not moved to the
  /// Governor until `castVote` is called.
  /// @param governor The governor that the voting preference is related to.
  /// @param proposalId The ID of the proposal in the associated governor.
  /// @param support The depositor's vote preference in accordance with the `VoteType` enum.
  function expressVote(IFractionalGovernor governor, uint256 proposalId, uint8 support) external virtual {
    if (!supportedGovernors[governor])
      revert FlexVotingBase.FlexVotingBase__UnsupportedGovernor(address(governor));

    address voter = msg.sender;
    uint256 weight = getPastVoteWeight(governor, voter, governor.proposalSnapshot(proposalId));
    if (weight == 0) revert FlexVotingClient__NoVotingWeight();

    if (proposalVoterHasVoted[governor][proposalId][voter])
      revert FlexVotingClient__AlreadyVoted();
    proposalVoterHasVoted[governor][proposalId][voter] = true;

    if (support == uint8(VoteType.Against)) {
      proposalVotes[governor][proposalId].againstVotes += SafeCast.toUint128(weight);
    } else if (support == uint8(VoteType.For)) {
      proposalVotes[governor][proposalId].forVotes += SafeCast.toUint128(weight);
    } else if (support == uint8(VoteType.Abstain)) {
      proposalVotes[governor][proposalId].abstainVotes += SafeCast.toUint128(weight);
    } else {
      // Support value must be included in VoteType enum.
      revert FlexVotingClient__InvalidSupportValue();
    }
  }

  /// @notice Causes this contract to cast a vote to the `governor` for all of the
  /// accumulated votes expressed by users. Uses the total internal vote weight
  /// to proportionally split weight among expressed votes. Can be called by
  /// anyone. It is idempotent and can be called multiple times during the
  /// lifecycle of a given proposal.
  /// @param governor The governor that votes will be cast to.
  /// @param proposalId The ID of the proposal on which votes will be cast.
  function castVote(IFractionalGovernor governor, uint256 proposalId) external {
    if (!supportedGovernors[governor])
      revert FlexVotingBase.FlexVotingBase__UnsupportedGovernor(address(governor));

    ProposalVote storage _proposalVote = proposalVotes[governor][proposalId];
    if (_proposalVote.forVotes + _proposalVote.againstVotes + _proposalVote.abstainVotes == 0) {
      revert FlexVotingClient__NoVotesExpressed();
    }

    uint256 _proposalSnapshot = governor.proposalSnapshot(proposalId);

    // We use the snapshot of total vote weight to determine the weight with
    // which to vote. We do this for two reasons:
    //   (1) We cannot use the proposalVote numbers alone, since some people with
    //       balances at the snapshot might never express their preferences. If a
    //       large holder never expressed a preference, but this contract nevertheless
    //       cast votes to the governor with all of its weight, then other users may
    //       effectively have *increased* their voting weight because someone else
    //       didn't participate, which creates all kinds of bad incentives.
    //   (2) Other people might have already expressed their preferences on this
    //       proposal and had those preferences submitted to the governor by an
    //       earlier call to this function. The weight of those preferences
    //       should still be taken into consideration when determining how much
    //       weight to vote with this time.
    // Using the total vote weight to proportion votes in this way means that in
    // many circumstances this function will not cast votes with all of its
    // weight.
    uint256 _totalVotesInternal = getPastTotalVoteWeight(governor, _proposalSnapshot);

    // We need 256 bits because of the multiplication we're about to do.
    uint256 _totalTokenWeight =
      IVotingToken(address(governor.token())).getPastVotes(address(this), _proposalSnapshot);

    //     userVotesInternal          userVoteWeight
    // ------------------------- = --------------------
    //     totalVotesInternal         totalTokenWeight
    //
    // userVoteWeight = userVotesInternal * totalTokenWeight / totalVotesInternal
    uint128 _forVotesToCast =
      SafeCast.toUint128((_totalTokenWeight * _proposalVote.forVotes) / _totalVotesInternal);
    uint128 _againstVotesToCast =
      SafeCast.toUint128((_totalTokenWeight * _proposalVote.againstVotes) / _totalVotesInternal);
    uint128 _abstainVotesToCast =
      SafeCast.toUint128((_totalTokenWeight * _proposalVote.abstainVotes) / _totalVotesInternal);

    // Clear the stored votes so that we don't double-cast them.
    delete proposalVotes[governor][proposalId];

    bytes memory fractionalizedVotes =
      abi.encodePacked(_againstVotesToCast, _forVotesToCast, _abstainVotesToCast);
    governor.castVoteWithReasonAndParams(
      proposalId, VOTE_TYPE_FRACTIONAL, _castVoteReasonString(governor), fractionalizedVotes
    );
  }

  /// @notice Returns the `_user`'s internal voting weight with `_governor` at
  /// `_timepoint`.
  /// @param _governor The governor that the voting weight is related to.
  /// @param _user The account that's historical vote weight will be looked up.
  /// @param _timepoint The timepoint at which to lookup the _user's internal
  /// voting weight, either a block number or a timestamp as determined by
  /// {GOVERNOR.token().clock()}.
  function getPastVoteWeight(IFractionalGovernor _governor, address _user, uint256 _timepoint) public view returns (uint256) {
    uint48 key = SafeCast.toUint48(_timepoint);
    return voteWeightCheckpoints[_governor][_user].upperLookup(key);
  }

  /// @notice Returns the total internal voting weight of all users at `_timepoint`.
  /// @param _governor The governor that the voting weight is related to.
  /// @param _timepoint The timepoint at which to lookup the total weight,
  /// either a block number or a timestamp as determined by
  /// {GOVERNOR.token().clock()}.
  function getPastTotalVoteWeight(IFractionalGovernor _governor, uint256 _timepoint) public view returns (uint256) {
    uint48 key = SafeCast.toUint48(_timepoint);
    return totalVoteWeightCheckpoints[_governor].upperLookup(key);
  }
}

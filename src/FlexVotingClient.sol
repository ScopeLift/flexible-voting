// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8.10;

import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {Checkpoints} from "@openzeppelin/contracts/utils/Checkpoints.sol";
import {IFractionalGovernor} from "src/interfaces/IFractionalGovernor.sol";
import {IVotingToken} from "src/interfaces/IVotingToken.sol";

// TODO natspec
// this is a contract to make it easy to build clients for flex voting governors.
abstract contract FlexVotingClient {
  using SafeCast for uint256;
  using Checkpoints for Checkpoints.History;

  /// @notice The voting options corresponding to those used in the Governor.
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

  /// @notice Map proposalId to an address to whether they have voted on this proposal.
  mapping(uint256 => mapping(address => bool)) private proposalVotersHasVoted;

  /// @notice Map proposalId to vote totals expressed on this proposal.
  mapping(uint256 => ProposalVote) public proposalVotes;

  /// @notice The governor contract associated with this governance token. It
  /// must be one that supports fractional voting, e.g. GovernorCountingFractional.
  IFractionalGovernor public immutable GOVERNOR;

  /// @notice Mapping from address to stored (not rebased) balance checkpoint history.
  mapping(address => Checkpoints.History) private balanceCheckpoints;

  /// @notice History of total stored (not rebased) balances.
  Checkpoints.History internal totalDepositCheckpoints;

  /// @dev Constructor.
  /// @param _governor The address of the flex-voting-compatible governance contract.
  constructor(address _governor) {
    GOVERNOR = IFractionalGovernor(_governor);
  }

  /// @notice Returns the _user's current balance in storage. If the balance
  /// rebases this should return the non-rebased value, i.e. the value before
  /// any computations are run or interest is applied.
  function _rawBalanceOf(address _user) internal view virtual returns (uint256);

  // TODO add natspec
  function _selfDelegate() internal {
    IVotingToken(GOVERNOR.token()).delegate(address(this));
  }

  /// @notice Allow a depositor to express their voting preference for a given
  /// proposal. Their preference is recorded internally but not moved to the
  /// Governor until `castVote` is called.
  /// @param proposalId The proposalId in the associated Governor
  /// @param support The depositor's vote preferences in accordance with the `VoteType` enum.
  function expressVote(uint256 proposalId, uint8 support) external {
    uint256 weight = getPastStoredBalance(msg.sender, GOVERNOR.proposalSnapshot(proposalId));
    require(weight > 0, "no weight");

    require(!proposalVotersHasVoted[proposalId][msg.sender], "already voted");
    proposalVotersHasVoted[proposalId][msg.sender] = true;

    if (support == uint8(VoteType.Against)) {
      proposalVotes[proposalId].againstVotes += SafeCast.toUint128(weight);
    } else if (support == uint8(VoteType.For)) {
      proposalVotes[proposalId].forVotes += SafeCast.toUint128(weight);
    } else if (support == uint8(VoteType.Abstain)) {
      proposalVotes[proposalId].abstainVotes += SafeCast.toUint128(weight);
    } else {
      revert("invalid support value, must be included in VoteType enum");
    }
  }

  /// @notice Causes this contract to cast a vote to the Governor for all of the
  /// accumulated votes expressed by users. Uses the sum of all raw (unrebased) balances
  /// to proportionally split its voting weight. Can be called by anyone. Can be called
  /// multiple times during the lifecycle of a given proposal.
  /// @param proposalId The ID of the proposal which the Pool will now vote on.
  function castVote(uint256 proposalId) external {
    ProposalVote storage _proposalVote = proposalVotes[proposalId];
    require(
      _proposalVote.forVotes + _proposalVote.againstVotes + _proposalVote.abstainVotes > 0,
      "no votes expressed"
    );
    uint256 _proposalSnapshotBlockNumber = GOVERNOR.proposalSnapshot(proposalId);

    // We use the snapshot of total raw balances to determine the weight with
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
    // Using the total raw balance to proportion votes in this way means that in
    // many circumstances this function will not cast votes with all of its
    // weight.
    uint256 _totalRawBalanceAtSnapshot = getPastTotalBalance(_proposalSnapshotBlockNumber);

    // We need 256 bits because of the multiplication we're about to do.
    uint256 _votingWeightAtSnapshot = IVotingToken(address(GOVERNOR.token())).getPastVotes(
      address(this), _proposalSnapshotBlockNumber
    );

    //      forVotesRaw          forVoteWeight
    // --------------------- = ------------------
    //     totalRawBalance      totalVoteWeight
    //
    // forVoteWeight = forVotesRaw * totalVoteWeight / totalRawBalance
    uint128 _forVotesToCast = SafeCast.toUint128(
      (_votingWeightAtSnapshot * _proposalVote.forVotes) / _totalRawBalanceAtSnapshot
    );
    uint128 _againstVotesToCast = SafeCast.toUint128(
      (_votingWeightAtSnapshot * _proposalVote.againstVotes) / _totalRawBalanceAtSnapshot
    );
    uint128 _abstainVotesToCast = SafeCast.toUint128(
      (_votingWeightAtSnapshot * _proposalVote.abstainVotes) / _totalRawBalanceAtSnapshot
    );

    // This param is ignored by the governor when voting with fractional
    // weights. It makes no difference what vote type this is.
    uint8 unusedSupportParam = uint8(VoteType.Abstain);

    // Clear the stored votes so that we don't double-cast them.
    delete proposalVotes[proposalId];

    bytes memory fractionalizedVotes =
      abi.encodePacked(_againstVotesToCast, _forVotesToCast, _abstainVotesToCast);
    GOVERNOR.castVoteWithReasonAndParams(
      proposalId,
      unusedSupportParam,
      "rolled-up vote from governance token holders", // Reason string.
      fractionalizedVotes
    );
  }

  /// @notice Checkpoints the _user's current raw balance.
  function _checkpointRawBalanceOf(address _user) internal {
    balanceCheckpoints[_user].push(_rawBalanceOf(_user));
  }

  /// @notice Returns the _user's balance in storage at the _blockNumber.
  /// @param _user The account that's historical balance will be looked up.
  /// @param _blockNumber The block at which to lookup the _user's balance.
  function getPastStoredBalance(address _user, uint256 _blockNumber) public view returns (uint256) {
    return balanceCheckpoints[_user].getAtProbablyRecentBlock(_blockNumber);
  }

  /// @notice Returns the total stored balance of all users at _blockNumber.
  /// @param _blockNumber The block at which to lookup the total stored balance.
  function getPastTotalBalance(uint256 _blockNumber) public view returns (uint256) {
    return totalDepositCheckpoints.getAtProbablyRecentBlock(_blockNumber);
  }
}

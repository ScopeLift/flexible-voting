// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IFractionalGovernor} from "src/interfaces/IFractionalGovernor.sol";
import {IVotingToken} from "src/interfaces/IVotingToken.sol";

///  @notice A proof-of-concept implementation demonstrating how Flexible Voting can be used to
///  allow holders of governance tokens to use them in DeFi but still participate in governance. The
///  FractionalPool simulates a lending protocol, such as Compound Finance or Aave, in that:
///
///  - Tokens can be deposited into the Pool by suppliers
///  - Tokens can be withdrawn from the Pool by borrowers
///  - Depositors are able to express their vote preferences on individual governance proposals
///  - The vote preferences of all Depositors are expressed proportionally across any tokens held by
///    the pool, and rolled up into a single delegated vote made by the pool before the proposal is
///    completed
contract FractionalPool {
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

  /// @notice Must call castVote within this many blocks of the proposal deadline, so-as to allow
  /// ample time for all
  /// depositors to express their vote preferences.
  uint32 public constant CAST_VOTE_WINDOW = 1200; // In blocks; 4 hours assuming 12 second blocks.

  /// @notice The governance token held and lent by this pool.
  IVotingToken public immutable TOKEN;

  /// @notice The governor contract associated with this governance token.
  IFractionalGovernor public immutable GOVERNOR;

  /// @notice Map depositor to deposit amount.
  mapping(address => uint256) public deposits;

  /// @notice Map borrower to total amount borrowed.
  mapping(address => uint256) public borrowTotal;

  /// @notice Map proposalId to an address to whether they have voted on this proposal.
  mapping(uint256 => mapping(address => bool)) private _proposalVotersHasVoted;

  /// @notice Map proposalId to vote totals expressed on this proposal.
  mapping(uint256 => ProposalVote) public proposalVotes;

  /// @param _token The governance token held and lent by this pool.
  /// @param _governor The governor contract associated with this governance token.
  constructor(IVotingToken _token, IFractionalGovernor _governor) {
    TOKEN = _token;
    GOVERNOR = _governor;
    _token.delegate(address(this));
  }

  /// @notice Allow a holder of the governance token to deposit it into the pool.
  /// @param _amount The amount to be deposited.
  function deposit(uint256 _amount) public {
    deposits[msg.sender] += _amount;

    _writeCheckpoint(_checkpoints[msg.sender], _additionFn, _amount);
    _writeCheckpoint(_totalDepositCheckpoints, _additionFn, _amount);

    TOKEN.transferFrom(msg.sender, address(this), _amount); // Assumes revert on failure.
  }

  /// @notice Allow a depositor to withdraw funds previously deposited to the pool.
  /// @param _amount The amount to be withdrawn.
  function withdraw(uint256 _amount) public {
    // Overflows & reverts if user does not have sufficient deposits.
    deposits[msg.sender] -= _amount;

    _writeCheckpoint(_checkpoints[msg.sender], _subtractionFn, _amount);
    _writeCheckpoint(_totalDepositCheckpoints, _subtractionFn, _amount);

    TOKEN.transfer(msg.sender, _amount); // Assumes revert on failure.
  }

  /// @notice Arbitrarily remove tokens from the pool. This is to simulate a borrower, hence the
  /// method name. Since this is just a proof-of-concept, nothing else is actually done here.
  /// @param _amount The amount to "borrow."
  function borrow(uint256 _amount) public {
    borrowTotal[msg.sender] += _amount;
    TOKEN.transfer(msg.sender, _amount);
  }

  /// @notice Allow a depositor to express their voting preference for a given proposal. Their
  /// preference is recorded internally but not moved to the Governor until `castVote` is called.
  /// @param proposalId The proposalId in the associated Governor
  /// @param support The depositor's vote preferences in accordance with the `VoteType` enum.
  function expressVote(uint256 proposalId, uint8 support) external {
    uint256 weight = getPastDeposits(msg.sender, GOVERNOR.proposalSnapshot(proposalId));
    if (weight == 0) revert("no weight");

    if (_proposalVotersHasVoted[proposalId][msg.sender]) revert("already voted");
    _proposalVotersHasVoted[proposalId][msg.sender] = true;

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

  /// @notice Causes this contract to cast a vote to the Governor for all the tokens it currently
  /// holds. Uses the sum of all depositor voting expressions to decide how to split its voting
  /// weight. Can be called by anyone, but _must_ be called within `CAST_VOTE_WINDOW` blocks before
  /// the proposal deadline.
  /// @param proposalId The ID of the proposal which the Pool will now vote on.
  function castVote(uint256 proposalId) external {
    if (internalVotingPeriodEnd(proposalId) > block.number) revert("cannot castVote yet");
    uint8 unusedSupportParam = uint8(VoteType.Abstain);
    ProposalVote memory _proposalVote = proposalVotes[proposalId];

    uint256 _proposalSnapshotBlockNumber = GOVERNOR.proposalSnapshot(proposalId);

    // Use the snapshot of total deposits to determine total voting weight. We cannot
    // use the proposalVote numbers alone, since some people with deposits at the
    // snapshot might not have expressed votes.
    uint256 _totalDepositWeightAtSnapshot = getPastTotalDeposits(_proposalSnapshotBlockNumber);

    // We need 256 bits because of the multiplication we're about to do.
    uint256 _votingWeightAtSnapshot =
      TOKEN.getPastVotes(address(this), _proposalSnapshotBlockNumber);

    //      forVotesRaw          forVotesScaled
    // --------------------- = ---------------------
    //     totalDeposits        deposits (@snapshot)
    //
    // forVotesScaled = forVotesRaw * deposits@snapshot / totalDeposits
    uint128 _forVotesToCast = SafeCast.toUint128(
      (_votingWeightAtSnapshot * _proposalVote.forVotes) / _totalDepositWeightAtSnapshot
    );
    uint128 _againstVotesToCast = SafeCast.toUint128(
      (_votingWeightAtSnapshot * _proposalVote.againstVotes) / _totalDepositWeightAtSnapshot
    );
    uint128 _abstainVotesToCast = SafeCast.toUint128(
      (_votingWeightAtSnapshot * _proposalVote.abstainVotes) / _totalDepositWeightAtSnapshot
    );

    bytes memory fractionalizedVotes =
      abi.encodePacked(_againstVotesToCast, _forVotesToCast, _abstainVotesToCast);
    GOVERNOR.castVoteWithReasonAndParams(
      proposalId, unusedSupportParam, "crowd-sourced vote", fractionalizedVotes
    );
  }

  /// @notice Method which returns the deadline for depositors to express their voting preferences
  /// to this Pool contract. Will always be before the Governor's corresponding proposal deadline.
  /// @param proposalId The ID of the proposal in question.
  function internalVotingPeriodEnd(uint256 proposalId)
    public
    view
    returns (uint256 _lastVotingBlock)
  {
    _lastVotingBlock = GOVERNOR.proposalDeadline(proposalId) - CAST_VOTE_WINDOW;
  }

  /// ===========================================================================
  /// BEGIN: Checkpointing code.
  /// ===========================================================================
  /// This has been copied from OZ's ERC20Votes checkpointing system with minor revisions:
  ///   * Replace "Vote" with "Deposit", as deposits are what we need to track
  ///   * Make some variable names longer for readibility
  ///
  /// We're disabling forgefmt to make this as easy as possible to diff with OZ's version.
  /// forgefmt: disable-start
  ///
  /// Reference code:
  ///   https://github.com/OpenZeppelin/openzeppelin-contracts/blob/d5ca39e9a264ddcadd5742484b6d391ae1647a10/contracts/token/ERC20/extensions/ERC20Votes.sol
  struct Checkpoint {
      uint32 fromBlock;
      uint224 deposits;
  }
  mapping(address => Checkpoint[]) private _checkpoints;
  Checkpoint[] private _totalDepositCheckpoints;
  function checkpoints(address account, uint32 pos) public view virtual returns (Checkpoint memory) {
      return _checkpoints[account][pos];
  }
  function getDeposits(address account) public view virtual returns (uint256) {
      uint256 pos = _checkpoints[account].length;
      return pos == 0 ? 0 : _checkpoints[account][pos - 1].deposits;
  }
  function getPastDeposits(address account, uint256 blockNumber) public view virtual returns (uint256) {
      require(blockNumber < block.number, "block not yet mined");
      return _checkpointsLookup(_checkpoints[account], blockNumber);
  }
  function getPastTotalDeposits(uint256 blockNumber) public view virtual returns (uint256) {
      require(blockNumber < block.number, "block not yet mined");
      return _checkpointsLookup(_totalDepositCheckpoints, blockNumber);
  }
  function _checkpointsLookup(Checkpoint[] storage ckpts, uint256 blockNumber) private view returns (uint256) {
      // We run a binary search to look for the earliest checkpoint taken after `blockNumber`.
      uint256 high = ckpts.length;
      uint256 low = 0;
      while (low < high) {
          uint256 mid = Math.average(low, high);
          if (ckpts[mid].fromBlock > blockNumber) {
              high = mid;
          } else {
              low = mid + 1;
          }
      }
      return high == 0 ? 0 : ckpts[high - 1].deposits;
  }
  function _writeCheckpoint(
      Checkpoint[] storage ckpts,
      function(uint256, uint256) view returns (uint256) operation,
      uint256 delta
  ) private returns (uint256 oldWeight, uint256 newWeight) {
      uint256 position = ckpts.length;
      oldWeight = position == 0 ? 0 : ckpts[position - 1].deposits;
      newWeight = operation(oldWeight, delta);

      if (position > 0 && ckpts[position - 1].fromBlock == block.number) {
          ckpts[position - 1].deposits = SafeCast.toUint224(newWeight);
      } else {
          ckpts.push(Checkpoint({fromBlock: SafeCast.toUint32(block.number), deposits: SafeCast.toUint224(newWeight)}));
      }
  }
  function _additionFn(uint256 a, uint256 b) private pure returns (uint256) {
      return a + b;
  }

  function _subtractionFn(uint256 a, uint256 b) private pure returns (uint256) {
      return a - b;
  }
  /// ===========================================================================
  /// END: Checkpointing code.
  /// ===========================================================================
  /// forgefmt: disable-end
}

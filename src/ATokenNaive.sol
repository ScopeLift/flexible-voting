// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.10;

import {AToken} from "aave-v3-core/contracts/protocol/tokenization/AToken.sol";
import {Errors} from "aave-v3-core/contracts/protocol/libraries/helpers/Errors.sol";
import {GPv2SafeERC20} from "aave-v3-core/contracts/dependencies/gnosis/contracts/GPv2SafeERC20.sol";
import {IAToken} from "aave-v3-core/contracts/interfaces/IAToken.sol";
import {IERC20} from "aave-v3-core/contracts/dependencies/openzeppelin/contracts/IERC20.sol";
import {IPool} from "aave-v3-core/contracts/interfaces/IPool.sol";
import {WadRayMath} from "aave-v3-core/contracts/protocol/libraries/math/WadRayMath.sol";
import {SafeCast} from "openzeppelin-contracts/contracts/utils/math/SafeCast.sol";
import {Math} from "openzeppelin-contracts/contracts/utils/math/Math.sol";

interface IFractionalGovernor {
  function token() external returns (address);
  function proposalSnapshot(uint256 proposalId) external view returns (uint256);
  function proposalDeadline(uint256 proposalId) external view returns (uint256);
  function castVoteWithReasonAndParams(
    uint256 proposalId,
    uint8 support,
    string calldata reason,
    bytes memory params
  ) external returns (uint256);
}

interface IVotingToken {
  function transfer(address to, uint256 amount) external returns (bool);
  function transferFrom(address from, address to, uint256 amount) external returns (bool);
  function delegate(address delegatee) external;
  function getPastVotes(address account, uint256 blockNumber) external view returns (uint256);
}

contract ATokenNaive is AToken {
  using WadRayMath for uint256;
  using SafeCast for uint256;
  using GPv2SafeERC20 for IERC20;

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

  /// @notice The number of blocks prior to the proposal deadline within which
  /// `castVote` may be called. Prior to this window, `castVote` will revert so
  /// as to give users time to call `expressVote` before votes are sent to the
  /// governor contract.
  uint32 public immutable CAST_VOTE_WINDOW;

  /// @notice Map proposalId to an address to whether they have voted on this proposal.
  mapping(uint256 => mapping(address => bool)) private _proposalVotersHasVoted;

  /// @notice Map proposalId to vote totals expressed on this proposal.
  mapping(uint256 => ProposalVote) public proposalVotes;

  /// @notice The governor contract associated with this governance token. It
  /// must be one that supports fractional voting, e.g.
  /// GovernorCountingFractional.
  IFractionalGovernor public immutable governor;

  /// @dev Constructor.
  /// @param _pool The address of the Pool contract
  /// @param _governor The address of the flex-voting-compatible governance contract.
  /// @param _castVoteWindow The number of blocks that users have to express
  /// their votes on a proposal before votes can be cast.
  constructor(IPool _pool, address _governor, uint32 _castVoteWindow) AToken(_pool) {
    governor = IFractionalGovernor(_governor);
    CAST_VOTE_WINDOW = _castVoteWindow;
  }

  // TODO Is there a better way to do this? It cannot be done in the constructor
  // because the AToken is just used a proxy -- it won't share an address with
  // the implementation (i.e. this code).
  function selfDelegate() public {
    IVotingToken(governor.token()).delegate(address(this));
  }

  /// @notice Method which returns the deadline (as a block number) by which
  /// depositors must express their voting preferences to this Pool contract. It
  /// will always be before the Governor's corresponding proposal deadline. The
  /// dealine is exclusive, meaning: if this returns (say) block 424242, then the
  /// internal voting period will be over on block 424242. The last block for
  /// internal voting will be 424241.
  /// @param proposalId The ID of the proposal in question.
  function internalVotingPeriodEnd(uint256 proposalId)
    public
    view
    returns (uint256 _lastVotingBlock)
  {
    _lastVotingBlock = governor.proposalDeadline(proposalId) - CAST_VOTE_WINDOW;
  }

  /// TODO how to handle onBehalfOf?
  /// TODO should this revert if the vote has been cast?
  /// @notice Allow a depositor to express their voting preference for a given
  /// proposal. Their preference is recorded internally but not moved to the
  /// Governor until `castVote` is called. We deliberately do NOT revert if the
  /// internalVotingPeriodEnd has passed.
  /// @param proposalId The proposalId in the associated Governor
  /// @param support The depositor's vote preferences in accordance with the `VoteType` enum.
  function expressVote(uint256 proposalId, uint8 support) external {
    uint256 weight = getPastDeposits(msg.sender, governor.proposalSnapshot(proposalId));
    require(weight > 0, "no weight");

    require(!_proposalVotersHasVoted[proposalId][msg.sender], "already voted");
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

  /// @notice Causes this contract to cast a vote to the Governor for all the
  /// tokens it currently holds. Uses the sum of all depositor voting
  /// expressions to decide how to split its voting weight. Can be called by
  /// anyone, but _must_ be called within `CAST_VOTE_WINDOW` blocks before the
  /// proposal deadline. We don't bother to check if the vote has already been
  /// cast -- GovernorCountingFractional will revert if it has.
  /// @param proposalId The ID of the proposal which the Pool will now vote on.
  function castVote(uint256 proposalId) external {
    require(
      internalVotingPeriodEnd(proposalId) <= block.number,
      "cannot castVote during internal voting period"
    );

    ProposalVote storage _proposalVote = proposalVotes[proposalId];

    uint256 _proposalSnapshotBlockNumber = governor.proposalSnapshot(proposalId);

    // Use the snapshot of total deposits to determine total voting weight. We cannot
    // use the proposalVote numbers alone, since some people with deposits at the
    // snapshot might not have expressed votes.
    uint256 _totalDepositWeightAtSnapshot = getPastTotalDeposits(_proposalSnapshotBlockNumber);

    // We need 256 bits because of the multiplication we're about to do.
    uint256 _votingWeightAtSnapshot = IVotingToken(address(_underlyingAsset)).getPastVotes(
      address(this), _proposalSnapshotBlockNumber
    );

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

    // This param is ignored by the governor when voting with fractional
    // weights. It makes no difference what vote type this is.
    uint8 unusedSupportParam = uint8(VoteType.Abstain);

    bytes memory fractionalizedVotes =
      abi.encodePacked(_forVotesToCast, _againstVotesToCast, _abstainVotesToCast);
    governor.castVoteWithReasonAndParams(
      proposalId, unusedSupportParam, "crowd-sourced vote", fractionalizedVotes
    );
  }

  /// @notice Implements the basic logic to mint a scaled balance token.
  /// @param caller The address performing the mint
  /// @param onBehalfOf The address of the user that will receive the scaled tokens
  /// @param amount The amount of tokens getting minted
  /// @param index The next liquidity index of the reserve
  /// @return `true` if the the previous balance of the user was 0
  function _mintScaledWithCheckpoint(
    address caller,
    address onBehalfOf,
    uint256 amount,
    uint256 index
  ) internal returns (bool) {
    bool _returnVar = _mintScaled(caller, onBehalfOf, amount, index);

    // We increment by `amount` instead of any computed/rebased amounts because
    // `amount` is what actually gets transferred of the underlying asset. We
    // need our checkpoints to still match up with the underlying asset balance.
    _writeCheckpoint(_checkpoints[onBehalfOf], _additionFn, amount);
    _writeCheckpoint(_totalDepositCheckpoints, _additionFn, amount);

    return _returnVar;
  }

  // forgefmt: disable-start
  //===========================================================================
  // BEGIN: Aave overrides
  //===========================================================================
  /// Note: this has been modified from Aave v3's AToken to call our custom
  /// mintScaledWithCheckpoint function.
  ///
  /// @inheritdoc IAToken
  function mint(
    address caller,
    address onBehalfOf,
    uint256 amount,
    uint256 index
  ) external virtual override onlyPool returns (bool) {
    return _mintScaledWithCheckpoint(caller, onBehalfOf, amount, index);
  }

  /// Note: this has been modified from Aave v3's AToken to call our custom
  /// mintScaledWithCheckpoint function.
  ///
  /// @inheritdoc IAToken
  function mintToTreasury(uint256 amount, uint256 index) external override onlyPool {
    if (amount == 0) {
      return;
    }
    _mintScaledWithCheckpoint(address(POOL), _treasury, amount, index);
  }

  /// Note: this has been modified from Aave v3's AToken to update deposit
  /// balance accordingly. We cannot just call `super` here because the function
  /// is external.
  ///
  /// @inheritdoc IAToken
  function burn(
    address from,
    address receiverOfUnderlying,
    uint256 amount,
    uint256 index
  ) external virtual override onlyPool {
    // Begin modifications.
    //
    // We decrement by `amount` instead of any computed/rebased amounts because
    // `amount` is what actually gets transferred of the underlying asset. We
    // need our checkpoints to still match up with the underlying asset balance.
    _writeCheckpoint(_checkpoints[from], _subtractionFn, amount);
    _writeCheckpoint(_totalDepositCheckpoints, _subtractionFn, amount);
    // End modifications.

    _burnScaled(from, receiverOfUnderlying, amount, index);
    if (receiverOfUnderlying != address(this)) {
      IERC20(_underlyingAsset).safeTransfer(receiverOfUnderlying, amount);
    }
  }
  //===========================================================================
  // END: Aave overrides
  //===========================================================================

  //===========================================================================
  // BEGIN: Checkpointing code.
  //===========================================================================
  // This was been copied from OZ's ERC20Votes checkpointing system with minor
  // revisions:
  //   * Replace "Vote" with "Deposit", as deposits are what we need to track
  //   * Make some variable names longer for readability
  //   * Break lines at 80-characters
  struct Checkpoint {
    uint32 fromBlock;
    uint224 deposits;
  }
  mapping(address => Checkpoint[]) private _checkpoints;
  Checkpoint[] private _totalDepositCheckpoints;
  function checkpoints(
    address account,
    uint32 pos
  ) public view virtual returns (Checkpoint memory) {
    return _checkpoints[account][pos];
  }
  function getDeposits(address account) public view virtual returns (uint256) {
    uint256 pos = _checkpoints[account].length;
    return pos == 0 ? 0 : _checkpoints[account][pos - 1].deposits;
  }
  function getPastDeposits(
    address account,
    uint256 blockNumber
  ) public view virtual returns (uint256) {
    require(blockNumber < block.number, "block not yet mined");
    return _checkpointsLookup(_checkpoints[account], blockNumber);
  }
  function getPastTotalDeposits(
    uint256 blockNumber
  ) public view virtual returns (uint256) {
    require(blockNumber < block.number, "block not yet mined");
    return _checkpointsLookup(_totalDepositCheckpoints, blockNumber);
  }
  function _checkpointsLookup(
    Checkpoint[] storage ckpts,
    uint256 blockNumber
  ) private view returns (uint256) {
    // We run a binary search to look for the earliest checkpoint taken after
    // `blockNumber`.
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
      ckpts.push(
        Checkpoint({
          fromBlock: SafeCast.toUint32(block.number),
          deposits: SafeCast.toUint224(newWeight)
        })
      );
    }
  }
  function _additionFn(uint256 a, uint256 b) private pure returns (uint256) {
    return a + b;
  }

  function _subtractionFn(uint256 a, uint256 b) private pure returns (uint256) {
    return a - b;
  }
  //===========================================================================
  // END: Checkpointing code.
  //===========================================================================
  // forgefmt: disable-end
}

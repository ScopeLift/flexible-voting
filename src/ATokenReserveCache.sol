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
import {Checkpoints} from "openzeppelin-contracts/contracts/utils/Checkpoints.sol";

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

contract ATokenReserveCache is AToken {
  using WadRayMath for uint256;
  using SafeCast for uint256;
  using GPv2SafeERC20 for IERC20;
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

  /// @notice The number of blocks prior to the proposal deadline within which
  /// `castVote` may be called. Prior to this window, `castVote` will revert so
  /// as to give users time to call `expressVote` before votes are sent to the
  /// governor contract.
  uint32 public immutable CAST_VOTE_WINDOW;

  /// @notice Map proposalId to an address to whether they have voted on this proposal.
  mapping(uint256 => mapping(address => bool)) private proposalVotersHasVoted;

  /// @notice Map proposalId to whether or not this contract has cast votes on it.
  mapping(uint256 => bool) public hasCastVotesOnProposal;

  /// @notice Map proposalId to vote totals expressed on this proposal.
  mapping(uint256 => ProposalVote) public proposalVotes;

  /// @notice The governor contract associated with this governance token. It
  /// must be one that supports fractional voting, e.g.
  /// GovernorCountingFractional.
  IFractionalGovernor public immutable governor;

  /// @notice Mapping from address to deposit checkpoint history.
  mapping(address => Checkpoints.History) private depositCheckpoints;

  /// @notice Mapping from address to stored (not rebased) balance checkpoint history.
  mapping(address => Checkpoints.History) private balanceCheckpoints;

  /// @notice History of total underlying asset balance.
  Checkpoints.History private totalDepositCheckpoints;

  /// @dev Constructor.
  /// @param _pool The address of the Pool contract
  /// @param _governor The address of the flex-voting-compatible governance contract.
  /// @param _castVoteWindow The number of blocks that users have to express
  /// their votes on a proposal before votes can be cast.
  constructor(IPool _pool, address _governor, uint32 _castVoteWindow) AToken(_pool) {
    governor = IFractionalGovernor(_governor);
    CAST_VOTE_WINDOW = _castVoteWindow;
  }

  // Get the rebased balance of a user at a given block number.
  function balanceOfAtBlock(
    address user,
    uint256 block
  ) public view returns(uint256) {
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
  /// deadline is exclusive, meaning: if this returns (say) block 424242, then the
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

  /// @notice Allow a depositor to express their voting preference for a given
  /// proposal. Their preference is recorded internally but not moved to the
  /// Governor until `castVote` is called. We deliberately do NOT revert if the
  /// internalVotingPeriodEnd has passed.
  /// @param proposalId The proposalId in the associated Governor
  /// @param support The depositor's vote preferences in accordance with the `VoteType` enum.
  function expressVote(uint256 proposalId, uint8 support) external {
    require(!hasCastVotesOnProposal[proposalId], "too late to express, votes already cast");
    uint256 weight = getPastDeposits(msg.sender, governor.proposalSnapshot(proposalId));
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
    require(
      _proposalVote.forVotes + _proposalVote.againstVotes + _proposalVote.abstainVotes > 0,
      "no votes expressed"
    );

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

    hasCastVotesOnProposal[proposalId] = true;
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
    // We increment by `amount` instead of any computed/rebased amounts because
    // `amount` is what actually gets transferred of the underlying asset. We
    // need our checkpoints to still match up with underlying asset transactions.
    Checkpoints.History storage _depositHistory = depositCheckpoints[onBehalfOf];
    _depositHistory.push(_depositHistory.latest() + amount);
    totalDepositCheckpoints.push(totalDepositCheckpoints.latest() + amount);

    bool _mintScaledReturn = _mintScaled(caller, onBehalfOf, amount, index);
    _checkpointRawBalanceOf(onBehalfOf);
    return _mintScaledReturn;
  }

  function _checkpointRawBalanceOf(address _user) internal {
    balanceCheckpoints[_user].push(_userState[_user].balance);
  }

  // Returns the raw (i.e. unrebased) balanceOf the _user at the _blockNumber.
  function getPastStoredBalance(address _user, uint256 _blockNumber) public returns (uint256) {
    return balanceCheckpoints[_user].getAtBlock(_blockNumber);
  }

  function getPastDeposits(address _voter, uint256 _blockNumber) public returns (uint256) {
    return depositCheckpoints[_voter].getAtBlock(_blockNumber);
  }

  function getPastTotalDeposits(uint256 _blockNumber) public returns (uint256) {
    return totalDepositCheckpoints.getAtBlock(_blockNumber);
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
    // need our checkpoints to still match up with underlying asset transactions.
    Checkpoints.History storage _depositHistory = depositCheckpoints[from];
    _depositHistory.push(_depositHistory.latest() - amount);
    totalDepositCheckpoints.push(totalDepositCheckpoints.latest() - amount);

    // End modifications.
    _burnScaled(from, receiverOfUnderlying, amount, index);
    if (receiverOfUnderlying != address(this)) {
      IERC20(_underlyingAsset).safeTransfer(receiverOfUnderlying, amount);
    }
  }
  //===========================================================================
  // END: Aave overrides
  //===========================================================================
  // forgefmt: disable-end
}

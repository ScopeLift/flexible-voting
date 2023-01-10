// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.10;

// forgefmt: disable-start
import {AToken} from "aave-v3-core/contracts/protocol/tokenization/AToken.sol";
import {MintableIncentivizedERC20} from "aave-v3-core/contracts/protocol/tokenization/base/MintableIncentivizedERC20.sol";
import {Errors} from "aave-v3-core/contracts/protocol/libraries/helpers/Errors.sol";
import {GPv2SafeERC20} from "aave-v3-core/contracts/dependencies/gnosis/contracts/GPv2SafeERC20.sol";
import {IAToken} from "aave-v3-core/contracts/interfaces/IAToken.sol";
import {IAaveIncentivesController} from "aave-v3-core/contracts/interfaces/IAaveIncentivesController.sol";
import {IPool} from "aave-v3-core/contracts/interfaces/IPool.sol";
import {SafeCast} from "openzeppelin-contracts/contracts/utils/math/SafeCast.sol";
import {Checkpoints} from "openzeppelin-contracts/contracts/utils/Checkpoints.sol";
import {IFractionalGovernor} from "src/interfaces/IFractionalGovernor.sol";
import {IVotingToken} from "src/interfaces/IVotingToken.sol";
// forgefmt: disable-end

/// @notice This is an extension of Aave V3's AToken contract which makes it possible for AToken
/// holders to still vote on governance proposals. This way, holders of governance tokens do not
/// have to choose between earning yield on Aave and voting. They can do both.
///
/// AToken holders are able to call `expressVote` to signal their preference on open governance
/// proposals. When they do so, this extension records that preference with weight proportional to
/// the users's AToken balance at the proposal snapshot.
///
/// When the proposal deadline nears, the AToken's public `castVote` function is called to roll up
/// all internal voting records into a single delegated vote to the Governor contract -- a vote
/// which specifies the exact For/Abstain/Against totals expressed by AToken holders.
///
/// This extension has the following requirements:
///   (a) the underlying token be a governance token
///   (b) the related governor contract supports flexible voting (see GovernorCountingFractional)
///
/// Participating in governance via AToken voting is completely optional. Users otherwise still
/// supply, borrow, and hold tokens with Aave as usual.
///
/// The original AToken that this contract extends is viewable here:
///
///   https://github.com/aave/aave-v3-core/blob/c38c6276/contracts/protocol/tokenization/AToken.sol
contract ATokenFlexVoting is AToken {
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
  /// must be one that supports fractional voting, e.g. GovernorCountingFractional.
  IFractionalGovernor public immutable GOVERNOR;

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
    GOVERNOR = IFractionalGovernor(_governor);
    CAST_VOTE_WINDOW = _castVoteWindow;
  }

  // forgefmt: disable-start
  //===========================================================================
  // BEGIN: Aave overrides
  //===========================================================================
  /// Note: this has been modified from Aave v3's AToken to delegate voting
  /// power to itself during initialization.
  ///
  /// @inheritdoc AToken
  function initialize(
    IPool initializingPool,
    address treasury,
    address underlyingAsset,
    IAaveIncentivesController incentivesController,
    uint8 aTokenDecimals,
    string calldata aTokenName,
    string calldata aTokenSymbol,
    bytes calldata params
  ) public override initializer {
    AToken.initialize(
      initializingPool,
      treasury,
      underlyingAsset,
      incentivesController,
      aTokenDecimals,
      aTokenName,
      aTokenSymbol,
      params
    );

    selfDelegate();
  }

  /// Note: this has been modified from Aave v3's MintableIncentivizedERC20 to
  /// checkpoint raw balances accordingly.
  ///
  /// @inheritdoc MintableIncentivizedERC20
  function _burn(address account, uint128 amount) internal override {
    MintableIncentivizedERC20._burn(account, amount);
    _checkpointRawBalanceOf(account);
    totalDepositCheckpoints.push(totalDepositCheckpoints.latest() - amount);
  }

  /// Note: this has been modified from Aave v3's MintableIncentivizedERC20 to
  /// checkpoint raw balances accordingly.
  ///
  /// @inheritdoc MintableIncentivizedERC20
  function _mint(address account, uint128 amount) internal override {
    MintableIncentivizedERC20._mint(account, amount);
    _checkpointRawBalanceOf(account);
    totalDepositCheckpoints.push(totalDepositCheckpoints.latest() + amount);
  }

  /// @dev This has been modified from Aave v3's AToken contract to checkpoint raw balances
  /// accordingly.  Ideally we would have overriden `IncentivizedERC20._transfer` instead of
  /// `AToken._transfer` as we did for `_mint` and `_burn`, but that isn't possible here:
  /// `AToken._transfer` *already is* an override of `IncentivizedERC20._transfer`
  ///
  /// @inheritdoc AToken
  function _transfer(
    address from,
    address to,
    uint256 amount,
    bool validate
  ) internal virtual override {
    AToken._transfer(from, to, amount, validate);
    _checkpointRawBalanceOf(from);
    _checkpointRawBalanceOf(to);
  }
  //===========================================================================
  // END: Aave overrides
  //===========================================================================
  // forgefmt: disable-end

  // Self-delegation cannot be done in the constructor because the aToken is
  // just a proxy -- it won't share an address with the implementation (i.e.
  // this code). Instead we do it at the end of `initialize`. But even that won't
  // handle already-initialized aTokens. For those, we'll need to self-delegate
  // during the upgrade process. More details in these issues:
  // https://github.com/aave/aave-v3-core/pull/774
  // https://github.com/ScopeLift/flexible-voting/issues/16
  function selfDelegate() public {
    IVotingToken(GOVERNOR.token()).delegate(address(this));
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
    _lastVotingBlock = GOVERNOR.proposalDeadline(proposalId) - CAST_VOTE_WINDOW;
  }

  /// @notice Allow a depositor to express their voting preference for a given
  /// proposal. Their preference is recorded internally but not moved to the
  /// Governor until `castVote` is called. We deliberately do NOT revert if the
  /// internalVotingPeriodEnd has passed.
  /// @param proposalId The proposalId in the associated Governor
  /// @param support The depositor's vote preferences in accordance with the `VoteType` enum.
  function expressVote(uint256 proposalId, uint8 support) external {
    require(!hasCastVotesOnProposal[proposalId], "too late to express, votes already cast");
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

    uint256 _proposalSnapshotBlockNumber = GOVERNOR.proposalSnapshot(proposalId);

    // Use the snapshot of total raw balances to determine total voting weight.
    // We cannot use the proposalVote numbers alone, since some people with
    // balances at the snapshot might not have expressed votes. We don't want to
    // make it possible for aToken holders to *increase* their voting power when
    // other people don't express their votes. That'd be a terrible incentive.
    uint256 _totalRawBalanceAtSnapshot = getPastTotalBalance(_proposalSnapshotBlockNumber);

    // We need 256 bits because of the multiplication we're about to do.
    uint256 _votingWeightAtSnapshot = IVotingToken(address(_underlyingAsset)).getPastVotes(
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

    hasCastVotesOnProposal[proposalId] = true;
    bytes memory fractionalizedVotes =
      abi.encodePacked(_forVotesToCast, _againstVotesToCast, _abstainVotesToCast);
    GOVERNOR.castVoteWithReasonAndParams(
      proposalId,
      unusedSupportParam,
      "rolled-up vote from aToken holders", // Reason string.
      fractionalizedVotes
    );
  }

  /// @notice Returns the _user's current balance in storage.
  function _rawBalanceOf(address _user) internal view returns (uint256) {
    return _userState[_user].balance;
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

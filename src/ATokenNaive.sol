// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8.10;

import { AToken } from "aave-v3-core/contracts/protocol/tokenization/AToken.sol";
import { Errors } from 'aave-v3-core/contracts/protocol/libraries/helpers/Errors.sol';
import { IAToken } from 'aave-v3-core/contracts/interfaces/IAToken.sol';
import { IPool } from 'aave-v3-core/contracts/interfaces/IPool.sol';
import { WadRayMath } from 'aave-v3-core/contracts/protocol/libraries/math/WadRayMath.sol';
import { SafeCast } from "openzeppelin-contracts/contracts/utils/math/SafeCast.sol";
import { Math } from "openzeppelin-contracts/contracts/utils/math/Math.sol";

contract ATokenNaive is AToken {
  using WadRayMath for uint256;
  using SafeCast for uint256;

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

  /// @notice Must call castVote within this many blocks of the proposal
  /// deadline, so-as to allow ample time for all depositors to express their
  /// vote preferences. Corresponds to roughly 4 hours, assuming 12s/block.
  uint32 constant public CAST_VOTE_WINDOW = 1_200;

  /// @notice Map depositor to deposit amount.
  mapping (address => uint256) public deposits;

  /// @notice Map borrower to total amount borrowed.
  mapping (address => uint256) public borrowTotal;

  /// @notice Map proposalId to an address to whether they have voted on this proposal.
  mapping(uint256 => mapping(address => bool)) private _proposalVotersHasVoted;

  /// @notice Map proposalId to vote totals expressed on this proposal.
  mapping(uint256 => ProposalVote) public proposalVotes;

  /// @dev Constructor.
  /// @param pool The address of the Pool contract
  constructor(IPool pool) AToken(pool) {
    // Intentionally left blank in favor of the initializer function.
  }

  /// @inheritdoc IAToken
  function mint(
    address caller,
    address onBehalfOf,
    uint256 amount,
    uint256 index
  ) external virtual override onlyPool returns (bool) {
    return __mintScaled(caller, onBehalfOf, amount, index);
  }

  // TODO Uncomment when we figure out the simplest way to override this
  // non-virtual function.
  //
  // /// @inheritdoc IAToken
  // function mintToTreasury(uint256 amount, uint256 index) external override onlyPool {
  //   if (amount == 0) {
  //     return;
  //   }
  //   _mintScaled(address(POOL), _treasury, amount, index);
  // }

  /// Note: this has been modified from Aave v3's ScaledBalanceTokenBase
  /// contract to include balance checkpointing code.
  /// https://github.com/aave/aave-v3-core/blob/f3e037b3638e3b7c98f0c09c56c5efde54f7c5d2/contracts/protocol/tokenization/base/ScaledBalanceTokenBase.sol#L61-L91
  /// Modifications are as indicated below.
  ///
  /// @notice Implements the basic logic to mint a scaled balance token.
  /// @param caller The address performing the mint
  /// @param onBehalfOf The address of the user that will receive the scaled tokens
  /// @param amount The amount of tokens getting minted
  /// @param index The next liquidity index of the reserve
  /// @return `true` if the the previous balance of the user was 0
  function __mintScaled(
    address caller,
    address onBehalfOf,
    uint256 amount,
    uint256 index
  ) internal returns (bool) {
    uint256 amountScaled = amount.rayDiv(index);
    require(amountScaled != 0, Errors.INVALID_MINT_AMOUNT);

    uint256 scaledBalance = super.balanceOf(onBehalfOf);
    uint256 balanceIncrease = scaledBalance.rayMul(index) -
      scaledBalance.rayMul(_userState[onBehalfOf].additionalData);

    _userState[onBehalfOf].additionalData = index.toUint128();

    _mint(onBehalfOf, amountScaled.toUint128());

    // Begin modifications.
    deposits[onBehalfOf] += amountScaled;
    _writeCheckpoint(_checkpoints[onBehalfOf], _additionFn, amountScaled);
    _writeCheckpoint(_totalDepositCheckpoints, _additionFn, amountScaled);
    // End modifications.

    uint256 amountToMint = amount + balanceIncrease;
    emit Transfer(address(0), onBehalfOf, amountToMint);
    emit Mint(caller, onBehalfOf, amountToMint, balanceIncrease, index);

    return (scaledBalance == 0);
  }

  //===========================================================================
  // BEGIN: Checkpointing code.
  //===========================================================================
  // This was been copied from OZ's ERC20Votes checkpointing system with minor
  // revisions:
  //   * Replace "Vote" with "Deposit", as deposits are what we need to track
  //   * Make some variable names longer for readibility
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
}

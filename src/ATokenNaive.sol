// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8.10;

import { AToken } from "aave-v3-core/contracts/protocol/tokenization/AToken.sol";
import { IPool } from 'aave-v3-core/contracts/interfaces/IPool.sol';

contract ATokenNaive is AToken {

  /// @inheritdoc AToken
  constructor(IPool pool) AToken(pool) {
    // Intentionally left blank in favor of the initializer function.
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

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {Context} from "@openzeppelin/contracts/utils/Context.sol";
import {Checkpoints} from "@openzeppelin/contracts/utils/structs/Checkpoints.sol";

import {IVotingToken} from "src/interfaces/IVotingToken.sol";
import {FlexVotingClient} from "src/FlexVotingClient.sol";

abstract contract FlexVotingDelegatable is Context, FlexVotingClient {
  using Checkpoints for Checkpoints.Trace208;

  // @dev Emitted when an account changes its delegate.
  event DelegateChanged(
    address indexed delegator, address indexed fromDelegate, address indexed toDelegate
  );

  // @dev Emitted when a delegate change results in changes to a delegate's
  // number of voting weight.
  event DelegateWeightChanged(address indexed delegate, uint256 previousVotes, uint256 newVotes);

  mapping(address account => address) private _delegatee;

  // @dev Delegates votes from the sender to `delegatee`.
  function delegate(address delegatee) public virtual {
    address account = _msgSender();
    _delegate(account, delegatee);
  }

  // @dev Returns the delegate that `account` has chosen. Assumes
  // self-delegation if no delegate has been chosen.
  function delegates(address _account) public view virtual returns (address) {
    address _proxy = _delegatee[_account];
    if (_proxy == address(0)) return _account;
    return _proxy;
  }

  // @dev Delegate all of `account`'s voting units to `delegatee`.
  //
  // Emits events {DelegateChanged} and {DelegateWeightChanged}.
  function _delegate(address account, address delegatee) internal virtual {
    address oldDelegate = delegates(account);
    _delegatee[account] = delegatee;

    int256 _delta = int256(uint256(_rawBalanceOf(account)));
    emit DelegateChanged(account, oldDelegate, delegatee);
    _updateDelegateBalance(oldDelegate, delegatee, _delta);
  }

  function _checkpointVoteWeightOf(
    address _user,
    int256 _delta
  ) internal virtual override {
    address _proxy = delegates(_user);
    _applyDeltaToCheckpoint(voteWeightCheckpoints[_proxy], _delta);
  }

  // @dev Moves delegated votes from one delegate to another.
  function _updateDelegateBalance(address from, address to, int256 _delta) internal virtual {
    if (from == to || _delta == 0) return;

    // Decrement old delegate's weight.
    (uint208 _oldFrom, uint208 _newFrom) =
      _applyDeltaToCheckpoint(voteWeightCheckpoints[from], -_delta);
    emit DelegateWeightChanged(from, _oldFrom, _newFrom);

    // Increment new delegate's weight.
    (uint208 _oldTo, uint208 _newTo) =
      _applyDeltaToCheckpoint(voteWeightCheckpoints[to], _delta);
    emit DelegateWeightChanged(to, _oldTo, _newTo);
  }
}

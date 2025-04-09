// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {Context} from "@openzeppelin/contracts/utils/Context.sol";
import {Checkpoints} from "@openzeppelin/contracts/utils/structs/Checkpoints.sol";

import {IFractionalGovernor} from "src/interfaces/IFractionalGovernor.sol";
import {FlexVotingBase} from "src/FlexVotingBase.sol";

/// @notice This is an abstract contract designed to make it easy to build
/// clients for governance systems that inherit from GovernorCountingFractional,
/// a.k.a. Flexible Voting governors.
///
/// This contract extends FlexVotingBase, adding the ability to subdelegate one's
/// internal voting weight. It is meant to be inherited from in conjunction with
/// FlexVotingClient. Doing so makes the following usecase possible:
///   - user A deposits 100 governance tokens in a FlexVotingClient
///   - user B deposits 50 governance tokens into the same client
///   - user A delegates voting weight to user B
///   - a proposal is created in the Governor contract
///   - user B expresses a voting preference P on the proposal to the client
///   - the client casts its votes on the proposal to the Governor contract
///   - user B's voting weight is combined with user A's voting weight so that
///     150 tokens are effectively cast with voting preference P on behalf of
///     users A and B.
abstract contract FlexVotingDelegable is Context, FlexVotingBase {
  using Checkpoints for Checkpoints.Trace208;

  // @dev Emitted when an account changes its delegate.
  event DelegateChanged(
    address indexed governor,
    address indexed delegator,
    address indexed toDelegate,
    address fromDelegate
  );

  // @dev Emitted when a delegate change results in changes to a delegate's
  // number of voting weight.
  event DelegateWeightChanged(
    address indexed governor, address indexed delegate, uint256 previousVotes, uint256 newVotes
  );

  mapping(IFractionalGovernor => mapping(address account => address)) private _delegatee;

  // @dev Delegates `_governor` votes from the sender to `_proxy`.
  function delegate(IFractionalGovernor _governor, address _proxy) public virtual {
    _checkGovernor(_governor);
    address _account = _msgSender();
    _delegate(_governor, _account, _proxy);
  }

  // @dev Returns the delegate that `_account` has chosen for `_governor`. Assumes
  // self-delegation if no delegate has been set.
  function delegates(IFractionalGovernor _governor, address _account)
    public
    view
    virtual
    returns (address)
  {
    address _proxy = _delegatee[_governor][_account];
    if (_proxy == address(0)) return _account;
    return _proxy;
  }

  // @dev Delegate all of `account`'s voting units with `governor` to `delegatee`.
  //
  // Emits events {DelegateChanged} and {DelegateWeightChanged}.
  function _delegate(IFractionalGovernor _governor, address _account, address _proxy)
    internal
    virtual
  {
    address oldDelegate = delegates(_governor, _account);
    _delegatee[_governor][_account] = _proxy;

    int256 _delta = int256(uint256(_rawBalanceOf(_governor, _account)));
    emit DelegateChanged(address(_governor), _account, oldDelegate, _proxy);
    _updateDelegateBalance(_governor, oldDelegate, _proxy, _delta);
  }

  function _checkpointVoteWeightOf(IFractionalGovernor _governor, address _user, int256 _delta)
    internal
    virtual
    override
  {
    address _proxy = delegates(_governor, _user);
    _applyDeltaToCheckpoint(_governor, voteWeightCheckpoints[_governor][_proxy], _delta);
  }

  // @dev Moves delegated votes from one delegate to another.
  function _updateDelegateBalance(
    IFractionalGovernor _governor,
    address _from,
    address _to,
    int256 _delta
  ) internal virtual {
    if (_from == _to || _delta == 0) return;

    // Decrement old delegate's weight.
    (uint208 _oldFrom, uint208 _newFrom) =
      _applyDeltaToCheckpoint(_governor, voteWeightCheckpoints[_governor][_from], -_delta);
    emit DelegateWeightChanged(address(_governor), _from, _oldFrom, _newFrom);

    // Increment new delegate's weight.
    (uint208 _oldTo, uint208 _newTo) =
      _applyDeltaToCheckpoint(_governor, voteWeightCheckpoints[_governor][_to], _delta);
    emit DelegateWeightChanged(address(_governor), _to, _oldTo, _newTo);
  }
}

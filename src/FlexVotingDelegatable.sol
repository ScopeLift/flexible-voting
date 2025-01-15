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
    event DelegateChanged(address indexed delegator, address indexed fromDelegate, address indexed toDelegate);

    // @dev Emitted when a delegate change results in changes to a delegate's
    // number of voting weight.
    event DelegateWeightChanged(address indexed delegate, uint256 previousVotes, uint256 newVotes);

    mapping(address account => address) private _delegatee;

    function expressVote(uint256 proposalId, uint8 support) external override virtual {
      address voter = _msgSender();
      uint256 weight = FlexVotingClient.getPastRawBalance(voter, GOVERNOR.proposalSnapshot(proposalId));
      _expressVote(voter, proposalId, support, weight);
    }

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

        emit DelegateChanged(account, oldDelegate, delegatee);
        _updateDelegateBalance(oldDelegate, delegatee, _rawBalanceOf(account));
    }

    // @dev Moves delegated votes from one delegate to another.
    function _updateDelegateBalance(address from, address to, uint208 amount) internal virtual {
      if (from == to || amount == 0) return;

      if (from != address(0)) {
        (uint256 oldValue, uint256 newValue) = _push(
          FlexVotingClient.balanceCheckpoints[from],
          _subtract,
          amount
        );
        emit DelegateWeightChanged(from, oldValue, newValue);
      }
      if (to != address(0)) {
        (uint256 oldValue, uint256 newValue) = _push(
          FlexVotingClient.balanceCheckpoints[to],
          _add,
          amount
        );
        emit DelegateWeightChanged(to, oldValue, newValue);
      }
    }

    function _push(
      Checkpoints.Trace208 storage store,
      function(uint208, uint208) view returns (uint208) fn,
      uint208 delta
    ) private returns (uint208 oldValue, uint208 newValue) {
      return store.push(
        IVotingToken(GOVERNOR.token()).clock(),
        fn(store.latest(), delta)
      );
    }

    function _add(uint208 a, uint208 b) private pure returns (uint208) {
      return a + b;
    }

    function _subtract(uint208 a, uint208 b) private pure returns (uint208) {
      return a - b;
    }
}

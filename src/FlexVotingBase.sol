// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {Checkpoints} from "@openzeppelin/contracts/utils/structs/Checkpoints.sol";
import {IFractionalGovernor} from "src/interfaces/IFractionalGovernor.sol";
import {IVotingToken} from "src/interfaces/IVotingToken.sol";

/// TODO this needs to be updated since the abstraction changed.
/// @notice This is an abstract contract designed to make it easy to build
/// clients for governance systems that inherit from GovernorCountingFractional,
/// a.k.a. Flexible Voting governors.
///
/// A "client" in this sense is a contract that:

/// - (a) receives deposits of governance tokens from its users,
/// - (b) gives said depositors the ability to express their voting preferences
///   on governance proposals, and
/// - (c) casts votes on said proposals to flexible voting governors according
///   to the expressed preferences of its depositors.
///
/// This contract assumes that a child contract will implement a mechanism for
/// receiving and storing deposit balances, part (a). With that in place, this
/// contract supplies features (b) and (c).
///
/// A key concept here is that of a user's "raw balance". The raw balance is the
/// system's internal representation of a user's claim on the governance tokens
/// that it custodies. Since different systems might represent such claims in
/// different ways, this contract leaves the implementation of the `_rawBalance`
/// function to the child contract.
///
/// The simplest such representation would be to directly store the cumulative
/// balance of the governance token that the user has deposited. In such a
/// system, the amount that the user deposits is the amount that the user has
/// claim to. If the user has claim to 1e18 governance tokens, the internal
/// representation is just 1e18.
///
/// In many systems, however, the raw balance will not be equivalent to the
/// amount of governance tokens the user has claim to. In Aave, for example,
/// deposit amounts are scaled down by an ever-increasing index that represents
/// the cumulative amount of interest earned over the lifetime of deposits. The
/// "raw balance" of a user in Aave's case is this scaled down amount, since it
/// is the value that represents the user's claim on deposits. Thus for Aave, a
/// users's raw balance will always be less than the actual amount they have
/// claim to.
///
/// If the raw balance can be identified and defined for a system, and
/// `_rawBalance` can be implemented for it, then this contract will take care
/// of the rest.
abstract contract FlexVotingBase {
  using SafeCast for uint256;

  // @dev Trace208 is used instead of Trace224 because the former allocates 48
  // bits to its _key. We need at least 48 bits because the _key is going to be
  // a timepoint. Timepoints in the context of ERC20Votes and ERC721Votes
  // conform to the EIP-6372 standard, which specifies they be uint48s.
  using Checkpoints for Checkpoints.Trace208;

  /// @dev Mapping from voting token address to a mapping from user (i.e. address)
  /// to the checkpoint history of internal voting weight for that address, i.e.
  /// how much weight they can call `expressVote` with at a given time.
  ///
  /// To get the vote weight for a user at timepoint t use:
  ///   voteWeightCheckpoints[token][user].upperLookup(t)
  mapping(
    IVotingToken token => mapping(
      address user => Checkpoints.Trace208 votingWeight
    )
  ) internal voteWeightCheckpoints;

  /// @dev Mapping from token address to the checkpoint history of the sum total
  /// of voting weight in token held by this contract. May or may not be
  /// equivalent to this contract's balance of token at a given time.
  mapping(IVotingToken token => Checkpoints.Trace208 totalWeight) internal totalVoteWeightCheckpoints;

  /// @dev Returns a representation of the current amount of `_token` that
  /// `_user` has claim to in this system. It may or may not be equivalent to
  /// the withdrawable balance of `_token` for `user`, e.g. if the
  /// internal representation of balance has been scaled down. This is indexed
  /// by `_token` and not Governor because it's much more natural to ask for the
  /// raw balance of a token than the raw balance of a governor.
  function _rawBalanceOf(IVotingToken _token, address _user)
    internal
    view
    virtual
    returns (uint208);

  // TODO Should we rename this function to avoid collision with FlexVotingDelegable?
  // https://github.com/ScopeLift/flexible-voting/issues/88
  /// @dev Delegates the `_token` voting rights to itself.
  function _selfDelegate(IVotingToken _token) internal {
    _token.delegate(address(this));
  }

  function _applyDeltaToCheckpoint(
    IVotingToken _token,
    Checkpoints.Trace208 storage _checkpoint,
    int256 _delta
  ) internal returns (uint208 _prevTotal, uint208 _newTotal) {
    // The casting in this function is safe since:
    // - if oldTotal + delta > int256.max it will panic and revert.
    // - if |delta| <= oldTotal there is no risk of wrapping
    // - if |delta| > oldTotal
    //   * uint256(oldTotal + delta) will wrap but the wrapped value will
    //     necessarily be greater than uint208.max, so SafeCast will revert.
    //   * the lowest that oldTotal + delta can be is int256.min (when
    //     oldTotal is 0 and delta is int256.min). The wrapped value of a
    //     negative signed integer is:
    //       wrapped(integer) = uint256.max + integer
    //     Substituting:
    //       wrapped(int256.min) = uint256.max + int256.min
    //     But:
    //       uint256.max + int256.min > uint208.max
    //     Substituting again:
    //       wrapped(int256.min) > uint208.max, which will revert when safecast.
    _prevTotal = _checkpoint.latest();
    int256 _castTotal = int256(uint256(_prevTotal));
    _newTotal = SafeCast.toUint208(uint256(_castTotal + _delta));

    uint48 _timepoint = _token.clock();
    _checkpoint.push(_timepoint, _newTotal);
  }

  /// @dev Checkpoints voting weight of `user` with `governor`s token after applying `_delta`.
  function _checkpointVoteWeightOf(IVotingToken _token, address _user, int256 _delta)
    internal
    virtual
  {
    _applyDeltaToCheckpoint(_token, voteWeightCheckpoints[_token][_user], _delta);
  }

  /// @dev Checkpoints this contract's total vote weight with `governor` after applying `_delta`.
  function _checkpointTotalVoteWeight(IVotingToken _token, int256 _delta)
    internal
    virtual
  {
    _applyDeltaToCheckpoint(_token, totalVoteWeightCheckpoints[_token], _delta);
  }
}

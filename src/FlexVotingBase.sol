// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {Checkpoints} from "@openzeppelin/contracts/utils/structs/Checkpoints.sol";
import {IFractionalGovernor} from "src/interfaces/IFractionalGovernor.sol";
import {IVotingToken} from "src/interfaces/IVotingToken.sol";

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

  /// @notice The governor contract associated with this governance token. It
  /// must be one that supports fractional voting, e.g. GovernorCountingFractional.
  IFractionalGovernor public immutable GOVERNOR;

  /// @dev Mapping from address to the checkpoint history of internal voting
  /// weight for that address, i.e. how much weight they can call `expressVote`
  /// with at a given time.
  mapping(address => Checkpoints.Trace208) internal voteWeightCheckpoints;

  /// @dev History of the sum total of voting weight in the system. May or may
  /// not be equivalent to this contract's balance of `GOVERNOR`s token at a
  /// given time.
  Checkpoints.Trace208 internal totalVoteWeightCheckpoints;

  /// @param _governor The address of the flex-voting-compatible governance contract.
  constructor(address _governor) {
    GOVERNOR = IFractionalGovernor(_governor);
  }

  /// @dev Returns a representation of the current amount of `GOVERNOR`s
  /// token that `_user` has claim to in this system. It may or may not be
  /// equivalent to the withdrawable balance of `GOVERNOR`s token for `user`,
  /// e.g. if the internal representation of balance has been scaled down.
  function _rawBalanceOf(address _user) internal view virtual returns (uint208);

  // TODO rename to avoid collision with FlexVotingDelegatable.
  /// @dev Delegates the present contract's voting rights with `GOVERNOR` to itself.
  function _selfDelegate() internal {
    IVotingToken(GOVERNOR.token()).delegate(address(this));
  }

  function _applyDeltaToCheckpoint(
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

    uint48 _timepoint = IVotingToken(GOVERNOR.token()).clock();
    _checkpoint.push(_timepoint, _newTotal);
  }

  /// @dev Checkpoints internal voting weight of `user` after applying `_delta`.
  function _checkpointVoteWeightOf(
    address _user,
    int256 _delta
  ) internal virtual {
    _applyDeltaToCheckpoint(voteWeightCheckpoints[_user], _delta);
  }

  /// @dev Checkpoints the total vote weight after applying `_delta`.
  function _checkpointTotalVoteWeight(int256 _delta) internal virtual {
    _applyDeltaToCheckpoint(totalVoteWeightCheckpoints, _delta);
  }
}

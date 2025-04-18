// SPDX-License-Identifier: MIT
pragma solidity >=0.8.10;

import {Checkpoints} from "@openzeppelin/contracts/utils/structs/Checkpoints.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20Votes} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Votes.sol";
import {GovToken} from "test/mocks/GovToken.sol";
import {IVotingToken} from "src/interfaces/IVotingToken.sol";
import {FlexVotingBase} from "src/FlexVotingBase.sol";
import {FlexVotingClient} from "src/FlexVotingClient.sol";
import {IFractionalGovernor} from "src/interfaces/IFractionalGovernor.sol";
import {IVotingToken} from "src/interfaces/IVotingToken.sol";

contract MockFlexVotingClient is FlexVotingClient {
  using Checkpoints for Checkpoints.Trace208;

  /// @notice The principle governor contract associated with this pool.
  IFractionalGovernor public immutable GOVERNOR;

  /// @notice The principle governance token held and lent by this pool.
  IVotingToken public immutable TOKEN;

  /// @notice Map token to address to that address' deposit amount of that token.
  mapping(IVotingToken => mapping(address => uint208)) public _deposits;

  /// @notice Map borrower to total amount borrowed of token.
  mapping(IVotingToken => mapping(address => uint256)) public _borrowTotal;

  constructor(address _governor) {
    GOVERNOR = IFractionalGovernor(_governor);
    TOKEN = IVotingToken(GOVERNOR.token());
    _selfDelegate(TOKEN);
  }

  function _rawBalanceOf(IVotingToken _token, address _user)
    internal
    view
    override
    returns (uint208)
  {
    return _deposits[_token][_user];
  }

  // Test hooks
  // ---------------------------------------------------------------------------
  function expressVote(uint256 proposalId, uint8 support) external {
    _expressVote(GOVERNOR, proposalId, support);
  }

  function castVote(uint256 proposalId) external {
    _castVote(GOVERNOR, proposalId);
  }

  function deposit(uint208 _amount) public {
    deposit(TOKEN, _amount);
  }

  function withdraw(uint208 _amount) public {
    withdraw(TOKEN, _amount);
  }

  function borrow(uint256 _amount) public {
    borrow(TOKEN, _amount);
  }

  function deposits(IVotingToken _token, address _user) external view returns (uint208) {
    return _deposits[_token][_user];
  }

  function deposits(address _user) external view returns (uint208) {
    return _deposits[TOKEN][_user];
  }

  function getPastVoteWeight(address _user, uint256 _timepoint) public view returns (uint256) {
    return getPastVoteWeight(TOKEN, _user, _timepoint);
  }

  function getPastTotalVoteWeight(uint256 _timepoint) public view returns (uint256) {
    return getPastTotalVoteWeight(TOKEN, _timepoint);
  }

  function exposed_rawBalanceOf(GovToken _token, address _user) external view returns (uint208) {
    return _rawBalanceOf(IVotingToken(address(_token)), _user);
  }

  function exposed_latestTotalWeight() external view returns (uint208) {
    return totalVoteWeightCheckpoints[TOKEN].latest();
  }

  function exposed_checkpointTotalVoteWeight(int256 _delta) external {
    return _checkpointTotalVoteWeight(TOKEN, _delta);
  }

  function exposed_castVoteReasonString() external returns (string memory) {
    return _castVoteReasonString(GOVERNOR);
  }

  function exposed_selfDelegate() external {
    return _selfDelegate(TOKEN);
  }

  function exposed_setDeposits(address _user, uint208 _amount) external {
    _deposits[TOKEN][_user] = _amount;
  }

  function exposed_checkpointVoteWeightOf(address _user, int256 _delta) external {
    _checkpointVoteWeightOf(TOKEN, _user, _delta);
  }
  // End test hooks
  // ---------------------------------------------------------------------------

  /// @notice Allow a holder of the governance token to deposit it into the pool.
  /// @param _token The token that will be deposited.
  /// @param _amount The amount to be deposited.
  function deposit(IVotingToken _token, uint208 _amount) public {
    _deposits[_token][msg.sender] += _amount;

    int256 _delta = int256(uint256(_amount));
    _checkpointVoteWeightOf(_token, msg.sender, _delta);
    _checkpointTotalVoteWeight(_token, _delta);

    // Assumes revert on failure.
    _token.transferFrom(msg.sender, address(this), _amount);
  }

  /// @notice Allow a depositor to withdraw funds previously deposited to the pool.
  /// @param _amount The amount to be withdrawn.
  function withdraw(IVotingToken _token, uint208 _amount) public {
    // Overflows & reverts if user does not have sufficient deposits.
    _deposits[_token][msg.sender] -= _amount;

    int256 _delta = -1 * int256(uint256(_amount));
    _checkpointVoteWeightOf(_token, msg.sender, _delta);
    _checkpointTotalVoteWeight(_token, _delta);

    _token.transfer(msg.sender, _amount); // Assumes revert on failure.
  }

  /// @notice Arbitrarily remove tokens from the pool. This is to simulate a
  /// borrower, hence the method name. Since this is just a mock, nothing else
  /// is actually done here (e.g. normally you'd want to limit borrows based
  /// on deposited collateral).
  /// @param _token The token that will be borrowed.
  /// @param _amount The amount to "borrow."
  function borrow(IVotingToken _token, uint256 _amount) public {
    _borrowTotal[_token][msg.sender] += _amount;
    _token.transfer(msg.sender, _amount);
  }

  function borrowTotal(IVotingToken _token, address _user) public view returns (uint256) {
    return _borrowTotal[_token][_user];
  }

  function borrowTotal(address _user) public view returns (uint256) {
    return _borrowTotal[TOKEN][_user];
  }
}

// SPDX-License-Identifier: MIT
pragma solidity >=0.8.10;

import {Checkpoints} from "@openzeppelin/contracts/utils/structs/Checkpoints.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20Votes} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Votes.sol";
import {IVotingToken} from "src/interfaces/IVotingToken.sol";
import {FlexVotingBase} from "src/FlexVotingBase.sol";
import {FlexVotingClient} from "src/FlexVotingClient.sol";
import {IFractionalGovernor} from "src/interfaces/IFractionalGovernor.sol";

contract MockFlexVotingClient is FlexVotingClient {
  using Checkpoints for Checkpoints.Trace208;

  /// @notice The principle governor contract associated with this pool.
  IFractionalGovernor public immutable GOVERNOR;

  /// @notice The principle governance token held and lent by this pool.
  ERC20Votes public immutable TOKEN;

  /// @notice Map governor to address to deposit amount of that governor's token.
  mapping(IFractionalGovernor => mapping(address => uint208)) public _deposits;

  /// @notice Map borrower to total amount borrowed of governor's token.
  mapping(IFractionalGovernor => mapping(address => uint256)) public _borrowTotal;

  constructor(address _governor) {
    GOVERNOR = IFractionalGovernor(_governor);
    TOKEN = ERC20Votes(GOVERNOR.token());
    _selfDelegate(GOVERNOR);
  }

  function _rawBalanceOf(IFractionalGovernor _governor, address _user)
    internal
    view
    override
    returns (uint208)
  {
    return _deposits[_governor][_user];
  }

  // Test hooks
  // ---------------------------------------------------------------------------
  function expressVote(uint256 proposalId, uint8 support) external {
    _expressVote(GOVERNOR, proposalId, support);
  }

  function castVote(uint256 proposalId) external {
    _castVote(GOVERNOR, proposalId);
  }

  function deposits(IFractionalGovernor _governor, address _user) external view returns (uint208) {
    return _deposits[_governor][_user];
  }

  function deposits(address _user) external view returns (uint208) {
    return _deposits[GOVERNOR][_user];
  }

  function getPastVoteWeight(address _user, uint256 _timepoint) public view returns (uint256) {
    return getPastVoteWeight(GOVERNOR, _user, _timepoint);
  }

  function getPastTotalVoteWeight(uint256 _timepoint) public view returns (uint256) {
    return getPastTotalVoteWeight(GOVERNOR, _timepoint);
  }

  function exposed_rawBalanceOf(address _user) external view returns (uint208) {
    return _rawBalanceOf(GOVERNOR, _user);
  }

  function exposed_latestTotalWeight() external view returns (uint208) {
    return totalVoteWeightCheckpoints[GOVERNOR].latest();
  }

  function exposed_checkpointTotalVoteWeight(int256 _delta) external {
    return _checkpointTotalVoteWeight(GOVERNOR, _delta);
  }

  function exposed_castVoteReasonString() external returns (string memory) {
    return _castVoteReasonString(GOVERNOR);
  }

  function exposed_selfDelegate() external {
    return _selfDelegate(GOVERNOR);
  }

  function exposed_setDeposits(address _user, uint208 _amount) external {
    _deposits[GOVERNOR][_user] = _amount;
  }

  function exposed_checkpointVoteWeightOf(address _user, int256 _delta) external {
    _checkpointVoteWeightOf(GOVERNOR, _user, _delta);
  }
  // End test hooks
  // ---------------------------------------------------------------------------

  /// @notice Allow a holder of the governance token to deposit it into the pool.
  /// @param _amount The amount to be deposited.
  function deposit(uint208 _amount) public {
    _deposits[GOVERNOR][msg.sender] += _amount;

    int256 _delta = int256(uint256(_amount));
    _checkpointVoteWeightOf(GOVERNOR, msg.sender, _delta);
    _checkpointTotalVoteWeight(GOVERNOR, _delta);

    // Assumes revert on failure.
    TOKEN.transferFrom(msg.sender, address(this), _amount);
  }

  /// @notice Allow a depositor to withdraw funds previously deposited to the pool.
  /// @param _amount The amount to be withdrawn.
  function withdraw(uint208 _amount) public {
    // Overflows & reverts if user does not have sufficient deposits.
    _deposits[GOVERNOR][msg.sender] -= _amount;

    int256 _delta = -1 * int256(uint256(_amount));
    _checkpointVoteWeightOf(GOVERNOR, msg.sender, _delta);
    _checkpointTotalVoteWeight(GOVERNOR, _delta);

    TOKEN.transfer(msg.sender, _amount); // Assumes revert on failure.
  }

  /// @notice Arbitrarily remove tokens from the pool. This is to simulate a borrower, hence the
  /// method name. Since this is just a proof-of-concept, nothing else is actually done here.
  /// @param _amount The amount to "borrow."
  function borrow(uint256 _amount) public {
    _borrowTotal[GOVERNOR][msg.sender] += _amount;
    TOKEN.transfer(msg.sender, _amount);
  }

  function borrowTotal(IFractionalGovernor _governor, address _user) public view returns (uint256) {
    return _borrowTotal[_governor][_user];
  }

  function borrowTotal(address _user) public view returns (uint256) {
    return _borrowTotal[GOVERNOR][_user];
  }
}

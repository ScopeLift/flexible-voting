// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8.10;

import {Comet} from "comet/Comet.sol";
import {CometConfiguration} from "comet/CometConfiguration.sol";
import {Checkpoints} from "@openzeppelin/contracts/utils/Checkpoints.sol";

import {FlexVotingClient} from "src/FlexVotingClient.sol";

/// @notice This is an extension of Compound V3's Comet contract which makes it
/// possible for Comet token holders to still vote on governance proposals. This
/// way, holders of governance tokens do not have to choose between earning
/// yield on Compound and voting. They can do both.
///
/// This extension has the following requirements:
///   (a) The base token must be a governance token.
///   (b) The base token's governor contract must support flexible voting (see
///       `GovernorCountingFractional`).
///
/// If these requirements are met, base token depositors can call
/// `Comet.expressVote` to signal their preference on open governance proposals.
/// When they do so, this extension records that preference with weight
/// proportional to the users's Comet balance at the proposal snapshot.
///
/// At any point after voting preferences have been expressed, Comet's public
/// `castVote` function may be called to roll up all internal voting records
/// into a single delegated vote to the Governor contract -- a vote which
/// specifies the exact For/Abstain/Against totals expressed by Comet holders.
/// Votes can be rolled up and cast in this manner multiple times for a given
/// proposal.
///
/// Participating in governance via Comet voting is completely optional. Users
/// otherwise still supply, borrow, and hold tokens with Compound as usual.
///
/// The original Comet that this contract was developed against can be viewed
/// here:
///
///   https://github.com/compound-finance/comet/blob/3780c06b4eaa80a8c78e0ff770a7e8a1518db75e/contracts/Comet.sol
contract CometFlexVoting is Comet, FlexVotingClient {
  using Checkpoints for Checkpoints.History;

  /// @param _config The configuration struct for this Comet instance.
  /// @param _governor The address of the flex-voting-compatible governance contract.
  constructor(CometConfiguration.Configuration memory _config, address _governor)
    Comet(_config)
    FlexVotingClient(_governor)
  {
    _selfDelegate();
  }

  /// @notice Returns the current balance in storage for the `account`.
  function _rawBalanceOf(address account) internal view override returns (uint256) {
    int104 _principal = userBasic[account].principal;
    return _principal > 0 ? uint256(int256(_principal)) : 0;
  }

  function _castVoteReasonString() internal override returns (string memory) {
    return "rolled-up vote from CometFlexVoting token holders";
  }

  //===========================================================================
  // BEGIN: Comet overrides
  //===========================================================================
  //
  // This function is called any time the underlying balance is changed.
  function updateBasePrincipal(address _account, UserBasic memory _userBasic, int104 _principalNew)
    internal
    override
  {
    Comet.updateBasePrincipal(_account, _userBasic, _principalNew);
    FlexVotingClient._checkpointRawBalanceOf(_account);
    FlexVotingClient.totalBalanceCheckpoints.push(uint224(totalSupplyBase));
  }
  //===========================================================================
  // END: Comet overrides
  //===========================================================================
}

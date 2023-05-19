// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.10;

// forgefmt: disable-start
import {AToken} from "aave-v3-core/contracts/protocol/tokenization/AToken.sol";
import {MintableIncentivizedERC20} from "aave-v3-core/contracts/protocol/tokenization/base/MintableIncentivizedERC20.sol";
import {IAaveIncentivesController} from "aave-v3-core/contracts/interfaces/IAaveIncentivesController.sol";
import {IPool} from "aave-v3-core/contracts/interfaces/IPool.sol";
import {Checkpoints} from "@openzeppelin/contracts/utils/Checkpoints.sol";

import {FlexVotingClient} from "src/FlexVotingClient.sol";
// forgefmt: disable-end

/// @notice This is an extension of Aave V3's AToken contract which makes it possible for AToken
/// holders to still vote on governance proposals. This way, holders of governance tokens do not
/// have to choose between earning yield on Aave and voting. They can do both.
///
/// AToken holders are able to call `expressVote` to signal their preference on open governance
/// proposals. When they do so, this extension records that preference with weight proportional to
/// the users's AToken balance at the proposal snapshot.
///
/// At any point after voting preferences have been expressed, the AToken's public `castVote`
/// function may be called to roll up all internal voting records into a single delegated vote to
/// the Governor contract -- a vote which specifies the exact For/Abstain/Against totals expressed
/// by AToken holders. Votes can be rolled up and cast in this manner multiple times for a given
/// proposal.
///
/// This extension has the following requirements:
///   (a) the underlying token be a governance token
///   (b) the related governor contract supports flexible voting (see GovernorCountingFractional)
///
/// Participating in governance via AToken voting is completely optional. Users otherwise still
/// supply, borrow, and hold tokens with Aave as usual.
///
/// The original AToken that this contract extends is viewable here:
///
///   https://github.com/aave/aave-v3-core/blob/c38c6276/contracts/protocol/tokenization/AToken.sol
contract ATokenFlexVoting is AToken, FlexVotingClient {
  using Checkpoints for Checkpoints.History;

  /// @dev Constructor.
  /// @param _pool The address of the Pool contract
  /// @param _governor The address of the flex-voting-compatible governance contract.
  constructor(IPool _pool, address _governor) AToken(_pool) FlexVotingClient(_governor) {}

  // forgefmt: disable-start
  //===========================================================================
  // BEGIN: Aave overrides
  //===========================================================================
  /// Note: this has been modified from Aave v3's AToken to delegate voting
  /// power to itself during initialization.
  ///
  /// @inheritdoc AToken
  function initialize(
    IPool initializingPool,
    address treasury,
    address underlyingAsset,
    IAaveIncentivesController incentivesController,
    uint8 aTokenDecimals,
    string calldata aTokenName,
    string calldata aTokenSymbol,
    bytes calldata params
  ) public override initializer {
    AToken.initialize(
      initializingPool,
      treasury,
      underlyingAsset,
      incentivesController,
      aTokenDecimals,
      aTokenName,
      aTokenSymbol,
      params
    );

    FlexVotingClient._selfDelegate();
  }

  /// Note: this has been modified from Aave v3's MintableIncentivizedERC20 to
  /// checkpoint raw balances accordingly.
  ///
  /// @inheritdoc MintableIncentivizedERC20
  function _burn(address account, uint128 amount) internal override {
    MintableIncentivizedERC20._burn(account, amount);
    FlexVotingClient._checkpointRawBalanceOf(account);
    FlexVotingClient.totalBalanceCheckpoints.push(
      FlexVotingClient.totalBalanceCheckpoints.latest() - amount
    );
  }

  /// Note: this has been modified from Aave v3's MintableIncentivizedERC20 to
  /// checkpoint raw balances accordingly.
  ///
  /// @inheritdoc MintableIncentivizedERC20
  function _mint(address account, uint128 amount) internal override {
    MintableIncentivizedERC20._mint(account, amount);
    FlexVotingClient._checkpointRawBalanceOf(account);
    FlexVotingClient.totalBalanceCheckpoints.push(
      FlexVotingClient.totalBalanceCheckpoints.latest() + amount
    );
  }

  /// @dev This has been modified from Aave v3's AToken contract to checkpoint raw balances
  /// accordingly.  Ideally we would have overriden `IncentivizedERC20._transfer` instead of
  /// `AToken._transfer` as we did for `_mint` and `_burn`, but that isn't possible here:
  /// `AToken._transfer` *already is* an override of `IncentivizedERC20._transfer`
  ///
  /// @inheritdoc AToken
  function _transfer(
    address from,
    address to,
    uint256 amount,
    bool validate
  ) internal virtual override {
    AToken._transfer(from, to, amount, validate);
    FlexVotingClient._checkpointRawBalanceOf(from);
    FlexVotingClient._checkpointRawBalanceOf(to);
  }
  //===========================================================================
  // END: Aave overrides
  //===========================================================================
  // forgefmt: disable-end

  /// @notice Returns the _user's current balance in storage.
  function _rawBalanceOf(address _user) internal view override returns (uint256) {
    return _userState[_user].balance;
  }
}

// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8.10;

import { Comet } from "comet/Comet.sol";
import { CometConfiguration } from "comet/CometConfiguration.sol";

import {IVotingToken} from "src/interfaces/IVotingToken.sol";
import {IFractionalGovernor} from "src/interfaces/IFractionalGovernor.sol";

// TODO add description
contract CometFlexVoting is Comet {
  /// @notice The governor contract associated with this contract's baseToken. It
  /// must be one that supports fractional voting, e.g. GovernorCountingFractional.
  IFractionalGovernor public immutable GOVERNOR;

  /// @dev Constructor.
  /// @param _config The configuration struct for this Comet instance.
  /// @param _governor The address of the flex-voting-compatible governance contract.
  constructor(
    CometConfiguration.Configuration memory _config,
    address _governor
  ) Comet(_config) {
    GOVERNOR = IFractionalGovernor(_governor);
    selfDelegate();
  }

  // This is called within the constructor, but we want it to be publically
  // available if/when existing cTokens are upgraded.
  // TODO can cTokens be upgraded?
  function selfDelegate() public {
    IVotingToken(GOVERNOR.token()).delegate(address(this));
  }

  // forgefmt: disable-start
  //===========================================================================
  // BEGIN: Comet overrides
  //===========================================================================
  //===========================================================================
  // END: Comet overrides
  //===========================================================================
  // forgefmt: disable-end
}

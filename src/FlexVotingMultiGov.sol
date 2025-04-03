// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {FlexVotingBase} from "src/FlexVotingBase.sol";
import {IFractionalGovernor} from "src/interfaces/IFractionalGovernor.sol";

abstract contract FlexVotingMultiGov is FlexVotingBase, Ownable {
  constructor(address _owner) Ownable(_owner) {}

  function updateAllowedGovernors(IFractionalGovernor _governor, bool _isAllowed) external {
    _checkOwner();
    _updateAllowedGovernors(_governor, _isAllowed);
    if (_isAllowed) _selfDelegate(_governor);
  }
}

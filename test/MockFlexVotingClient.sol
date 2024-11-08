// SPDX-License-Identifier: MIT
pragma solidity >=0.8.10;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {FlexVotingClient} from "src/FlexVotingClient.sol";

contract MockFlexVotingClient is FlexVotingClient {
  constructor(address _governor) FlexVotingClient(_governor) {
    _selfDelegate();
  }

  function _rawBalanceOf(address _user) internal view override returns (uint208) {
    uint256 balance = IERC20(GOVERNOR.token()).balanceOf(_user);
    return balance > type(uint208).max ? type(uint208).max : uint208(balance);
  }
}

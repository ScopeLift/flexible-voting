// SPDX-License-Identifier: Unlicensed
pragma solidity >=0.8.10;

import { IPool } from 'aave-v3-core/contracts/interfaces/IPool.sol';
import { ATokenReserveCache } from "src/ATokenReserveCache.sol";

contract MockATokenReserveCache is ATokenReserveCache {

  constructor(
    IPool _pool,
    address _governor,
    uint32 _castVoteWindow
  ) ATokenReserveCache(_pool, _governor, _castVoteWindow) {}

  function exposedRawBalanceOf(address _user) public returns(uint256) {
    return _userState[_user].balance;
  }

}

// SPDX-License-Identifier: Unlicensed
pragma solidity 0.8.15;

import { DSTestPlus } from "solmate/test/utils/DSTestPlus.sol";
import { Vm } from "forge-std/Vm.sol";
import { IAToken } from "aave-v2/interfaces/IAToken.sol";
import { IAToken } from "aave-v2/protocol/tokenization/AToken.sol";

import {GovToken} from "./GovToken.sol";

contract AaveAtokenForkTest is DSTestPlus {
  uint256 forkId;
  Vm vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

  IAToken atoken;
  ERC20 token;

  function setUp() public {
    uint256 mainnetForkBlock = 15641047; // The mainnet block number at the time this test was written.
    forkId = vm.createSelectFork(vm.envString("MAINNET_RPC_URL"), mainnetForkBlock);

    // deploy the GOV token
    token = new GovToken();

    // deploy the aGOV token
    // data from https://dune.com/queries/1329814?d=4
    atoken = new AToken(
      ILendingPool(0x7d2768dE32b0b80b7a3454c06BdAc94A69DDc7A9), // the mainnet pool
      0x464c71f6c2f760dda6093dcb91c24c39e5d6e18c, // treasury
      address(token),
      IAaveIncentivesController(0xd784927ff2f95ba542bfc824c8a8a98f3495f6b5), // incentivesController
      18, // aTokenDecimals
      "aGOV", // string calldata aTokenName
      "aGOV", // string calldata aTokenSymbol
      "" // bytes calldata params
    )

    // add the aGOV token to aave
  }

  function testFork_ATokenWorks() {
    vm.selectFork(forkId);
  }
}

// SPDX-License-Identifier: Unlicensed
pragma solidity >=0.8.10;

import { DSTestPlus } from "solmate/test/utils/DSTestPlus.sol";
import { Vm } from "forge-std/Vm.sol";
import { ERC20 } from "openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";

import { IAToken } from "aave-v3-core/contracts/interfaces/IAToken.sol";
import { AToken } from "aave-v3-core/contracts/protocol/tokenization/AToken.sol";
import { IPool } from 'aave-v3-core/contracts/interfaces/IPool.sol';
import { IAaveIncentivesController } from 'aave-v3-core/contracts/interfaces/IAaveIncentivesController.sol';

import {GovToken} from "./GovToken.sol";

contract AaveAtokenForkTest is DSTestPlus {
  uint256 forkId;
  Vm vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

  IAToken atoken;
  ERC20 token;

  function setUp() public {
    uint256 optimismForkBlock = 26332308; // The mainnet block number at the time this test was written.
    forkId = vm.createSelectFork(vm.envString("OPTIMISM_RPC_URL"), optimismForkBlock);

    // deploy the GOV token
    token = new GovToken();

    // deploy the aGOV token
    IPool _pool = IPool(0x794a61358D6845594F94dc1DB02A252b5b4814aD);
    atoken = new AToken(_pool);
    // data from https://dune.com/queries/1329814/2272783?d=10
    atoken.initialize(
      _pool,
      0xB2289E329D2F85F1eD31Adbb30eA345278F21bcf, // treasury
      address(token), // underlyingAsset,
      IAaveIncentivesController(0x0aadeE9418641b5749e872eDEF9844200143865D), // incentivesController
      token.decimals(), // aTokenDecimals
      "Aave V3 Optimism GOV", // aTokenName
      "aOptGOV", // aTokenSymbol
      bytes("10") // params?? the chainID?
    );

    // add the aGOV token to aave
  }

  function testFork_ATokenWorks() {
    vm.selectFork(forkId);
  }
}

// SPDX-License-Identifier: Unlicensed
pragma solidity >=0.8.10;

import { DSTestPlus } from "solmate/test/utils/DSTestPlus.sol";
import { Vm } from "forge-std/Vm.sol";
import { ERC20 } from "openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";

import { IAToken } from "aave-v3-core/contracts/interfaces/IAToken.sol";
import { AToken } from "aave-v3-core/contracts/protocol/tokenization/AToken.sol";
import { IPool } from 'aave-v3-core/contracts/interfaces/IPool.sol';
import { ConfiguratorInputTypes } from 'aave-v3-core/contracts/protocol/libraries/types/ConfiguratorInputTypes.sol';

import {GovToken} from "./GovToken.sol";

contract AaveAtokenForkTest is DSTestPlus {
  uint256 forkId;
  Vm vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

  IAToken aToken;
  ERC20 token;

  function setUp() public {
    uint256 optimismForkBlock = 26332308; // The mainnet block number at the time this test was written.
    forkId = vm.createSelectFork(vm.envString("OPTIMISM_RPC_URL"), optimismForkBlock);

    // deploy the GOV token
    token = new GovToken();

    // deploy the aGOV token
    IPool _pool = IPool(0x794a61358D6845594F94dc1DB02A252b5b4814aD); // pool from https://dune.com/queries/1329814
    address _poolConfigurator = 0x8145eddDf43f50276641b55bd3AD95944510021E; // pool.ADDRESSES_PROVIDER().getPoolConfigurator()
    aToken = new AToken(_pool);

    // address _poolConfigurator = _pool
    // add the aGOV token to aave
    //  * could maybe just call updateAToken on the PoolConfigurator to change
    //    the implementation address for a given aToken?
    //
    //  * vm.prank(pool.ADDRESSES_PROVIDER().getPoolConfigurator())
    //  * initReserve (onlyPoolConfigurer) on the pool calls...
    //  * executeInitReserve (external fn) from PoolLogic, which calls...
    //  * init (internal fn) from ReserveLogic

    // This is the stableDebtToken implementation that all of the Optimism
    // aTokens use. You can see this here: https://dune.com/queries/1332820.
    // Each token uses a different stableDebtToken, but those are just proxies.
    // They each proxy to this address for their implementation.
    address _stableDebtToken = 0x52A1CeB68Ee6b7B5D13E0376A1E0E4423A8cE26e;
    string memory _stableDebtTokenName = "Aave Optimism Stable Debt GOV";
    string memory _stableDebtTokenSymbol = "stableDebtOptGOV";

    // This is the variableDebtToken implementation that all of the Optimism
    // aTokens use. You can see this here: https://dune.com/queries/1332820.
    // Each token uses a different variableDebtToken, but those are just proxies.
    // They each proxy to this address for their implementation.
    address _variableDebtToken = 0x81387c40EB75acB02757C1Ae55D5936E78c9dEd3;
    string memory _variableDebtTokenName = "Aave Optimism Variable Debt GOV";
    string memory _variableDebtTokenSymbol = "variableDebtOptGOV";

    ConfiguratorInputTypes.InitReserveInput[] memory _initReservesInput;
    _initReservesInput[0] = ConfiguratorInputTypes.InitReserveInput(
      address(aToken), // aTokenImpl
      _stableDebtToken, // stableDebtTokenImpl
      _variableDebtToken, // variableDebtTokenImpl
      token.decimals(), // underlyingAssetDecimals
      0x4aa694e6c06D6162d95BE98a2Df6a521d5A7b521, // interestRateStrategyAddress, taken from https://dune.com/queries/1332820
      address(token), // underlyingAsset
      // treasury + pool + incentives data from https://dune.com/queries/1329814
      0xB2289E329D2F85F1eD31Adbb30eA345278F21bcf, // treasury
      0x0aadeE9418641b5749e872eDEF9844200143865D, // incentivesController
      "Aave V3 Optimism GOV", // aTokenName
      "aOptGOV", // aTokenSymbol
      _variableDebtTokenName,
      _variableDebtTokenSymbol,
      _stableDebtTokenName,
      _stableDebtTokenSymbol,
      bytes("10") // chainID??
    );

    address _aaveAdmin = 0xE50c8C619d05ff98b22Adf991F17602C774F785c;
    vm.prank(_aaveAdmin);
    _poolConfigurator.initReserves(_initReservesInput);


    // to deposit to aave
      // if ERC20: approve the pool to transfer, call `supply` on the pool
  }

  function testFork_ATokenWorks() public {
    vm.selectFork(forkId);
  }
}

// SPDX-License-Identifier: Unlicensed
pragma solidity >=0.8.10;

import { DSTestPlus } from "solmate/test/utils/DSTestPlus.sol";
import { Vm } from "forge-std/Vm.sol";
import { ERC20 } from "openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";

import { IAToken } from "aave-v3-core/contracts/interfaces/IAToken.sol";
import { AToken } from "aave-v3-core/contracts/protocol/tokenization/AToken.sol";
import { IPool } from 'aave-v3-core/contracts/interfaces/IPool.sol';
import { ConfiguratorInputTypes } from 'aave-v3-core/contracts/protocol/libraries/types/ConfiguratorInputTypes.sol';
import { PoolConfigurator } from 'aave-v3-core/contracts/protocol/pool/PoolConfigurator.sol';

import {GovToken} from "./GovToken.sol";

contract AaveAtokenForkTest is DSTestPlus {
  uint256 forkId;
  Vm vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

  IAToken aToken;
  GovToken token;
  IPool pool;

  function setUp() public {
    uint256 optimismForkBlock = 26332308; // The mainnet block number at the time this test was written.
    forkId = vm.createSelectFork(vm.envString("OPTIMISM_RPC_URL"), optimismForkBlock);

    // deploy the GOV token
    token = new GovToken();

    // deploy the aGOV token
    pool = IPool(0x794a61358D6845594F94dc1DB02A252b5b4814aD); // pool from https://dune.com/queries/1329814
    PoolConfigurator _poolConfigurator = PoolConfigurator(0x8145eddDf43f50276641b55bd3AD95944510021E); // pool.ADDRESSES_PROVIDER().getPoolConfigurator()
    AToken _aTokenImplementation = new AToken(pool);

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

    ConfiguratorInputTypes.InitReserveInput[] memory _initReservesInput = new ConfiguratorInputTypes.InitReserveInput[](1);
    _initReservesInput[0] = ConfiguratorInputTypes.InitReserveInput(
      address(_aTokenImplementation), // aTokenImpl
      _stableDebtToken, // stableDebtTokenImpl
      _variableDebtToken, // variableDebtTokenImpl
      token.decimals(), // underlyingAssetDecimals
      0x4aa694e6c06D6162d95BE98a2Df6a521d5A7b521, // interestRateStrategyAddress, taken from https://dune.com/queries/1332820
      address(token), // underlyingAsset
      // treasury + incentives data from https://dune.com/queries/1329814
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

    // Add our AToken to Aave.
    address _aaveAdmin = 0xE50c8C619d05ff98b22Adf991F17602C774F785c;
    vm.prank(_aaveAdmin);
    _poolConfigurator.initReserves(_initReservesInput);

    // Get the AToken instance just deployed.
    // forge inspect lib/aave-v3-core/contracts/protocol/pool/Pool.sol:Pool storage
    //   reservesCount: "offset": 8, "slot": "59",
    bytes32 _reservesCountStorageSlot = bytes32(uint256(59));
    uint256 _reservesCountStorageOffset = 64; // 8 byte offset
    uint256 _reservesCountStorageSize = 16; // it is a uint16
    bytes32 _reservesCountStorageVal = vm.load(address(pool), _reservesCountStorageSlot);
    bytes32 _reservesCountMask = bytes32((1 << _reservesCountStorageSize) - 1);

    uint16 _reservesCount = uint16(uint256((_reservesCountStorageVal >> _reservesCountStorageOffset) & _reservesCountMask));
    console2.log("david reservesCount", _reservesCount);

    // Next, we compute the slot of the reservesList storage given the
    // reservesCount above. It is a mapping, so the storage slot is equal to the
    // hash of the key we are interested in, concatenated with the mapping slot
    // itself.
    // https://docs.soliditylang.org/en/v0.8.11/internals/layout_in_storage.html#mappings-and-dynamic-arrays
    // forge inspect lib/aave-v3-core/contracts/protocol/pool/Pool.sol:Pool storage
    //   reservesList: "offset": 0, "slot": "54",
    bytes32 _reservesListStorageSlot = keccak256(
      bytes.concat(
        bytes32(uint256(_reservesCount - 1)), // the mapping key, we subtract 1 b/c it's zero indexed
        bytes32(uint256(54)) // reservesList slot, as determined by forge
      )
    );
    aToken = AToken(
      address(uint160(uint256(vm.load(address(pool), _reservesListStorageSlot))))
    );

    assertEq(aToken.symbol(), "Aave V3 Optimism GOV");

  }

  function testFork_ATokenWorks() public {
    assertEq(aToken.balanceOf(address(this)), 0);

    // mint GOV and deposit into aave
    token.THIS_IS_JUST_A_TEST_HOOK_mint(address(this), 42 ether);
    token.approve(address(pool), type(uint256).max);
    pool.supply(
      address(token),
      2 ether,
      address(this),
      0 // referral code
    );
    assertEq(aToken.balanceOf(address(this)), 2 ether);

      // if ERC20: approve the pool to transfer, call `supply` on the pool
  }
}

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
    // We need to use optimism for Aave V3 because it's not (yet?) on mainnet.
    // https://docs.aave.com/developers/deployed-contracts/v3-mainnet
    uint256 optimismForkBlock = 26332308; // The optimism block number at the time this test was written.
    forkId = vm.createSelectFork(vm.envString("OPTIMISM_RPC_URL"), optimismForkBlock);

    // deploy the GOV token
    token = new GovToken();
    pool = IPool(0x794a61358D6845594F94dc1DB02A252b5b4814aD); // pool from https://dune.com/queries/1329814
    PoolConfigurator _poolConfigurator = PoolConfigurator(0x8145eddDf43f50276641b55bd3AD95944510021E); // pool.ADDRESSES_PROVIDER().getPoolConfigurator()

    // deploy the aGOV token
    AToken _aTokenImplementation = new AToken(pool);

    // This is the stableDebtToken implementation that all of the Optimism
    // aTokens use. You can see this here: https://dune.com/queries/1332820.
    // Each token uses a different stableDebtToken, but those are just proxies.
    // They each proxy to this address for their implementation. We will do the
    // same.
    address _stableDebtTokenImpl = 0x52A1CeB68Ee6b7B5D13E0376A1E0E4423A8cE26e;
    string memory _stableDebtTokenName = "Aave Optimism Stable Debt GOV";
    string memory _stableDebtTokenSymbol = "stableDebtOptGOV";

    // This is the variableDebtToken implementation that all of the Optimism
    // aTokens use. You can see this here: https://dune.com/queries/1332820.
    // Each token uses a different variableDebtToken, but those are just proxies.
    // They each proxy to this address for their implementation. We will do the
    // same.
    address _variableDebtTokenImpl = 0x81387c40EB75acB02757C1Ae55D5936E78c9dEd3;
    string memory _variableDebtTokenName = "Aave Optimism Variable Debt GOV";
    string memory _variableDebtTokenSymbol = "variableDebtOptGOV";

    ConfiguratorInputTypes.InitReserveInput[] memory _initReservesInput = new ConfiguratorInputTypes.InitReserveInput[](1);
    _initReservesInput[0] = ConfiguratorInputTypes.InitReserveInput(
      address(_aTokenImplementation), // aTokenImpl
      _stableDebtTokenImpl, // stableDebtTokenImpl
      _variableDebtTokenImpl, // variableDebtTokenImpl
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

    // Get the address of the AToken instance just deployed.
    //
    // Unfortunately, this is not trivial. Aave emits this address as a part of
    // the ReserveInitialized event. But we don't have access to events with
    // forge. So we're going to have to read it from storage. The aTokenAddress
    // is stored in the pool's _reserves storage var, and would be accessible
    // internally as:
    //
    //   _reserves[address(token)].aTokenAddress
    //
    // But _reserves is an internal var, so we will have to manually extract
    // the data. Looking it up in forge we see:
    //   $ forge inspect lib/aave-v3-core/contracts/protocol/pool/Pool.sol:Pool storage
    //     ...
    //     "label": "_reserves",
    //     "offset": 0,
    //     "slot": "52",
    //     "type": "t_mapping(t_address,t_struct(ReserveData)12580_storage)"
    //
    // We can see here that _reserves is a mapping pointing to a struct, namely:
    // DataTypes.ReserveData. The struct is a big one, occupying many slots. So
    // we need to find out which slot we want. In this case, the property we
    // care about is called "aTokenAddress" and it is stored fairly deep within
    // the data structure. These are the properties leading up to it (see
    // aave-v3-core/contracts/protocol/libraries/types/DataTypes.sol):
    //
    //   slot 1: ReserveConfigurationMap configuration; <-- just a uint256
    //   slot 2: uint128 liquidityIndex;
    //   slot 2: uint128 currentLiquidityRate;
    //   slot 3: uint128 variableBorrowIndex;
    //   slot 3: uint128 currentVariableBorrowRate;
    //   slot 4: uint128 currentStableBorrowRate;
    //   slot 4: uint40 lastUpdateTimestamp;
    //   slot 4: uint16 id;
    //   slot 5: address aTokenAddress;
    //
    // So we need to take the 4th slot after the one we compute for the mapping:
    bytes32 _aTokenAddressStorageSlot = bytes32(uint256(keccak256(
      bytes.concat(
        bytes32(uint256(uint160(address(token)))), // map key == the token addr
        bytes32(uint256(52)) // _reserves slot, as determined by forge
      )
    )) + 4); // 4 slots *after* the slot computed for the struct, i.e. the 5th slot

    aToken = AToken(
      address(uint160(uint256(
        vm.load(address(pool), _aTokenAddressStorageSlot)
      )))
    );
  }

  function testFork_SetupWorked() public {
    assertEq(ERC20(address(aToken)).symbol(), "aOptGOV");
    assertEq(ERC20(address(aToken)).name(), "Aave V3 Optimism GOV");

    // Confirm that the atoken._underlyingAsset == token
    // forge inspect lib/aave-v3-core/contracts/protocol/tokenization/AToken.sol:AToken storage
    //
    //   "label": "_underlyingAsset",
    //   "offset": 0,
    //   "slot": "61",
    //   "type": "t_address"
    assertEq(
      address(uint160(uint256(
        vm.load(address(aToken), bytes32(uint256(61)))
      ))),
      address(token)
    );

    // Confirm that we can supply GOV to the aToken.
    assertEq(aToken.balanceOf(address(this)), 0);

    // Mint GOV and deposit into aave.
    token.THIS_IS_JUST_A_TEST_HOOK_mint(address(this), 42 ether);
    token.approve(address(pool), type(uint256).max);
    pool.supply(
      address(token),
      2 ether,
      address(this),
      0 // referral code
    );
    assertEq(token.balanceOf(address(this)), 40 ether);
    assertEq(aToken.balanceOf(address(this)), 2 ether);

    // We can withdraw our GOV when we want to.
    pool.withdraw(
      address(token),
      2 ether,
      address(this)
    );
    assertEq(token.balanceOf(address(this)), 42 ether);
    assertEq(aToken.balanceOf(address(this)), 0 ether);
  }
}

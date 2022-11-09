// SPDX-License-Identifier: Unlicensed
pragma solidity >=0.8.10;

// forgefmt: disable-start
import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {ERC20} from "openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";

import {IAToken} from "aave-v3-core/contracts/interfaces/IAToken.sol";
import {AToken} from "aave-v3-core/contracts/protocol/tokenization/AToken.sol";
import {IPool} from "aave-v3-core/contracts/interfaces/IPool.sol";
import {ConfiguratorInputTypes} from "aave-v3-core/contracts/protocol/libraries/types/ConfiguratorInputTypes.sol";
import {PoolConfigurator} from "aave-v3-core/contracts/protocol/pool/PoolConfigurator.sol";
import {DataTypes} from "aave-v3-core/contracts/protocol/libraries/types/DataTypes.sol";
import {AaveOracle} from "aave-v3-core/contracts/misc/AaveOracle.sol";

import {GovToken} from "./GovToken.sol";

import {Pool} from "aave-v3-core/contracts/protocol/pool/Pool.sol";
import "forge-std/console2.sol";
// forgefmt: disable-end

contract AaveAtokenForkTest is Test {
  uint256 forkId;

  IAToken aToken;
  GovToken govToken;
  IPool pool;

  address dai = 0xDA10009cBd5D07dd0CeCc66161FC93D7c9000da1;
  address weth = 0x4200000000000000000000000000000000000006;

  function setUp() public {
    // We need to use optimism for Aave V3 because it's not (yet?) on mainnet.
    // https://docs.aave.com/developers/deployed-contracts/v3-mainnet
    // This was the optimism block number at the time this test was written.
    uint256 optimismForkBlock = 26_332_308;
    forkId = vm.createSelectFork(vm.rpcUrl("optimism"), optimismForkBlock);

    // deploy the GOV token
    govToken = new GovToken();
    // Pool address taken from https://dune.com/queries/1329814.
    pool = IPool(0x794a61358D6845594F94dc1DB02A252b5b4814aD);

    // Uncomment this line to temporarily etch local code onto the fork address
    // so that we can do things like add console.log statements during
    // debugging:
    // vm.etch(address(pool), address(new Pool(pool.ADDRESSES_PROVIDER())).code);

    // Address from: pool.ADDRESSES_PROVIDER().getPoolConfigurator();
    PoolConfigurator _poolConfigurator =
      PoolConfigurator(0x8145eddDf43f50276641b55bd3AD95944510021E);

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

    ConfiguratorInputTypes.InitReserveInput[] memory _initReservesInput =
      new ConfiguratorInputTypes.InitReserveInput[](1);
    _initReservesInput[0] = ConfiguratorInputTypes.InitReserveInput(
      address(_aTokenImplementation), // aTokenImpl
      _stableDebtTokenImpl, // stableDebtTokenImpl
      _variableDebtTokenImpl, // variableDebtTokenImpl
      govToken.decimals(), // underlyingAssetDecimals
      // Taken from https://dune.com/queries/1332820
      0x4aa694e6c06D6162d95BE98a2Df6a521d5A7b521, // interestRateStrategyAddress
      address(govToken), // underlyingAsset
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
    vm.recordLogs();
    _poolConfigurator.initReserves(_initReservesInput);

    // Retrieve the address of the aToken contract just deployed.
    Vm.Log[] memory _emittedEvents = vm.getRecordedLogs();
    Vm.Log memory _event;
    bytes32 _eventSig = keccak256("ReserveInitialized(address,address,address,address,address)");
    for (uint256 _i; _i < _emittedEvents.length; _i++) {
      _event = _emittedEvents[_i];
      if (_event.topics[0] == _eventSig) {
        // event ReserveInitialized(
        //   address indexed asset,
        //   address indexed aToken,     <-- The topic we want.
        //   address stableDebtToken,
        //   address variableDebtToken,
        //   address interestRateStrategyAddress
        // );
        aToken = AToken(address(uint160(uint256(_event.topics[2]))));
      }
    }

    // Configure GOV to serve as collateral.
    //
    // We are copying the DAI configs here. Configs were obtained by inserting
    // console.log statements and printing out
    // _reserves[daiAddr].configuration.getParams() from within
    // GenericLogic.calculateUserAccountData.
    // tok   ltv   liqThr  liqBon
    // ------------------------
    // DAI   7500  8000    10500
    // wETH  8000  8250    10500
    // wBTC  7000  7500    11000
    // USDC  8000  8500    10500
    vm.prank(_aaveAdmin);
    _poolConfigurator.configureReserveAsCollateral(
      address(govToken), // underlyingAsset
      7500, // ltv, i.e. loan-to-value
      8000, // liquidationThreshold, i.e. threshold at which positions will be liquidated
      10_500 // liquidationBonus
    );

    // Configure GOV to be borrowed.
    vm.prank(_aaveAdmin);
    _poolConfigurator.setReserveBorrowing(address(govToken), true);

    // Allow GOV to be borrowed with stablecoins as collateral.
    vm.prank(_aaveAdmin);
    _poolConfigurator.setReserveStableRateBorrowing(address(govToken), true);

    // Sometimes Aave uses oracles to get price information, e.g. when
    // determining the value of collateral relative to loan value. Since GOV
    // isn't a real thing and doesn't have a real price, we need to mock these
    // calls. When borrowing, the oracle interaction happens in
    // GenericLogic.calculateUserAccountData L130
    address _priceOracle = pool.ADDRESSES_PROVIDER().getPriceOracle();
    vm.mockCall(
      _priceOracle,
      abi.encodeWithSelector(AaveOracle.getAssetPrice.selector, address(govToken)),
      // Aave only seems to use USD-based oracles, so we will do the same.
      abi.encode(1e8) // 1 GOV == $1 USD
    );
  }

  function testFork_SetupCanSupplyGovToAave() public {
    assertEq(ERC20(address(aToken)).symbol(), "aOptGOV");
    assertEq(ERC20(address(aToken)).name(), "Aave V3 Optimism GOV");

    // Confirm that the atoken._underlyingAsset == govToken
    //
    //   $ forge inspect lib/aave-v3-core/contracts/protocol/tokenization/AToken.sol:AToken storage
    //     ...
    //     "label": "_underlyingAsset",
    //     "offset": 0,
    //     "slot": "61",
    //     "type": "t_address"
    assertEq(
      address(uint160(uint256(vm.load(address(aToken), bytes32(uint256(61)))))), address(govToken)
    );

    // Mint GOV and deposit into aave.
    // Confirm that we can supply GOV to the aToken.
    assertEq(aToken.balanceOf(address(this)), 0);
    govToken.exposed_mint(address(this), 42 ether);
    govToken.approve(address(pool), type(uint256).max);
    pool.supply(
      address(govToken),
      2 ether,
      address(this),
      0 // referral code
    );
    assertEq(govToken.balanceOf(address(this)), 40 ether);
    assertEq(aToken.balanceOf(address(this)), 2 ether);

    // We can withdraw our GOV when we want to.
    pool.withdraw(address(govToken), 2 ether, address(this));
    assertEq(govToken.balanceOf(address(this)), 42 ether);
    assertEq(aToken.balanceOf(address(this)), 0 ether);
  }

  function testFork_SetupCanBorrowAgainstGovCollateral() public {
    // supply GOV
    govToken.exposed_mint(address(this), 42 ether);
    govToken.approve(address(pool), type(uint256).max);
    pool.supply(
      address(govToken),
      2 ether,
      address(this),
      0 // referral code
    );
    assertEq(govToken.balanceOf(address(this)), 40 ether);
    assertEq(aToken.balanceOf(address(this)), 2 ether);

    assertEq(ERC20(dai).balanceOf(address(this)), 0);

    // borrow DAI against GOV
    pool.borrow(
      dai,
      42, // amount of DAI to borrow
      uint256(DataTypes.InterestRateMode.STABLE), // interestRateMode
      0, // referralCode
      address(this) // onBehalfOf
    );

    assertEq(ERC20(dai).balanceOf(address(this)), 42);
  }

  function testFork_SetupCanBorrowGovAndBeLiquidated() public {
    // Someone else supplies GOV -- necessary so we can borrow it
    address _bob = address(0xBEEF);
    govToken.exposed_mint(_bob, 1100e18);
    vm.startPrank(_bob);
    govToken.approve(address(pool), type(uint256).max);
    // Don't supply all of the GOV, some will be needed to liquidate.
    pool.supply(address(govToken), 1000e18, _bob, 0);
    vm.stopPrank();

    // We suppy WETH.
    deal(weth, address(this), 100 ether);
    ERC20(weth).approve(address(pool), type(uint256).max);
    pool.supply(weth, 100 ether, address(this), 0);
    ERC20 _awethToken = ERC20(0xe50fA9b3c56FfB159cB0FCA61F5c9D750e8128c8);
    uint256 _thisATokenBalance = _awethToken.balanceOf(address(this));
    assertEq(_thisATokenBalance, 100 ether);

    // Borrow GOV against WETH
    uint256 _initGovBalance = govToken.balanceOf(address(this));
    pool.borrow(
      address(govToken),
      42e18, // amount of GOV to borrow
      uint256(DataTypes.InterestRateMode.STABLE), // interestRateMode
      0, // referralCode
      address(this) // onBehalfOf
    );
    uint256 _currentGovBalance = govToken.balanceOf(address(this));
    assertEq(_initGovBalance, 0);
    assertEq(_currentGovBalance, 42e18);

    // Oh no, WETH goes to ~zero!
    address _priceOracle = pool.ADDRESSES_PROVIDER().getPriceOracle();
    vm.mockCall(
      _priceOracle,
      abi.encodeWithSelector(AaveOracle.getAssetPrice.selector, weth),
      abi.encode(1) // 1 bip
    );

    // Liquidate GOV position
    uint256 _bobInitAtokenBalance = _awethToken.balanceOf(_bob);
    vm.prank(_bob);
    pool.liquidationCall(
      weth, // collateralAsset
      address(govToken), // borrow asset
      address(this), // borrower
      42e18, // amount borrowed
      true // don't receive atoken, receive underlying
    );
    uint256 _bobCurrentAtokenBalance = _awethToken.balanceOf(_bob);
    assertEq(_bobInitAtokenBalance, 0);
    assertApproxEqRel(_bobCurrentAtokenBalance, _thisATokenBalance, 0.01e18);
  }
}

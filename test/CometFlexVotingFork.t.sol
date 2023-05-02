// SPDX-License-Identifier: Unlicensed
pragma solidity >=0.8.10;

import { Test } from "forge-std/Test.sol";
import { Vm } from "forge-std/Vm.sol";

import { IVotes } from "@openzeppelin/contracts/governance/utils/IVotes.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import { CometFlexVoting } from "src/CometFlexVoting.sol";
import { FractionalGovernor } from "test/FractionalGovernor.sol";
import { ProposalReceiverMock } from "test/ProposalReceiverMock.sol";
import { GovToken } from "test/GovToken.sol";

import { CometConfiguration } from "comet/CometConfiguration.sol";
import { Comet } from "comet/Comet.sol";

contract CometForkTest is Test, CometConfiguration {
  uint256 forkId;

  CometFlexVoting cToken;
  // The Compound governor, not to be confused with the govToken's governance system:
  address immutable COMPOUND_GOVERNOR = 0x6d903f6003cca6255D85CcA4D3B5E5146dC33925;
  GovToken govToken;
  FractionalGovernor flexVotingGovernor;
  ProposalReceiverMock receiver;

  // Mainnet addresses.
  address weth = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;

  // See CometMainInterface.sol.
  error NotCollateralized();

  function setUp() public {
    // Compound v3 has been deployed to mainnet.
    // https://docs.compound.finance/#networks
    uint256 mainnetForkBlock = 17_146_483;
    forkId = vm.createSelectFork(vm.rpcUrl("mainnet"), mainnetForkBlock);

    // Deploy the GOV token.
    govToken = new GovToken();
    vm.label(address(govToken), "govToken");

    // Deploy the governor.
    flexVotingGovernor = new FractionalGovernor("Governor", IVotes(govToken));
    vm.label(address(flexVotingGovernor), "flexVotingGovernor");

    //Deploy the contract which will receive proposal calls.
    receiver = new ProposalReceiverMock();
    vm.label(address(receiver), "receiver");

    // ========= START DEPLOY NEW COMET ========================
    //
    // These configs are all based on the cUSDCv3 token configs:
    //   https://etherscan.io/address/0xc3d688B66703497DAA19211EEdff47f25384cdc3#readProxyContract
    AssetConfig[] memory _assetConfigs = new AssetConfig[](5);
    _assetConfigs[0] = AssetConfig(
      0xc00e94Cb662C3520282E6f5717214004A7f26888, // asset, COMP
      0xdbd020CAeF83eFd542f4De03e3cF0C28A4428bd5, // priceFeed
      18, // decimals
      650000000000000000, // borrowCollateralFactor
      700000000000000000, // liquidateCollateralFactor
      880000000000000000, // liquidationFactor
      900000000000000000000000 // supplyCap
    );
    _assetConfigs[1] = AssetConfig(
      0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599, // asset, WBTC
      0xF4030086522a5bEEa4988F8cA5B36dbC97BeE88c, // priceFeed
      8, // decimals
      700000000000000000, // borrowCollateralFactor
      770000000000000000, // liquidateCollateralFactor
      950000000000000000, // liquidationFactor
      1200000000000 // supplyCap
    );
    _assetConfigs[2] = AssetConfig(
      weth, // asset
      0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419, // priceFeed
      18, // decimals
      825000000000000000, // borrowCollateralFactor
      895000000000000000, // liquidateCollateralFactor
      950000000000000000, // liquidationFactor
      350000000000000000000000 // supplyCap
    );
    _assetConfigs[3] = AssetConfig(
      0x1f9840a85d5aF5bf1D1762F925BDADdC4201F984, // asset, UNI
      0x553303d460EE0afB37EdFf9bE42922D8FF63220e, // priceFeed
      18, // decimals
      750000000000000000, // borrowCollateralFactor
      810000000000000000, // liquidateCollateralFactor
      930000000000000000, // liquidationFactor
      2300000000000000000000000 // supplyCap
    );
    _assetConfigs[4] = AssetConfig(
      0x514910771AF9Ca656af840dff83E8264EcF986CA, // asset, LINK
      0x2c1d072e956AFFC0D435Cb7AC38EF18d24d9127c, // priceFeed
      18, // decimals
      790000000000000000, // borrowCollateralFactor
      850000000000000000, // liquidateCollateralFactor
      930000000000000000, // liquidationFactor
      1250000000000000000000000 // supplyCap
    );
    Configuration memory _config = Configuration(
      COMPOUND_GOVERNOR,
      0xbbf3f1421D886E9b2c5D716B5192aC998af2012c, // pauseGuardian
      address(govToken), // baseToken
      0x8fFfFfd4AfB6115b954Bd326cbe7B4BA576818f6, // baseTokenPriceFeed, using the chainlink USDC/USD price feed
      0x285617313887d43256F852cAE0Ee4de4b68D45B0, // extensionDelegate
      800000000000000000, // supplyKink
      1030568239 * 60 * 60 * 24 * 365, // supplyPerYearInterestRateSlopeLow
      12683916793 * 60 * 60 * 24 * 365, // supplyPerYearInterestRateSlopeHigh
      0, // supplyPerYearInterestRateBase
      800000000000000000, // borrowKink
      1109842719 * 60 * 60 * 24 * 365, // borrowPerYearInterestRateSlopeLow
      7927447995 * 60 * 60 * 24 * 365, // borrowPerYearInterestRateSlopeHigh
      475646879 * 60 * 60 * 24 * 365, // borrowPerYearInterestRateBase
      600000000000000000, // storeFrontPriceFactor
      1000000000000000, // trackingIndexScale
      0, // baseTrackingSupplySpeed
      3257060185185, // baseTrackingBorrowSpeed
      1000000000000, // baseMinForRewards
      100000000, // baseBorrowMin
      5000000000000, // targetReserves
      _assetConfigs
    );

    cToken = new CometFlexVoting(_config, address(flexVotingGovernor));

    cToken.initializeStorage();
    // ========= END DEPLOY NEW COMET ========================

    // TODO is there anything we need to do to make this an "official" Comet?
  }
}

contract Setup is CometForkTest {
  function testFork_SetupCTokenDeploy() public {
    assertEq(cToken.governor(), COMPOUND_GOVERNOR);
    assertEq(cToken.baseToken(), address(govToken));
    assertEq(address(cToken.GOVERNOR()), address(flexVotingGovernor));

    assertEq(
      govToken.delegates(address(cToken)),
      address(cToken),
      // The CToken should be delegating to itself.
      "cToken is not delegating to itself"
    );
  }

  function testFork_SetupCanSupplyGovToCompound() public {
    // Mint GOV and deposit into Compound.
    assertEq(cToken.balanceOf(address(this)), 0);
    assertEq(govToken.balanceOf(address(cToken)), 0);
    govToken.exposed_mint(address(this), 42 ether);
    govToken.approve(address(cToken), type(uint256).max);
    cToken.supply(address(govToken), 2 ether);

    assertEq(govToken.balanceOf(address(this)), 40 ether);
    assertEq(govToken.balanceOf(address(cToken)), 2 ether);
    assertEq(cToken.balanceOf(address(this)), 2 ether);

    // We can withdraw our GOV when we want to.
    cToken.withdraw(address(govToken), 2 ether);
    assertEq(govToken.balanceOf(address(this)), 42 ether);
    assertEq(cToken.balanceOf(address(this)), 0 ether);
  }

  // TODO can you borrow against the base position?
  function testFork_SetupCanBorrowAgainstGovCollateral() public {
  }

  function testFork_SetupCanBorrowGov() public {
    // Mint GOV and deposit into Compound.
    address _supplier = address(this);
    assertEq(cToken.balanceOf(_supplier), 0);
    assertEq(govToken.balanceOf(address(cToken)), 0);
    govToken.exposed_mint(_supplier, 1_000 ether);
    govToken.approve(address(cToken), type(uint256).max);
    cToken.supply(address(govToken), 1_000 ether);
    uint256 _initCTokenBalance = cToken.balanceOf(_supplier);
    assertGt(_initCTokenBalance, 0);

    // Someone else wants to borrow GOV.
    address _borrower = makeAddr("_borrower");
    deal(weth, _borrower, 100 ether);
    vm.prank(_borrower);
    vm.expectRevert(NotCollateralized.selector);
    cToken.withdraw(address(govToken), 0.1 ether);

    // Borrower deposits WETH to borrow GOV against.
    vm.prank(_borrower);
    ERC20(weth).approve(address(cToken), type(uint256).max);
    vm.prank(_borrower);
    cToken.supply(weth, 100 ether);
    assertEq(ERC20(weth).balanceOf(_borrower), 0);

    // Borrow GOV against WETH position
    vm.prank(_borrower);
    cToken.withdraw(address(govToken), 100 ether);
    assertEq(govToken.balanceOf(_borrower), 100 ether);

    // Supplier earns yield.
    vm.roll(block.number + 1);
    vm.warp(block.timestamp + 1 days);
    uint256 _newCTokenBalance = cToken.balanceOf(_supplier);
    assertTrue(_newCTokenBalance > _initCTokenBalance, "Supplier has not earned yield");
  }
}

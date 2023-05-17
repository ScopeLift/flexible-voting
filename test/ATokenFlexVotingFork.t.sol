// SPDX-License-Identifier: Unlicensed
pragma solidity >=0.8.10;

// forgefmt: disable-start
import { Test } from "forge-std/Test.sol";
import { Vm } from "forge-std/Vm.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { IVotes } from "@openzeppelin/contracts/governance/utils/IVotes.sol";

import { AaveOracle } from 'aave-v3-core/contracts/misc/AaveOracle.sol';
import { AToken } from "aave-v3-core/contracts/protocol/tokenization/AToken.sol";
import { ConfiguratorInputTypes } from 'aave-v3-core/contracts/protocol/libraries/types/ConfiguratorInputTypes.sol';
import { DataTypes } from 'aave-v3-core/contracts/protocol/libraries/types/DataTypes.sol';
import { IAToken } from "aave-v3-core/contracts/interfaces/IAToken.sol";
import { IPool } from 'aave-v3-core/contracts/interfaces/IPool.sol';
import { PoolConfigurator } from 'aave-v3-core/contracts/protocol/pool/PoolConfigurator.sol';

import { MockATokenFlexVoting } from "test/MockATokenFlexVoting.sol";
import { FractionalGovernor } from "test/FractionalGovernor.sol";
import { ProposalReceiverMock } from "test/ProposalReceiverMock.sol";
import { GovToken } from "test/GovToken.sol";

// Uncomment these lines if you need to etch below.
// import { Pool } from 'aave-v3-core/contracts/protocol/pool/Pool.sol';
// import { DefaultReserveInterestRateStrategy } from 'aave-v3-core/contracts/protocol/pool/DefaultReserveInterestRateStrategy.sol';
// import { IPoolAddressesProvider } from 'aave-v3-core/contracts/interfaces/IPoolAddressesProvider.sol';
// forgefmt: disable-end
//
contract AaveAtokenForkTest is Test {
  uint256 forkId;

  MockATokenFlexVoting aToken;
  GovToken govToken;
  FractionalGovernor governor;
  ProposalReceiverMock receiver;
  IPool pool;

  // These are addresses on Optimism.
  address dai = 0xDA10009cBd5D07dd0CeCc66161FC93D7c9000da1;
  address weth = 0x4200000000000000000000000000000000000006;

  uint256 constant INITIAL_REBASING_DEPOSIT = 1000 ether;
  address initialSupplier;

  enum ProposalState {
    Pending,
    Active,
    Canceled,
    Defeated,
    Succeeded,
    Queued,
    Expired,
    Executed
  }

  enum VoteType {
    Against,
    For,
    Abstain
  }

  function setUp() public {
    // We need to use optimism for Aave V3 because it's not (yet?) on mainnet.
    // https://docs.aave.com/developers/deployed-contracts/v3-mainnet
    // This was the optimism block number at the time this test was written.
    uint256 optimismForkBlock = 26_332_308;
    forkId = vm.createSelectFork(vm.rpcUrl("optimism"), optimismForkBlock);

    initialSupplier = makeAddr("InitialSupplier");

    // Deploy the GOV token.
    govToken = new GovToken();
    // Pool from https://dune.com/queries/1329814.
    pool = IPool(0x794a61358D6845594F94dc1DB02A252b5b4814aD);
    vm.label(address(pool), "pool");

    // Deploy the governor.
    governor = new FractionalGovernor("Governor", IVotes(govToken));
    vm.label(address(governor), "governor");

    // Deploy the contract which will receive proposal calls.
    receiver = new ProposalReceiverMock();
    vm.label(address(receiver), "receiver");

    // Uncomment this line to temporarily etch local code onto the fork address
    // so that we can do things like add console.log statements during
    // debugging:
    // vm.etch(address(pool), address(new Pool(pool.ADDRESSES_PROVIDER())).code);

    // Uncomment to etch local code to the DefaultReserveInterestRateStrategy to
    // understand how/when reserve interest rates are calculated (as these are
    // used to determine rebasing rates).
    // vm.etch(
    //   0x4aa694e6c06D6162d95BE98a2Df6a521d5A7b521, // interestRateStrategyAddress
    //   address(
    //     new DefaultReserveInterestRateStrategy(
    //       // These values were taken from Optimism scan for the etched address.
    //       IPoolAddressesProvider(0xa97684ead0e402dC232d5A977953DF7ECBaB3CDb), // provider
    //       800000000000000000000000000, // optimalUsageRatio
    //       0, // baseVariableBorrowRate
    //       40000000000000000000000000, // variableRateSlope1,
    //       750000000000000000000000000, // variableRateSlope2,
    //       20000000000000000000000000, //stableRateSlope1,
    //       750000000000000000000000000, // stableRateSlope2,
    //       20000000000000000000000000, // baseStableRateOffset,
    //       50000000000000000000000000, // stableRateExcessOffset,
    //       200000000000000000000000000 // optimalStableToTotalDebtRatio
    //     )
    //   ).code
    // );

    // Address from: pool.ADDRESSES_PROVIDER().getPoolConfigurator();
    PoolConfigurator _poolConfigurator =
      PoolConfigurator(0x8145eddDf43f50276641b55bd3AD95944510021E);

    // deploy the aGOV token
    AToken _aTokenImplementation = new MockATokenFlexVoting(pool, address(governor));

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
        aToken = MockATokenFlexVoting(address(uint160(uint256(_event.topics[2]))));
        vm.label(address(aToken), "aToken");
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

    // Allow the Aave reserve to collect fees on our transactions.
    vm.prank(_aaveAdmin);
    _poolConfigurator.setReserveFactor(address(govToken), 1000);

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

  // ------------------
  // Helper functions
  // ------------------

  function _mintGovAndSupplyToAave(address _who, uint256 _govAmount) internal {
    govToken.exposed_mint(_who, _govAmount);
    vm.startPrank(_who);
    govToken.approve(address(pool), type(uint256).max);
    pool.supply(address(govToken), _govAmount, _who, 0 /* referral code*/ );
    vm.stopPrank();
  }

  function _createAndSubmitProposal() internal returns (uint256 proposalId) {
    // Proposal will underflow if we're on the zero block.
    if (block.number == 0) vm.roll(42);

    // Create a dummy proposal.
    bytes memory receiverCallData = abi.encodeWithSignature("mockReceiverFunction()");
    address[] memory targets = new address[](1);
    uint256[] memory values = new uint256[](1);
    bytes[] memory calldatas = new bytes[](1);
    targets[0] = address(receiver);
    values[0] = 0; // no ETH will be sent
    calldatas[0] = receiverCallData;

    // Submit the proposal.
    proposalId = governor.propose(targets, values, calldatas, "A great proposal");
    assertEq(uint256(governor.state(proposalId)), uint256(ProposalState.Pending));

    // advance proposal to active state
    vm.roll(governor.proposalSnapshot(proposalId) + 1);
    assertEq(uint256(governor.state(proposalId)), uint256(ProposalState.Active));
  }

  function _initiateRebasing() internal {
    uint256 _initLiquidityRate = pool.getReserveData(address(govToken)).currentLiquidityRate;

    // Have someone mint and deposit some gov.
    _mintGovAndSupplyToAave(initialSupplier, INITIAL_REBASING_DEPOSIT);

    // Have someone else borrow some gov.
    deal(weth, address(this), 100 ether);
    ERC20(weth).approve(address(pool), type(uint256).max);
    pool.supply(weth, 100 ether, address(this), 0);
    pool.borrow(
      address(govToken),
      42 ether, // amount of GOV to borrow
      uint256(DataTypes.InterestRateMode.STABLE), // interestRateMode
      0, // referralCode
      address(this) // onBehalfOf
    );

    // Advance the clock so that checkpoints become meaningful.
    vm.roll(block.number + 42);
    vm.warp(block.timestamp + 42 days);

    // We should be rebasing at this point.
    assertGt(
      pool.getReserveData(address(govToken)).currentLiquidityRate,
      _initLiquidityRate,
      "If the liquidity rate has not changed, rebasing isn't happening."
    );
  }
}

contract Setup is AaveAtokenForkTest {
  function testFork_SetupATokenDeploy() public {
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

    // The AToken should be delegating to itself.
    assertEq(
      govToken.delegates(address(aToken)), address(aToken), "aToken is not delegating to itself"
    );
  }

  function testFork_SetupCanSupplyGovToAave() public {
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
    address _bob = makeAddr("testFork_SetupCanBorrowGovAndBeLiquidated address");
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

contract CastVote is AaveAtokenForkTest {
  function test_UserCanCastAgainstVotes() public {
    _testUserCanCastVotes(
      makeAddr("test_UserCanCastAgainstVotes address"), 4242 ether, uint8(VoteType.Against)
    );
  }

  function test_UserCanCastForVotes() public {
    _testUserCanCastVotes(
      makeAddr("test_UserCanCastForVotes address"), 4242 ether, uint8(VoteType.For)
    );
  }

  function test_UserCanCastAbstainVotes() public {
    _testUserCanCastVotes(
      makeAddr("test_UserCanCastAbstainVotes address"), 4242 ether, uint8(VoteType.Abstain)
    );
  }

  function test_UserCannotExpressAgainstVotesWithoutWeight() public {
    _testUserCannotExpressVotesWithoutATokens(
      makeAddr("test_UserCannotExpressAgainstVotesWithoutWeight address"),
      0.42 ether,
      uint8(VoteType.Against)
    );
  }

  function test_UserCannotExpressForVotesWithoutWeight() public {
    _testUserCannotExpressVotesWithoutATokens(
      makeAddr("test_UserCannotExpressForVotesWithoutWeight address"),
      0.42 ether,
      uint8(VoteType.For)
    );
  }

  function test_UserCannotExpressAbstainVotesWithoutWeight() public {
    _testUserCannotExpressVotesWithoutATokens(
      makeAddr("test_UserCannotExpressAbstainVotesWithoutWeight address"),
      0.42 ether,
      uint8(VoteType.Abstain)
    );
  }

  function test_UserCannotCastAfterVotingPeriodAgainst() public {
    _testUserCannotCastAfterVotingPeriod(
      makeAddr("test_UserCannotCastAfterVotingPeriodAbstain address"),
      4.2 ether,
      uint8(VoteType.Against)
    );
  }

  function test_UserCannotCastAfterVotingPeriodFor() public {
    _testUserCannotCastAfterVotingPeriod(
      makeAddr("test_UserCannotCastAfterVotingPeriodAbstain address"),
      4.2 ether,
      uint8(VoteType.For)
    );
  }

  function test_UserCannotCastAfterVotingPeriodAbstain() public {
    _testUserCannotCastAfterVotingPeriod(
      makeAddr("test_UserCannotCastAfterVotingPeriodAbstain address"),
      4.2 ether,
      uint8(VoteType.Abstain)
    );
  }

  function test_UserCannotDoubleVoteAfterVotingAgainst() public {
    _tesNoDoubleVoting(
      makeAddr("test_UserCannotDoubleVoteAfterVoting address"), 0.042 ether, uint8(VoteType.Against)
    );
  }

  function test_UserCannotDoubleVoteAfterVotingFor() public {
    _tesNoDoubleVoting(
      makeAddr("test_UserCannotDoubleVoteAfterVoting address"), 0.042 ether, uint8(VoteType.For)
    );
  }

  function test_UserCannotDoubleVoteAfterVotingAbstain() public {
    _tesNoDoubleVoting(
      makeAddr("test_UserCannotDoubleVoteAfterVoting address"), 0.042 ether, uint8(VoteType.Abstain)
    );
  }

  function test_UserCannotCastVotesTwiceAfterVotingAgainst() public {
    _testUserCannotCastVotesTwice(
      makeAddr("test_UserCannotCastVotesTwiceAfterVoting address"),
      1.42 ether,
      uint8(VoteType.Against)
    );
  }

  function test_UserCannotCastVotesTwiceAfterVotingFor() public {
    _testUserCannotCastVotesTwice(
      makeAddr("test_UserCannotCastVotesTwiceAfterVoting address"), 1.42 ether, uint8(VoteType.For)
    );
  }

  function test_UserCannotCastVotesTwiceAfterVotingAbstain() public {
    _testUserCannotCastVotesTwice(
      makeAddr("test_UserCannotCastVotesTwiceAfterVoting address"),
      1.42 ether,
      uint8(VoteType.Abstain)
    );
  }

  function test_UserCannotExpressAgainstVotesPriorToDepositing() public {
    _testUserCannotExpressVotesPriorToDepositing(
      makeAddr("UserCannotExpressVotesPriorToDepositing address"),
      4.242 ether,
      uint8(VoteType.Against)
    );
  }

  function test_UserCannotExpressForVotesPriorToDepositing() public {
    _testUserCannotExpressVotesPriorToDepositing(
      makeAddr("UserCannotExpressVotesPriorToDepositing address"), 4.242 ether, uint8(VoteType.For)
    );
  }

  function test_UserCannotExpressAbstainVotesPriorToDepositing() public {
    _testUserCannotExpressVotesPriorToDepositing(
      makeAddr("UserCannotExpressVotesPriorToDepositing address"),
      4.242 ether,
      uint8(VoteType.Abstain)
    );
  }

  function test_UserAgainstVotingWeightIsSnapshotDependent() public {
    _testUserVotingWeightIsSnapshotDependent(
      makeAddr("UserVotingWeightIsSnapshotDependent address"),
      0.00042 ether,
      0.042 ether,
      uint8(VoteType.Against)
    );
  }

  function test_UserForVotingWeightIsSnapshotDependent() public {
    _testUserVotingWeightIsSnapshotDependent(
      makeAddr("UserVotingWeightIsSnapshotDependent address"),
      0.00042 ether,
      0.042 ether,
      uint8(VoteType.For)
    );
  }

  function test_UserAbstainVotingWeightIsSnapshotDependent() public {
    _testUserVotingWeightIsSnapshotDependent(
      makeAddr("UserVotingWeightIsSnapshotDependent address"),
      0.00042 ether,
      0.042 ether,
      uint8(VoteType.Abstain)
    );
  }

  function test_MultipleUsersCanCastVotes() public {
    _testMultipleUsersCanCastVotes(
      makeAddr("MultipleUsersCanCastVotes address 1"),
      makeAddr("MultipleUsersCanCastVotes address 2"),
      0.42424242 ether,
      0.00000042 ether
    );
  }

  function test_VoteWeightIsScaledBasedOnPoolBalanceAgainstFor() public {
    _testVoteWeightIsScaledBasedOnPoolBalance(
      VoteWeightIsScaledVars(
        makeAddr("VoteWeightIsScaledBasedOnPoolBalance voterA #1"),
        makeAddr("VoteWeightIsScaledBasedOnPoolBalance voterB #1"),
        makeAddr("VoteWeightIsScaledBasedOnPoolBalance borrower #1"),
        12 ether, // voteWeightA
        4 ether, // voteWeightB
        7 ether, // borrowerAssets
        uint8(VoteType.Against), // supportTypeA
        uint8(VoteType.For) // supportTypeB
      )
    );
  }

  function test_VoteWeightIsScaledBasedOnPoolBalanceAgainstAbstain() public {
    _testVoteWeightIsScaledBasedOnPoolBalance(
      VoteWeightIsScaledVars(
        makeAddr("VoteWeightIsScaledBasedOnPoolBalance voterA #2"),
        makeAddr("VoteWeightIsScaledBasedOnPoolBalance voterB #2"),
        makeAddr("VoteWeightIsScaledBasedOnPoolBalance borrower #2"),
        2 ether, // voteWeightA
        7 ether, // voteWeightB
        4 ether, // borrowerAssets
        uint8(VoteType.Against), // supportTypeA
        uint8(VoteType.Abstain) // supportTypeB
      )
    );
  }

  function test_VoteWeightIsScaledBasedOnPoolBalanceForAbstain() public {
    _testVoteWeightIsScaledBasedOnPoolBalance(
      VoteWeightIsScaledVars(
        makeAddr("VoteWeightIsScaledBasedOnPoolBalance voterA #3"),
        makeAddr("VoteWeightIsScaledBasedOnPoolBalance voterB #3"),
        makeAddr("VoteWeightIsScaledBasedOnPoolBalance borrower #3"),
        1 ether, // voteWeightA
        1 ether, // voteWeightB
        1 ether, // borrowerAssets
        uint8(VoteType.For), // supportTypeA
        uint8(VoteType.Abstain) // supportTypeB
      )
    );
  }

  function test_AgainstVotingWeightIsAbandonedIfSomeoneDoesntExpress() public {
    _testVotingWeightIsAbandonedIfSomeoneDoesntExpress(
      VotingWeightIsAbandonedVars(
        makeAddr("VotingWeightIsAbandonedIfSomeoneDoesntExpress voterA #1"),
        makeAddr("VotingWeightIsAbandonedIfSomeoneDoesntExpress voterB #1"),
        makeAddr("VotingWeightIsAbandonedIfSomeoneDoesntExpress borrower #1"),
        1 ether, // voteWeightA
        1 ether, // voteWeightB
        1 ether, // borrowerAssets
        uint8(VoteType.Against) // supportTypeA
      )
    );
  }

  function test_ForVotingWeightIsAbandonedIfSomeoneDoesntExpress() public {
    _testVotingWeightIsAbandonedIfSomeoneDoesntExpress(
      VotingWeightIsAbandonedVars(
        makeAddr("VotingWeightIsAbandonedIfSomeoneDoesntExpress voterA #2"),
        makeAddr("VotingWeightIsAbandonedIfSomeoneDoesntExpress voterB #2"),
        makeAddr("VotingWeightIsAbandonedIfSomeoneDoesntExpress borrower #2"),
        42 ether, // voteWeightA
        24 ether, // voteWeightB
        11 ether, // borrowerAssets
        uint8(VoteType.For) // supportTypeA
      )
    );
  }

  function test_AbstainVotingWeightIsAbandonedIfSomeoneDoesntExpress() public {
    _testVotingWeightIsAbandonedIfSomeoneDoesntExpress(
      VotingWeightIsAbandonedVars(
        makeAddr("VotingWeightIsAbandonedIfSomeoneDoesntExpress voterA #3"),
        makeAddr("VotingWeightIsAbandonedIfSomeoneDoesntExpress voterB #3"),
        makeAddr("VotingWeightIsAbandonedIfSomeoneDoesntExpress borrower #3"),
        24 ether, // voteWeightA
        42 ether, // voteWeightB
        100 ether, // borrowerAssets
        uint8(VoteType.Abstain) // supportTypeA
      )
    );
  }

  function test_AgainstVotingWeightIsUnaffectedByDepositsAfterProposal() public {
    _testVotingWeightIsUnaffectedByDepositsAfterProposal(
      makeAddr("VotingWeightIsUnaffectedByDepositsAfterProposal voterA #1"),
      makeAddr("VotingWeightIsUnaffectedByDepositsAfterProposal voterB #1"),
      1 ether, // voteWeightA
      2 ether, // voteWeightB
      uint8(VoteType.Against) // supportTypeA
    );
  }

  function test_ForVotingWeightIsUnaffectedByDepositsAfterProposal() public {
    _testVotingWeightIsUnaffectedByDepositsAfterProposal(
      makeAddr("VotingWeightIsUnaffectedByDepositsAfterProposal voterA #2"),
      makeAddr("VotingWeightIsUnaffectedByDepositsAfterProposal voterB #2"),
      0.42 ether, // voteWeightA
      0.042 ether, // voteWeightB
      uint8(VoteType.For) // supportTypeA
    );
  }

  function test_AbstainVotingWeightIsUnaffectedByDepositsAfterProposal() public {
    _testVotingWeightIsUnaffectedByDepositsAfterProposal(
      makeAddr("VotingWeightIsUnaffectedByDepositsAfterProposal voterA #3"),
      makeAddr("VotingWeightIsUnaffectedByDepositsAfterProposal voterB #3"),
      10 ether, // voteWeightA
      20 ether, // voteWeightB
      uint8(VoteType.Abstain) // supportTypeA
    );
  }

  function test_AgainstVotingWeightDoesNotGoDownWhenUsersBorrow() public {
    _testVotingWeightDoesNotGoDownWhenUsersBorrow(
      makeAddr("VotingWeightDoesNotGoDownWhenUsersBorrow address 1"),
      4.242 ether, // GOV deposit amount
      1 ether, // DAI borrow amount
      uint8(VoteType.Against) // supportType
    );
  }

  function test_ForVotingWeightDoesNotGoDownWhenUsersBorrow() public {
    _testVotingWeightDoesNotGoDownWhenUsersBorrow(
      makeAddr("VotingWeightDoesNotGoDownWhenUsersBorrow address 2"),
      424.2 ether, // GOV deposit amount
      4 ether, // DAI borrow amount
      uint8(VoteType.For) // supportType
    );
  }

  function test_AbstainVotingWeightDoesNotGoDownWhenUsersBorrow() public {
    _testVotingWeightDoesNotGoDownWhenUsersBorrow(
      makeAddr("VotingWeightDoesNotGoDownWhenUsersBorrow address 3"),
      0.4242 ether, // GOV deposit amount
      0.0424 ether, // DAI borrow amount
      uint8(VoteType.Abstain) // supportType
    );
  }

  function test_AgainstVotingWeightGoesDownWhenUsersFullyWithdraw() public {
    _testVotingWeightGoesDownWhenUsersWithdraw(
      makeAddr("VotingWeightGoesDownWhenUsersWithdraw address #1"),
      42 ether, // supplyAmount
      type(uint256).max, // withdrawAmount
      uint8(VoteType.Against) // supportType
    );
  }

  function test_ForVotingWeightGoesDownWhenUsersFullyWithdraw() public {
    _testVotingWeightGoesDownWhenUsersWithdraw(
      makeAddr("VotingWeightGoesDownWhenUsersWithdraw address #2"),
      42 ether, // supplyAmount
      type(uint256).max, // withdrawAmount
      uint8(VoteType.For) // supportType
    );
  }

  function test_AbstainVotingWeightGoesDownWhenUsersFullyWithdraw() public {
    _testVotingWeightGoesDownWhenUsersWithdraw(
      makeAddr("VotingWeightGoesDownWhenUsersWithdraw address #3"),
      42 ether, // supplyAmount
      type(uint256).max, // withdrawAmount
      uint8(VoteType.Abstain) // supportType
    );
  }

  function test_AgainstVotingWeightGoesDownWhenUsersPartiallyWithdraw() public {
    _testVotingWeightGoesDownWhenUsersWithdraw(
      makeAddr("VotingWeightGoesDownWhenUsersWithdraw address #4"),
      42 ether, // supplyAmount
      2 ether, // withdrawAmount
      uint8(VoteType.Against) // supportType
    );
  }

  function test_ForVotingWeightGoesDownWhenUsersPartiallyWithdraw() public {
    _testVotingWeightGoesDownWhenUsersWithdraw(
      makeAddr("VotingWeightGoesDownWhenUsersWithdraw address #5"),
      42 ether, // supplyAmount
      3 ether, // withdrawAmount
      uint8(VoteType.For) // supportType
    );
  }

  function test_AbstainVotingWeightGoesDownWhenUsersPartiallyWithdraw() public {
    _testVotingWeightGoesDownWhenUsersWithdraw(
      makeAddr("VotingWeightGoesDownWhenUsersWithdraw address #6"),
      42 ether, // supplyAmount
      10 ether, // withdrawAmount
      uint8(VoteType.Abstain) // supportType
    );
  }

  function test_CannotCastVoteWithoutVotesExpressed() public {
    _testCannotCastVoteWithoutVotesExpressed(
      makeAddr("CannotCastVoteWithoutVotesExpressed who"),
      uint8(VoteType.Abstain) // supportType
    );
  }

  function test_VotingWeightWorksWithRebasing() public {
    _testVotingWeightWorksWithRebasing(
      makeAddr("VotingWeightWorksWithRebasing userA"),
      makeAddr("VotingWeightWorksWithRebasing userB"),
      424_242 ether
    );
  }

  function test_CastForVoteWithFullyTransferredATokens() public {
    _testCastVoteWithTransferredATokens(
      makeAddr("CastVoteWithTransferredATokens userA #1"),
      makeAddr("CastVoteWithTransferredATokens userB #1"),
      1 ether, // weight
      1 ether, // transferAmount
      uint8(VoteType.For), // supportTypeA
      uint8(VoteType.For) // supportTypeB
    );
  }

  function test_CastAgainstVoteWithFullyTransferredATokens() public {
    _testCastVoteWithTransferredATokens(
      makeAddr("CastVoteWithTransferredATokens userA #2"),
      makeAddr("CastVoteWithTransferredATokens userB #2"),
      42 ether, // weight
      42 ether, // transferAmount
      uint8(VoteType.For), // supportTypeA
      uint8(VoteType.Against) // supportTypeB
    );
  }

  function test_VotesCanBeCastIncrementally1() public {
    _testVotesCanBeCastIncrementally(
      makeAddr("test_VotesCanBeCastIncrementally userA #1"),
      makeAddr("test_VotesCanBeCastIncrementally userB #1"),
      uint8(VoteType.For), // supportTypeA
      uint8(VoteType.Abstain) // supportTypeB
    );
  }

  function test_VotesCanBeCastIncrementally2() public {
    _testVotesCanBeCastIncrementally(
      makeAddr("test_VotesCanBeCastIncrementally userA #2"),
      makeAddr("test_VotesCanBeCastIncrementally userB #2"),
      uint8(VoteType.For), // supportTypeA
      uint8(VoteType.For) // supportTypeB
    );
  }

  function test_VotesCanBeCastIncrementally3() public {
    _testVotesCanBeCastIncrementally(
      makeAddr("test_VotesCanBeCastIncrementally userA #3"),
      makeAddr("test_VotesCanBeCastIncrementally userB #3"),
      uint8(VoteType.Against), // supportTypeA
      uint8(VoteType.For) // supportTypeB
    );
  }

  function test_CastAbstainVoteWithFullyTransferredATokens() public {
    _testCastVoteWithTransferredATokens(
      makeAddr("CastVoteWithTransferredATokens userA #3"),
      makeAddr("CastVoteWithTransferredATokens userB #3"),
      0.42 ether, // weight
      0.42 ether, // transferAmount
      uint8(VoteType.For), // supportTypeA
      uint8(VoteType.Abstain) // supportTypeB
    );
  }

  function test_CastSameVoteWithBarelyTransferredATokens() public {
    _testCastVoteWithTransferredATokens(
      makeAddr("CastVoteWithTransferredATokens userA #4"),
      makeAddr("CastVoteWithTransferredATokens userB #4"),
      // Transfer less than half.
      1 ether, // weight
      0.33 ether, // transferAmount
      uint8(VoteType.For), // supportTypeA
      uint8(VoteType.For) // supportTypeB
    );
  }

  function test_CastDifferentVoteWithBarelyTransferredATokens() public {
    _testCastVoteWithTransferredATokens(
      makeAddr("CastVoteWithTransferredATokens userA #5"),
      makeAddr("CastVoteWithTransferredATokens userB #5"),
      // Transfer less than half.
      1 ether, // weight
      0.33 ether, // transferAmount
      uint8(VoteType.Abstain), // supportTypeA
      uint8(VoteType.Against) // supportTypeB
    );
  }

  function test_CastSameVoteWithMostlyTransferredATokens() public {
    _testCastVoteWithTransferredATokens(
      makeAddr("CastVoteWithTransferredATokens userA #6"),
      makeAddr("CastVoteWithTransferredATokens userB #6"),
      // Transfer almost all of it.
      42 ether, // weight
      41 ether, // transferAmount
      uint8(VoteType.For), // supportTypeA
      uint8(VoteType.For) // supportTypeB
    );
  }

  function test_CastDifferentVoteWithMostlyTransferredATokens() public {
    _testCastVoteWithTransferredATokens(
      makeAddr("CastVoteWithTransferredATokens userA #7"),
      makeAddr("CastVoteWithTransferredATokens userB #7"),
      // Transfer almost all of it.
      42 ether, // weight
      41 ether, // transferAmount
      uint8(VoteType.Against), // supportTypeA
      uint8(VoteType.For) // supportTypeB
    );
  }

  function _testUserCanCastVotes(address _who, uint256 _voteWeight, uint8 _supportType) private {
    // Deposit some funds.
    _mintGovAndSupplyToAave(_who, _voteWeight);
    assertEq(aToken.balanceOf(_who), _voteWeight, "aToken balance wrong");
    assertEq(govToken.balanceOf(address(aToken)), _voteWeight, "govToken balance wrong");

    // Create the proposal.
    uint256 _proposalId = _createAndSubmitProposal();
    assertEq(
      govToken.getPastVotes(address(aToken), block.number - 1),
      _voteWeight,
      "getPastVotes returned unexpected result"
    );

    // _who should now be able to express his/her vote on the proposal.
    vm.prank(_who);
    aToken.expressVote(_proposalId, _supportType);

    (uint256 _againstVotesExpressed, uint256 _forVotesExpressed, uint256 _abstainVotesExpressed) =
      aToken.proposalVotes(_proposalId);

    // Vote preferences have been expressed.
    assertEq(_forVotesExpressed, _supportType == uint8(VoteType.For) ? _voteWeight : 0);
    assertEq(_againstVotesExpressed, _supportType == uint8(VoteType.Against) ? _voteWeight : 0);
    assertEq(_abstainVotesExpressed, _supportType == uint8(VoteType.Abstain) ? _voteWeight : 0);

    (uint256 _againstVotes, uint256 _forVotes, uint256 _abstainVotes) =
      governor.proposalVotes(_proposalId);

    // But no actual votes have been cast yet.
    assertEq(_forVotes, 0);
    assertEq(_againstVotes, 0);
    assertEq(_abstainVotes, 0);

    // submit votes on behalf of the pool
    aToken.castVote(_proposalId);

    // governor should now record votes from the pool
    (_againstVotes, _forVotes, _abstainVotes) = governor.proposalVotes(_proposalId);
    assertEq(_forVotes, _forVotesExpressed, "for votes not as expected");
    assertEq(_againstVotes, _againstVotesExpressed, "against votes not as expected");
    assertEq(_abstainVotes, _abstainVotesExpressed, "abstain votes not as expected");
  }

  function _testUserCannotExpressVotesWithoutATokens(
    address _who,
    uint256 _voteWeight,
    uint8 _supportType
  ) private {
    // Mint gov but do not deposit
    govToken.exposed_mint(_who, _voteWeight);
    vm.prank(_who);
    govToken.approve(address(pool), type(uint256).max);

    assertEq(govToken.balanceOf(_who), _voteWeight);

    // Create the proposal.
    uint256 _proposalId = _createAndSubmitProposal();

    // _who should NOT be able to express his/her vote on the proposal
    vm.expectRevert(bytes("no weight"));
    vm.prank(_who);
    aToken.expressVote(_proposalId, uint8(_supportType));
  }

  function _testUserCannotCastAfterVotingPeriod(
    address _who,
    uint256 _voteWeight,
    uint8 _supportType
  ) private {
    // Deposit some funds.
    _mintGovAndSupplyToAave(_who, _voteWeight);

    // Create the proposal.
    uint256 _proposalId = _createAndSubmitProposal();

    // Express vote preference.
    vm.prank(_who);
    aToken.expressVote(_proposalId, _supportType);

    // Jump ahead so that we're outside of the proposal's voting period.
    vm.roll(governor.proposalDeadline(_proposalId) + 1);

    // We should not be able to castVote at this point.
    vm.expectRevert(bytes("Governor: vote not currently active"));
    aToken.castVote(_proposalId);
  }

  function _tesNoDoubleVoting(address _who, uint256 _voteWeight, uint8 _supportType) private {
    // Deposit some funds.
    _mintGovAndSupplyToAave(_who, _voteWeight);

    // Create the proposal.
    uint256 _proposalId = _createAndSubmitProposal();

    // _who should now be able to express his/her vote on the proposal.
    vm.prank(_who);
    aToken.expressVote(_proposalId, _supportType);

    // Vote early and often.
    vm.expectRevert(bytes("already voted"));
    vm.prank(_who);
    aToken.expressVote(_proposalId, _supportType);
  }

  function _testUserCannotCastVotesTwice(address _who, uint256 _voteWeight, uint8 _supportType)
    private
  {
    // Deposit some funds.
    _mintGovAndSupplyToAave(_who, _voteWeight);

    // Have someone else deposit as well so that _who isn't the only one.
    _mintGovAndSupplyToAave(makeAddr("testUserCannotCastVotesTwice"), _voteWeight);

    // Create the proposal.
    uint256 _proposalId = _createAndSubmitProposal();

    // _who should now be able to express his/her vote on the proposal.
    vm.prank(_who);
    aToken.expressVote(_proposalId, _supportType);

    // Submit votes on behalf of the pool.
    aToken.castVote(_proposalId);

    // Try to submit them again.
    vm.expectRevert("no votes expressed");
    aToken.castVote(_proposalId);
  }

  function _testUserCannotExpressVotesPriorToDepositing(
    address _who,
    uint256 _voteWeight,
    uint8 _supportType
  ) private {
    // Create the proposal *before* the user deposits anything.
    uint256 _proposalId = _createAndSubmitProposal();

    // Deposit some funds.
    _mintGovAndSupplyToAave(_who, _voteWeight);

    // Now try to express a voting preference on the proposal.
    vm.expectRevert(bytes("no weight"));
    vm.prank(_who);
    aToken.expressVote(_proposalId, _supportType);
  }

  function _testUserVotingWeightIsSnapshotDependent(
    address _who,
    uint256 _voteWeightA,
    uint256 _voteWeightB,
    uint8 _supportType
  ) private {
    // Deposit some funds.
    _mintGovAndSupplyToAave(_who, _voteWeightA);

    // Create the proposal.
    uint256 _proposalId = _createAndSubmitProposal();

    // Sometime later the user deposits some more.
    vm.roll(governor.proposalDeadline(_proposalId) - 1);
    _mintGovAndSupplyToAave(_who, _voteWeightB);

    vm.prank(_who);
    aToken.expressVote(_proposalId, _supportType);

    // The internal proposal vote weight should not reflect the new deposit weight.
    (uint256 _againstVotesExpressed, uint256 _forVotesExpressed, uint256 _abstainVotesExpressed) =
      aToken.proposalVotes(_proposalId);
    assertEq(_forVotesExpressed, _supportType == uint8(VoteType.For) ? _voteWeightA : 0);
    assertEq(_againstVotesExpressed, _supportType == uint8(VoteType.Against) ? _voteWeightA : 0);
    assertEq(_abstainVotesExpressed, _supportType == uint8(VoteType.Abstain) ? _voteWeightA : 0);

    // Submit votes on behalf of the pool.
    aToken.castVote(_proposalId);

    // Votes cast should likewise reflect only the earlier balance.
    (uint256 _againstVotes, uint256 _forVotes, uint256 _abstainVotes) =
      governor.proposalVotes(_proposalId);
    assertEq(_forVotes, _supportType == uint8(VoteType.For) ? _voteWeightA : 0);
    assertEq(_againstVotes, _supportType == uint8(VoteType.Against) ? _voteWeightA : 0);
    assertEq(_abstainVotes, _supportType == uint8(VoteType.Abstain) ? _voteWeightA : 0);
  }

  function _testMultipleUsersCanCastVotes(
    address _userA,
    address _userB,
    uint256 _voteWeightA,
    uint256 _voteWeightB
  ) private {
    // Deposit some funds.
    _mintGovAndSupplyToAave(_userA, _voteWeightA);
    _mintGovAndSupplyToAave(_userB, _voteWeightB);

    // Create the proposal.
    uint256 _proposalId = _createAndSubmitProposal();

    // Users should now be able to express their votes on the proposal.
    vm.prank(_userA);
    aToken.expressVote(_proposalId, uint8(VoteType.Against));
    vm.prank(_userB);
    aToken.expressVote(_proposalId, uint8(VoteType.Abstain));

    (uint256 _againstVotesExpressed, uint256 _forVotesExpressed, uint256 _abstainVotesExpressed) =
      aToken.proposalVotes(_proposalId);
    assertEq(_forVotesExpressed, 0);
    assertEq(_againstVotesExpressed, _voteWeightA);
    assertEq(_abstainVotesExpressed, _voteWeightB);

    // The governor should have not recieved any votes yet.
    (uint256 _againstVotes, uint256 _forVotes, uint256 _abstainVotes) =
      governor.proposalVotes(_proposalId);
    assertEq(_forVotes, 0);
    assertEq(_againstVotes, 0);
    assertEq(_abstainVotes, 0);

    // Submit votes on behalf of the pool.
    aToken.castVote(_proposalId);

    // Governor should now record votes for the pool.
    (_againstVotes, _forVotes, _abstainVotes) = governor.proposalVotes(_proposalId);
    assertEq(_forVotes, 0);
    assertEq(_againstVotes, _voteWeightA);
    assertEq(_abstainVotes, _voteWeightB);
  }

  function _testUserCanMakeThePoolCastVotesImmediatelyAfterVoting(
    address _who,
    uint256 _voteWeight,
    uint8 _supportType
  ) private {
    // Deposit some funds.
    _mintGovAndSupplyToAave(_who, _voteWeight);

    // Create the proposal.
    uint256 _proposalId = _createAndSubmitProposal();

    // Express vote.
    vm.prank(_who);
    aToken.expressVote(_proposalId, _supportType);

    // Try to submit votes on behalf of the pool.
    aToken.castVote(_proposalId);
  }

  struct VoteWeightIsScaledVars {
    address voterA;
    address voterB;
    address borrower;
    uint256 voteWeightA;
    uint256 voteWeightB;
    uint256 borrowerAssets;
    uint8 supportTypeA;
    uint8 supportTypeB;
  }

  function _testVoteWeightIsScaledBasedOnPoolBalance(VoteWeightIsScaledVars memory _vars) private {
    // This would be a vm.assume if we could do fuzz tests.
    assertLt(_vars.voteWeightA + _vars.voteWeightB, type(uint128).max);

    // Deposit some funds.
    _mintGovAndSupplyToAave(_vars.voterA, _vars.voteWeightA);
    _mintGovAndSupplyToAave(_vars.voterB, _vars.voteWeightB);
    uint256 _initGovBalance = govToken.balanceOf(address(aToken));

    // Borrow GOV from the pool, decreasing its token balance.
    deal(weth, _vars.borrower, _vars.borrowerAssets);
    vm.startPrank(_vars.borrower);
    ERC20(weth).approve(address(pool), type(uint256).max);
    pool.supply(weth, _vars.borrowerAssets, _vars.borrower, 0);
    // Borrow GOV against WETH
    pool.borrow(
      address(govToken),
      (_vars.voteWeightA + _vars.voteWeightB) / 7, // amount of GOV to borrow
      uint256(DataTypes.InterestRateMode.STABLE), // interestRateMode
      0, // referralCode
      _vars.borrower // onBehalfOf
    );
    assertLt(govToken.balanceOf(address(aToken)), _initGovBalance);
    govToken.delegate(_vars.borrower);
    vm.stopPrank();

    // Create the proposal.
    uint256 _proposalId = _createAndSubmitProposal();

    // Jump ahead to the proposal snapshot to lock in the pool's balance.
    vm.roll(governor.proposalSnapshot(_proposalId) + 1);
    uint256 _expectedVotingWeight = govToken.balanceOf(address(aToken));
    assert(_expectedVotingWeight < _initGovBalance);

    // A+B express votes
    vm.prank(_vars.voterA);
    aToken.expressVote(_proposalId, _vars.supportTypeA);
    vm.prank(_vars.voterB);
    aToken.expressVote(_proposalId, _vars.supportTypeB);

    // Submit votes on behalf of the pool.
    aToken.castVote(_proposalId);

    // Vote should be cast as a percentage of the depositer's expressed types, since
    // the actual weight is different from the deposit weight.
    (uint256 _againstVotes, uint256 _forVotes, uint256 _abstainVotes) =
      governor.proposalVotes(_proposalId);

    // These can differ because votes are rounded.
    assertApproxEqAbs(_againstVotes + _forVotes + _abstainVotes, _expectedVotingWeight, 1);

    // forgefmt: disable-start
    if (_vars.supportTypeA == _vars.supportTypeB) {
      assertEq(_forVotes, _vars.supportTypeA == uint8(VoteType.For) ? _expectedVotingWeight : 0);
      assertEq(_againstVotes, _vars.supportTypeA == uint8(VoteType.Against) ? _expectedVotingWeight : 0);
      assertEq(_abstainVotes, _vars.supportTypeA == uint8(VoteType.Abstain) ? _expectedVotingWeight : 0);
    } else {
      uint256 _expectedVotingWeightA = (_vars.voteWeightA * _expectedVotingWeight) / _initGovBalance;
      uint256 _expectedVotingWeightB = (_vars.voteWeightB * _expectedVotingWeight) / _initGovBalance;

      // We assert the weight is within a range of 1 because scaled weights are sometimes floored.
      if (_vars.supportTypeA == uint8(VoteType.For)) assertApproxEqAbs(_forVotes, _expectedVotingWeightA, 1);
      if (_vars.supportTypeB == uint8(VoteType.For)) assertApproxEqAbs(_forVotes, _expectedVotingWeightB, 1);
      if (_vars.supportTypeA == uint8(VoteType.Against)) assertApproxEqAbs(_againstVotes, _expectedVotingWeightA, 1);
      if (_vars.supportTypeB == uint8(VoteType.Against)) assertApproxEqAbs(_againstVotes, _expectedVotingWeightB, 1);
      if (_vars.supportTypeA == uint8(VoteType.Abstain)) assertApproxEqAbs(_abstainVotes, _expectedVotingWeightA, 1);
      if (_vars.supportTypeB == uint8(VoteType.Abstain)) assertApproxEqAbs(_abstainVotes, _expectedVotingWeightB, 1);
    }
    // forgefmt: disable-end

    // The borrower should also be able to submit votes!
    vm.prank(_vars.borrower);
    governor.castVoteWithReasonAndParams(
      _proposalId,
      uint8(VoteType.For),
      "Vote from the person that borrowed Gov from Aave",
      new bytes(0) // Vote nominally so that all of the borrower's weight is used.
    );

    (_againstVotes, _forVotes, _abstainVotes) = governor.proposalVotes(_proposalId);
    // The summed votes should now ~equal the amount of Gov initially supplied,
    // since the borrower also voted. There can be off-by-one errors because
    // the aToken rounds vote weights down before casting, but the total voting
    // weight expressed should be constrained by the amount of govToken injected into
    // the system. This ensures there's no double counting possible.
    assertApproxEqAbs(
      _initGovBalance,
      _againstVotes + _forVotes + _abstainVotes,
      1,
      "the number of votes cast does not match the amount of gov minted"
    );
  }

  struct VotingWeightIsAbandonedVars {
    address voterA;
    address voterB;
    address borrower;
    uint256 voteWeightA;
    uint256 voteWeightB;
    uint256 borrowerAssets;
    uint8 supportTypeA;
  }

  function _testVotingWeightIsAbandonedIfSomeoneDoesntExpress(
    VotingWeightIsAbandonedVars memory _vars
  ) private {
    // This would be a vm.assume if we could do fuzz tests.
    assertLt(_vars.voteWeightA + _vars.voteWeightB, type(uint128).max);

    // Deposit some funds.
    _mintGovAndSupplyToAave(_vars.voterA, _vars.voteWeightA);
    _mintGovAndSupplyToAave(_vars.voterB, _vars.voteWeightB);
    uint256 _initGovBalance = govToken.balanceOf(address(aToken));

    // Borrow GOV from the pool, decreasing its token balance.
    deal(weth, _vars.borrower, _vars.borrowerAssets);
    vm.startPrank(_vars.borrower);
    ERC20(weth).approve(address(pool), type(uint256).max);
    pool.supply(weth, _vars.borrowerAssets, _vars.borrower, 0);
    // Borrow GOV against WETH
    pool.borrow(
      address(govToken),
      (_vars.voteWeightA + _vars.voteWeightB) / 5, // amount of GOV to borrow
      uint256(DataTypes.InterestRateMode.STABLE), // interestRateMode
      0, // referralCode
      _vars.borrower // onBehalfOf
    );
    assertLt(govToken.balanceOf(address(aToken)), _initGovBalance);
    vm.stopPrank();

    // Create the proposal.
    uint256 _proposalId = _createAndSubmitProposal();

    // Jump ahead to the proposal snapshot to lock in the pool's balance.
    vm.roll(governor.proposalSnapshot(_proposalId) + 1);
    uint256 _totalPossibleVotingWeight = govToken.balanceOf(address(aToken));

    uint256 _fullVotingWeight = govToken.balanceOf(address(aToken));
    assert(_fullVotingWeight < _initGovBalance);
    uint256 _borrowedGov = govToken.balanceOf(address(_vars.borrower));
    assertEq(
      _fullVotingWeight,
      _vars.voteWeightA + _vars.voteWeightB - _borrowedGov,
      "voting weight doesn't match calculated value"
    );

    // Only user A expresses a vote.
    vm.prank(_vars.voterA);
    aToken.expressVote(_proposalId, _vars.supportTypeA);

    // Submit votes on behalf of the pool.
    aToken.castVote(_proposalId);

    // Vote should be cast as a percentage of the depositer's expressed types, since
    // the actual weight is different from the deposit weight.
    (uint256 _againstVotes, uint256 _forVotes, uint256 _abstainVotes) =
      governor.proposalVotes(_proposalId);

    uint256 _expectedVotingWeightA = (_vars.voteWeightA * _fullVotingWeight) / _initGovBalance;
    uint256 _expectedVotingWeightB = (_vars.voteWeightB * _fullVotingWeight) / _initGovBalance;

    // The pool *could* have voted with this much weight.
    assertApproxEqAbs(
      _totalPossibleVotingWeight, _expectedVotingWeightA + _expectedVotingWeightB, 1
    );

    // Actually, though, the pool did not vote with all of the weight it could have.
    // VoterB's votes were never cast because he/she did not express his/her preference.
    assertApproxEqAbs(
      _againstVotes + _forVotes + _abstainVotes, // The total actual weight.
      _expectedVotingWeightA, // VoterB's weight has been abandoned, only A's is counted.
      1
    );

    // forgefmt: disable-start
    // We assert the weight is within a range of 1 because scaled weights are sometimes floored.
    if (_vars.supportTypeA == uint8(VoteType.For)) assertApproxEqAbs(_forVotes, _expectedVotingWeightA, 1);
    if (_vars.supportTypeA == uint8(VoteType.Against)) assertApproxEqAbs(_againstVotes, _expectedVotingWeightA, 1);
    if (_vars.supportTypeA == uint8(VoteType.Abstain)) assertApproxEqAbs(_abstainVotes, _expectedVotingWeightA, 1);
    // forgefmt: disable-end
  }

  function _testVotingWeightIsUnaffectedByDepositsAfterProposal(
    address _voterA,
    address _voterB,
    uint256 _voteWeightA,
    uint256 _voteWeightB,
    uint8 _supportTypeA
  ) private {
    // This would be a vm.assume if we could do fuzz tests.
    assertLt(_voteWeightA + _voteWeightB, type(uint128).max);

    // Mint and deposit for just userA.
    _mintGovAndSupplyToAave(_voterA, _voteWeightA);
    uint256 _initGovBalance = govToken.balanceOf(address(aToken));

    // Create the proposal.
    uint256 _proposalId = _createAndSubmitProposal();

    // Jump ahead to the proposal snapshot to lock in the pool's balance.
    vm.roll(governor.proposalSnapshot(_proposalId) + 1);

    // Now mint and deposit for userB.
    _mintGovAndSupplyToAave(_voterB, _voteWeightB);

    uint256 _fullVotingWeight = govToken.balanceOf(address(aToken));
    assert(_fullVotingWeight > _initGovBalance);
    assertEq(_fullVotingWeight, _voteWeightA + _voteWeightB);

    // Only user A expresses a vote.
    vm.prank(_voterA);
    aToken.expressVote(_proposalId, _supportTypeA);

    // Submit votes on behalf of the pool.
    aToken.castVote(_proposalId);

    (uint256 _againstVotes, uint256 _forVotes, uint256 _abstainVotes) =
      governor.proposalVotes(_proposalId);

    if (_supportTypeA == uint8(VoteType.For)) assertEq(_forVotes, _voteWeightA);
    if (_supportTypeA == uint8(VoteType.Against)) assertEq(_againstVotes, _voteWeightA);
    if (_supportTypeA == uint8(VoteType.Abstain)) assertEq(_abstainVotes, _voteWeightA);
  }

  function _testVotingWeightDoesNotGoDownWhenUsersBorrow(
    address _who,
    uint256 _voteWeight,
    uint256 _borrowAmount,
    uint8 _supportType
  ) private {
    // Mint and deposit.
    _mintGovAndSupplyToAave(_who, _voteWeight);

    // Borrow DAI against GOV position.
    vm.prank(_who);
    pool.borrow(
      dai,
      _borrowAmount,
      uint256(DataTypes.InterestRateMode.STABLE), // interestRateMode
      0, // referralCode
      _who // onBehalfOf
    );

    // Create the proposal.
    uint256 _proposalId = _createAndSubmitProposal();

    // Express voting preference.
    vm.prank(_who);
    aToken.expressVote(_proposalId, _supportType);

    // Submit votes on behalf of the pool.
    aToken.castVote(_proposalId);

    (uint256 _againstVotes, uint256 _forVotes, uint256 _abstainVotes) =
      governor.proposalVotes(_proposalId);

    // Actual voting weight should match the initial deposit.
    if (_supportType == uint8(VoteType.For)) assertEq(_forVotes, _voteWeight);
    if (_supportType == uint8(VoteType.Against)) assertEq(_againstVotes, _voteWeight);
    if (_supportType == uint8(VoteType.Abstain)) assertEq(_abstainVotes, _voteWeight);
  }

  function _testVotingWeightGoesDownWhenUsersWithdraw(
    address _who,
    uint256 _supplyAmount,
    uint256 _withdrawAmount,
    uint8 _supportType
  ) private {
    // Mint and deposit.
    _mintGovAndSupplyToAave(_who, _supplyAmount);

    // Immediately withdraw.
    vm.prank(_who);
    pool.withdraw(address(govToken), _withdrawAmount, _who);
    if (_withdrawAmount == type(uint256).max) {
      assertEq(aToken.balanceOf(_who), 0);
    } else {
      assertEq(aToken.balanceOf(_who), _supplyAmount - _withdrawAmount);

      // Have someone else immediately supply the withdrawn amount to make sure
      // our accounting is handling the change in internal deposit balances.
      _mintGovAndSupplyToAave(address(this), _withdrawAmount);
    }

    // Create the proposal.
    uint256 _proposalId = _createAndSubmitProposal();

    // Express a voting preference.
    if (_withdrawAmount == type(uint256).max) vm.expectRevert(bytes("no weight"));
    vm.prank(_who);
    aToken.expressVote(_proposalId, _supportType);
    if (_withdrawAmount == type(uint256).max) return; // Nothing left to test.

    // Submit votes on behalf of the pool.
    aToken.castVote(_proposalId);

    (uint256 _againstVotes, uint256 _forVotes, uint256 _abstainVotes) =
      governor.proposalVotes(_proposalId);

    uint256 _expectedVoteWeight = _supplyAmount - _withdrawAmount;
    if (_supportType == uint8(VoteType.For)) assertEq(_forVotes, _expectedVoteWeight);
    if (_supportType == uint8(VoteType.Against)) assertEq(_againstVotes, _expectedVoteWeight);
    if (_supportType == uint8(VoteType.Abstain)) assertEq(_abstainVotes, _expectedVoteWeight);
  }

  function _testVotingWeightWorksWithRebasing(address _userA, address _userB, uint256 _supplyAmount)
    private
  {
    _initiateRebasing();

    // Someone supplies GOV to Aave.
    _mintGovAndSupplyToAave(_userA, _supplyAmount);
    uint256 _initATokenBalanceA = aToken.balanceOf(_userA);

    // Let those aGovTokens rebase \o/.
    vm.roll(block.number + 365 * 24 * 60 * 12); // 12 blocks per min for a year.
    vm.warp(block.timestamp + 365 days);
    assertGt(aToken.balanceOf(_userA), _initATokenBalanceA, "aToken did not rebase");

    // Someone else supplies the same amount of GOV to Aave.
    _mintGovAndSupplyToAave(_userB, _supplyAmount);
    assertGt(
      aToken.balanceOf(_userA),
      aToken.balanceOf(_userB),
      "userA does not have more aTokens than userB"
    );

    // Create the proposal.
    uint256 _proposalId = _createAndSubmitProposal();

    // Express voting preferences.
    vm.prank(_userA);
    aToken.expressVote(_proposalId, uint8(VoteType.For));
    vm.prank(_userB);
    aToken.expressVote(_proposalId, uint8(VoteType.Against));

    // Submit votes on behalf of the pool.
    aToken.castVote(_proposalId);

    (uint256 _againstVotes, uint256 _forVotes, /*uint256 _abstainVotes */ ) =
      governor.proposalVotes(_proposalId);

    // userA's vote *should* have beaten userB's.
    assertGt(_forVotes, _againstVotes, "rebasing isn't reflected in vote weight");
  }

  function _testCanExpressVoteAfterVotesHaveBeenCast(
    address _userA,
    address _userB,
    uint8 _supportType
  ) private {
    // Deposit some funds.
    _mintGovAndSupplyToAave(_userA, 1 ether);
    _mintGovAndSupplyToAave(_userB, 1 ether);

    // Create the proposal.
    uint256 _proposalId = _createAndSubmitProposal();

    // Express voting preference on the proposal.
    vm.prank(_userA);
    aToken.expressVote(_proposalId, _supportType);

    // submit votes on behalf of the pool
    aToken.castVote(_proposalId);

    // _userB should be able to express his/her vote on the proposal even though
    // the vote was cast.
    vm.prank(_userB);
    aToken.expressVote(_proposalId, _supportType);
  }

  function _testCannotCastVoteWithoutVotesExpressed(address _who, uint8 _supportType) private {
    // Deposit some funds.
    _mintGovAndSupplyToAave(_who, 1 ether);

    // Create the proposal.
    uint256 _proposalId = _createAndSubmitProposal();

    // Try to submit votes on behalf of the pool. It should fail.
    vm.expectRevert(bytes("no votes expressed"));
    aToken.castVote(_proposalId);

    // Express voting preference on the proposal.
    vm.prank(_who);
    aToken.expressVote(_proposalId, _supportType);

    // Now votes should be castable.
    aToken.castVote(_proposalId);
  }

  function _testCastVoteWithTransferredATokens(
    address _userA,
    address _userB,
    uint256 _weight,
    uint256 _transferAmount,
    uint8 _supportTypeA,
    uint8 _supportTypeB
  ) private {
    // Deposit some funds.
    _mintGovAndSupplyToAave(_userA, _weight);
    assertEq(aToken.balanceOf(_userA), _weight);
    assertEq(aToken.balanceOf(_userB), 0);

    // Transfer all aTokens from userA to userB.
    vm.prank(_userA);
    aToken.transfer(_userB, _transferAmount);
    assertEq(aToken.balanceOf(_userA), _weight - _transferAmount);
    assertEq(aToken.balanceOf(_userB), _transferAmount);

    // Create the proposal.
    uint256 _proposalId = _createAndSubmitProposal();

    // Express voting preferences.
    if (aToken.balanceOf(_userA) == 0) vm.expectRevert(bytes("no weight"));
    vm.prank(_userA);
    aToken.expressVote(_proposalId, _supportTypeA);
    vm.prank(_userB);
    aToken.expressVote(_proposalId, _supportTypeB);

    // Submit votes on behalf of the pool.
    aToken.castVote(_proposalId);

    (uint256 _againstVotes, uint256 _forVotes, uint256 _abstainVotes) =
      governor.proposalVotes(_proposalId);

    if (_supportTypeA == _supportTypeB) {
      if (_supportTypeA == uint8(VoteType.For)) assertEq(_forVotes, _weight);
      if (_supportTypeA == uint8(VoteType.Against)) assertEq(_againstVotes, _weight);
      if (_supportTypeA == uint8(VoteType.Abstain)) assertEq(_abstainVotes, _weight);
    } else {
      // forgefmt: disable-start
      if (_supportTypeA == uint8(VoteType.For)) assertEq(_forVotes, _weight - _transferAmount);
      if (_supportTypeA == uint8(VoteType.Against)) assertEq(_againstVotes, _weight - _transferAmount);
      if (_supportTypeA == uint8(VoteType.Abstain)) assertEq(_abstainVotes, _weight - _transferAmount);
      if (_supportTypeB == uint8(VoteType.For)) assertEq(_forVotes, _transferAmount);
      if (_supportTypeB == uint8(VoteType.Against)) assertEq(_againstVotes, _transferAmount);
      if (_supportTypeB == uint8(VoteType.Abstain)) assertEq(_abstainVotes, _transferAmount);
      // forgefmt: disable-end
    }
  }

  // TODO this should really just be a fuzz test.
  function _testVotesCanBeCastIncrementally(
    address _userA,
    address _userB,
    uint8 _supportTypeA,
    uint8 _supportTypeB
  ) private {
    uint256 _weightA = 1 ether;
    uint256 _weightB = 3 ether;

    // Deposit some funds.
    _mintGovAndSupplyToAave(_userA, _weightA);
    _mintGovAndSupplyToAave(_userB, _weightB);

    // Create the proposal.
    uint256 _proposalId = _createAndSubmitProposal();

    // UserA expresses a voting preference on the proposal.
    vm.prank(_userA);
    aToken.expressVote(_proposalId, _supportTypeA);

    // Submit votes on behalf of the pool.
    aToken.castVote(_proposalId);

    (uint256 _againstVotes, uint256 _forVotes, uint256 _abstainVotes) =
      governor.proposalVotes(_proposalId);

    uint256 _expectedForVotes;
    uint256 _expectedAgainstVotes;
    uint256 _expectedAbstainVotes;

    if (_supportTypeA == uint256(VoteType.For)) _expectedForVotes += _weightA;
    if (_supportTypeA == uint256(VoteType.Against)) _expectedAgainstVotes += _weightA;
    if (_supportTypeA == uint256(VoteType.Abstain)) _expectedAbstainVotes += _weightA;

    assertEq(_forVotes, _expectedForVotes);
    assertEq(_againstVotes, _expectedAgainstVotes);
    assertEq(_abstainVotes, _expectedAbstainVotes);

    // UserA should not be able to express votes again.
    vm.prank(_userA);
    vm.expectRevert("already voted");
    aToken.expressVote(_proposalId, _supportTypeA);

    // UserB expresses a voting preference on the proposal.
    vm.prank(_userB);
    aToken.expressVote(_proposalId, _supportTypeB);

    // Submit votes on behalf of the pool.
    aToken.castVote(_proposalId);

    (_againstVotes, _forVotes, _abstainVotes) = governor.proposalVotes(_proposalId);

    if (_supportTypeB == uint256(VoteType.For)) _expectedForVotes += _weightB;
    if (_supportTypeB == uint256(VoteType.Against)) _expectedAgainstVotes += _weightB;
    if (_supportTypeB == uint256(VoteType.Abstain)) _expectedAbstainVotes += _weightB;

    assertEq(_forVotes, _expectedForVotes);
    assertEq(_againstVotes, _expectedAgainstVotes);
    assertEq(_abstainVotes, _expectedAbstainVotes);
  }
}

contract GetPastRawBalanceTest is AaveAtokenForkTest {
  function test_GetPastStoredBalanceCorrectlyReadsCheckpoints() public {
    _initiateRebasing();

    address _who = makeAddr("GetPastStoredBalanceCorrectlyReadsCheckpoints _who");
    uint256 _amountA = 42 ether;
    uint256 _amountB = 3 ether;

    uint256[] memory _rawBalances = new uint256[](3);

    // Deposit.
    _mintGovAndSupplyToAave(_who, _amountA);
    _rawBalances[0] = aToken.exposed_RawBalanceOf(_who);

    // It's important that this be greater than a ray, since Aave uses this
    // index when determining the raw stored balance. If it were a ray, the
    // stored balance would just equal the supplied amount and this test would
    // be less meaningful.
    assertGt(
      pool.getReserveData(address(govToken)).liquidityIndex,
      1e27,
      "liquidityIndex has not changed, is rebasing occuring?"
    );

    // The supplied amount should be less than the raw balance, which was
    // scaled down by the reserve liquidity index.
    assertLt(_rawBalances[0], _amountA, "supply wasn't reduced by liquidityIndex");

    // Advance the clock.
    uint256 _blocksJumped = 42;
    vm.roll(block.number + _blocksJumped);
    vm.warp(block.timestamp + 42 days);

    // getPastRawBalance should match the initial raw balance.
    assertEq(
      aToken.getPastRawBalance(_who, block.number - _blocksJumped + 1),
      _rawBalances[0],
      "getPastRawBalance does not match the initial raw balance"
    );

    // getPastRawBalance should be able to give us the raw balance at an
    // intermediate point.
    assertEq(
      aToken.getPastRawBalance(
        _who,
        block.number - (_blocksJumped / 3) // 1/3 is just an arbitrary point.
      ),
      _rawBalances[0]
    );

    // Deposit again to make things more complicated.
    _mintGovAndSupplyToAave(_who, _amountB);
    _rawBalances[1] = aToken.exposed_RawBalanceOf(_who);

    // Advance the clock.
    uint256 _blocksJumpedSecondTime = 100;
    vm.roll(block.number + _blocksJumpedSecondTime);
    vm.warp(block.timestamp + 100 days);

    // Rebasing should not affect the raw balance.
    assertGt(_rawBalances[1], _rawBalances[0], "raw balance did not increase");

    // getPastRawBalance should match historical balances.
    assertEq(
      aToken.getPastRawBalance(_who, block.number - _blocksJumped - _blocksJumpedSecondTime + 1),
      _rawBalances[0],
      "getPastRawBalance did not match original raw balance"
    );
    assertEq(
      aToken.getPastRawBalance(_who, block.number - _blocksJumpedSecondTime + 1),
      _rawBalances[1],
      "getPastRawBalance did not match raw balance after second supply"
    );
    // getPastRawBalance should be able to give us the raw balance at intermediate points.
    assertEq(
      aToken.getPastRawBalance(_who, block.number - _blocksJumpedSecondTime / 3), // random point
      _rawBalances[1]
    );
    assertEq(
      aToken.getPastRawBalance(_who, block.number - _blocksJumpedSecondTime / 3),
      aToken.getPastRawBalance(_who, block.number - 1)
    );

    // Withdrawals should be reflected in getPastRawBalance.
    vm.startPrank(_who);
    pool.withdraw(
      address(govToken),
      aToken.balanceOf(_who) / 3, // Withdraw 1/3rd of balance.
      _who
    );
    vm.stopPrank();

    // Advance the clock
    uint256 _blocksJumpedThirdTime = 10;
    vm.roll(block.number + _blocksJumpedThirdTime);
    vm.warp(block.timestamp + 10 days);

    assertEq(
      aToken.getPastRawBalance(_who, block.number - _blocksJumpedThirdTime),
      aToken.exposed_RawBalanceOf(_who)
    );
    assertEq(aToken.getPastRawBalance(_who, block.number - 1), aToken.exposed_RawBalanceOf(_who));
    assertGt(
      _rawBalances[1], // The raw balance pre-withdrawal.
      aToken.getPastRawBalance(_who, block.number - _blocksJumpedThirdTime)
    );
  }

  function test_GetPastStoredBalanceHandlesTransfers() public {
    _initiateRebasing();

    address _userA = makeAddr("GetPastStoredBalanceHandlesTransfers _userA");
    address _userB = makeAddr("GetPastStoredBalanceHandlesTransfers _userB");
    uint256 _amount = 4242 ether;

    // Deposit.
    _mintGovAndSupplyToAave(_userA, _amount);
    uint256 _initRawBalanceUserA = aToken.exposed_RawBalanceOf(_userA);

    // Advance the clock so that we checkpoint and let some rebasing happen.
    vm.roll(block.number + 100);
    vm.warp(block.timestamp + 100 days);

    // Get the rebased balances.
    uint256 _initBalanceUserA = aToken.balanceOf(_userA);
    uint256 _initBalanceUserB = aToken.balanceOf(_userB);
    assertGt(_initBalanceUserA, 0);
    assertEq(_initBalanceUserB, 0);

    // Transfer aTokens to userB.
    vm.prank(_userA);
    aToken.transfer(_userB, _initBalanceUserA / 3);
    assertEq(aToken.balanceOf(_userA), 2 * _initBalanceUserA / 3);
    assertEq(aToken.balanceOf(_userB), 1 * _initBalanceUserA / 3);

    // Advance the clock so that we checkpoint.
    vm.roll(block.number + 1);
    vm.warp(block.timestamp + 1 days);

    // Confirm voting weight has shifted.
    assertEq(
      aToken.getPastRawBalance(_userA, block.number - 1),
      2 * _initRawBalanceUserA / 3 // 2/3rds of A's initial balance
    );
    assertEq(
      aToken.getPastRawBalance(_userB, block.number - 1),
      1 * _initRawBalanceUserA / 3 // 1/3rd of A's initial balance
    );
  }

  function test_GetPastStoredBalanceHandlesTransferFrom() public {
    _initiateRebasing();

    address _userA = makeAddr("GetPastStoredBalanceHandlesTransfers _userA");
    address _userB = makeAddr("GetPastStoredBalanceHandlesTransfers _userB");
    uint256 _amount = 4242 ether;

    // Deposit.
    _mintGovAndSupplyToAave(_userA, _amount);
    uint256 _initRawBalanceUserA = aToken.exposed_RawBalanceOf(_userA);

    // Advance the clock so that we checkpoint and let some rebasing happen.
    vm.roll(block.number + 100);
    vm.warp(block.timestamp + 100 days);

    // Get the rebased balances.
    uint256 _initBalanceUserA = aToken.balanceOf(_userA);
    uint256 _initBalanceUserB = aToken.balanceOf(_userB);
    assertGt(_initBalanceUserA, 0);
    assertEq(_initBalanceUserB, 0);

    // Transfer aTokens to userB.
    vm.prank(_userA);
    aToken.approve(address(this), type(uint256).max);
    aToken.transferFrom(_userA, _userB, _initBalanceUserA / 3);
    assertEq(aToken.balanceOf(_userA), 2 * _initBalanceUserA / 3);
    assertEq(aToken.balanceOf(_userB), _initBalanceUserA / 3);

    // Advance the clock so that we checkpoint.
    vm.roll(block.number + 1);
    vm.warp(block.timestamp + 1 days);

    // Confirm voting weight has shifted.
    assertEq(
      aToken.getPastRawBalance(_userA, block.number - 1),
      2 * _initRawBalanceUserA / 3 // 2/3rds of A's initial balance
    );
    assertEq(
      aToken.getPastRawBalance(_userB, block.number - 1),
      1 * _initRawBalanceUserA / 3 // 1/3rd of A's initial balance
    );
  }

  function test_MintToTreasuryIsCheckpointed() public {
    _initiateRebasing();

    // Advance the clock so that the treasury earns some interest.
    vm.roll(block.number + 100);
    vm.warp(block.timestamp + 100 days);

    address _treasury = aToken.exposed_Treasury();
    uint256 _initTreasuryBalance = aToken.balanceOf(_treasury);

    // Repay the borrow and give the treasury more interest.
    ERC20(govToken).approve(address(pool), type(uint256).max);
    // Give the user some more gov to pay the interest on the borrow.
    govToken.exposed_mint(address(this), 10 ether);
    pool.repay(
      address(govToken),
      type(uint256).max, // pay entire debt.
      uint256(DataTypes.InterestRateMode.STABLE), // interestRateMode
      address(this)
    );

    address[] memory _assetsForMintToTreasury = new address[](1);
    _assetsForMintToTreasury[0] = address(govToken);
    pool.mintToTreasury(_assetsForMintToTreasury);

    // Advance the block so that we can query checkpoints.
    vm.roll(block.number + 1);
    vm.warp(block.timestamp + 1 days);

    assertGt(aToken.balanceOf(_treasury), _initTreasuryBalance);

    assertGt(aToken.getPastRawBalance(_treasury, block.number - 1), 0);
  }
}

contract GetPastTotalBalanceTest is AaveAtokenForkTest {
  function test_GetPastTotalBalanceIncreasesOnDeposit() public {
    _initiateRebasing();
    assertEq(aToken.getPastTotalBalance(block.number - 1), INITIAL_REBASING_DEPOSIT);

    address _userA = makeAddr("GetPastTotalBalanceIncreasesOnDeposit _userA");
    address _userB = makeAddr("GetPastTotalBalanceIncreasesOnDeposit _userB");
    uint256 _amountA = 4242 ether;
    uint256 _amountB = 123 ether;

    // Deposit.
    _mintGovAndSupplyToAave(_userA, _amountA);
    uint256 _rawBalanceA = aToken.exposed_RawBalanceOf(_userA);

    // Advance the clock so that we checkpoint and let some rebasing happen.
    vm.roll(block.number + 100);
    vm.warp(block.timestamp + 100 days);

    // forgefmt: disable-start
    assertEq(aToken.getPastTotalBalance(block.number - 101), INITIAL_REBASING_DEPOSIT);
    assertEq(aToken.getPastTotalBalance(block.number - 100), INITIAL_REBASING_DEPOSIT + _rawBalanceA);
    assertEq(aToken.getPastTotalBalance(block.number - 10), INITIAL_REBASING_DEPOSIT + _rawBalanceA);
    assertEq(aToken.getPastTotalBalance(block.number - 1), INITIAL_REBASING_DEPOSIT + _rawBalanceA);
    // forgefmt: disable-end

    // Another user deposits.
    _mintGovAndSupplyToAave(_userB, _amountB);
    uint256 _rawBalanceB = aToken.exposed_RawBalanceOf(_userB);

    // Advance the clock to checkpoint + rebase.
    vm.roll(block.number + 100);
    vm.warp(block.timestamp + 100 days);

    // forgefmt: disable-start
    assertEq(aToken.getPastTotalBalance(block.number - 201), INITIAL_REBASING_DEPOSIT);
    assertEq(aToken.getPastTotalBalance(block.number - 120), INITIAL_REBASING_DEPOSIT + _rawBalanceA);
    assertEq(aToken.getPastTotalBalance(block.number - 20), INITIAL_REBASING_DEPOSIT + _rawBalanceA + _rawBalanceB);
    assertEq(aToken.getPastTotalBalance(block.number - 1), INITIAL_REBASING_DEPOSIT + _rawBalanceA + _rawBalanceB);
    // forgefmt: disable-end
  }

  function test_GetPastTotalBalanceDecreasesOnWithdraw() public {
    _initiateRebasing();

    address _userA = makeAddr("GetPastTotalBalanceDecreasesOnWithdraw _userA");
    uint256 _amountA = 4242 ether;

    // Deposit.
    _mintGovAndSupplyToAave(_userA, _amountA);
    uint256 _rawBalanceA = aToken.exposed_RawBalanceOf(_userA);

    // Advance the clock so that we checkpoint and let some rebasing happen.
    vm.roll(block.number + 100);
    vm.warp(block.timestamp + 100 days);

    assertEq(aToken.getPastTotalBalance(block.number - 1), INITIAL_REBASING_DEPOSIT + _rawBalanceA);

    vm.startPrank(_userA);
    uint256 _withdrawAmount = aToken.balanceOf(_userA) / 3;
    pool.withdraw(address(govToken), _withdrawAmount, _userA);
    vm.stopPrank();

    // Advance the clock so that we checkpoint and let some rebasing happen.
    vm.roll(block.number + 100);
    vm.warp(block.timestamp + 100 days);

    assertEq(
      aToken.getPastTotalBalance(block.number - 1),
      INITIAL_REBASING_DEPOSIT + aToken.exposed_RawBalanceOf(_userA)
    );

    uint256 _rawBalanceDelta = _rawBalanceA - aToken.exposed_RawBalanceOf(_userA);
    assertEq(
      aToken.getPastTotalBalance(block.number - 101) - _rawBalanceDelta,
      aToken.getPastTotalBalance(block.number - 1)
    );
  }

  function test_GetPastTotalBalanceIsUnaffectedByTransfer() public {
    _initiateRebasing();

    address _userA = makeAddr("GetPastTotalBalanceIsUnaffectedByTransfer _userA");
    address _userB = makeAddr("GetPastTotalBalanceIsUnaffectedByTransfer _userB");
    uint256 _amountA = 4242 ether;

    // Deposit.
    _mintGovAndSupplyToAave(_userA, _amountA);

    // Advance the clock so that we checkpoint and let some rebasing happen.
    vm.roll(block.number + 100);
    vm.warp(block.timestamp + 100 days);

    uint256 _totalDeposits = aToken.getPastTotalBalance(block.number - 1);

    vm.startPrank(_userA);
    aToken.transfer(_userB, aToken.balanceOf(_userA) / 2);
    vm.stopPrank();

    // Advance the clock so that we checkpoint and let some rebasing happen.
    vm.roll(block.number + 100);
    vm.warp(block.timestamp + 100 days);

    assertEq(
      aToken.getPastTotalBalance(block.number - 1),
      _totalDeposits // No change because of the transfer;
    );

    // Repeat.
    vm.startPrank(_userA);
    aToken.transfer(_userB, aToken.balanceOf(_userA));
    vm.stopPrank();

    assertEq(aToken.balanceOf(_userA), 0);

    // Advance the clock so that we checkpoint and let some rebasing happen.
    vm.roll(block.number + 100);
    vm.warp(block.timestamp + 100 days);

    assertEq(
      aToken.getPastTotalBalance(block.number - 1),
      _totalDeposits // Still no change caused by transfer.
    );
  }

  function test_GetPastTotalBalanceIsUnaffectedByBorrow() public {
    _initiateRebasing();

    address _userA = makeAddr("GetPastTotalBalanceIsUnaffectedByBorrow _userA");
    uint256 _totalDeposits = aToken.getPastTotalBalance(block.number - 1);

    // Borrow gov.
    vm.startPrank(_userA);
    deal(weth, _userA, 100 ether);
    ERC20(weth).approve(address(pool), type(uint256).max);
    pool.supply(weth, 100 ether, _userA, 0);
    pool.borrow(
      address(govToken),
      42 ether, // amount of GOV to borrow
      uint256(DataTypes.InterestRateMode.STABLE), // interestRateMode
      0, // referralCode
      _userA // onBehalfOf
    );
    assertEq(govToken.balanceOf(_userA), 42 ether);
    vm.stopPrank();

    // Advance the clock so that we checkpoint and let some rebasing happen.
    vm.roll(block.number + 100);
    vm.warp(block.timestamp + 100 days);

    assertEq(aToken.getPastTotalBalance(block.number - 1), _totalDeposits);
  }

  function test_GetPastTotalBalanceZerosOutIfAllPositionsAreUnwound() public {
    _initiateRebasing();

    uint256 _totalDeposits = aToken.getPastTotalBalance(block.number - 1);
    assertGt(_totalDeposits, 0);
    assertGt(govToken.balanceOf(address(aToken)), 0);

    // Repay the borrow that kicked off rebasing.
    ERC20(govToken).approve(address(pool), type(uint256).max);
    // Give the user some more gov to pay the interest on the borrow.
    govToken.exposed_mint(address(this), 10 ether);
    pool.repay(
      address(govToken),
      type(uint256).max, // pay entire debt.
      uint256(DataTypes.InterestRateMode.STABLE), // interestRateMode
      address(this)
    );

    // Withdraw the only balance.
    vm.startPrank(initialSupplier);
    pool.withdraw(
      address(govToken),
      type(uint256).max, // Withdraw it all.
      initialSupplier
    );

    // Advance the clock so that we checkpoint.
    vm.roll(block.number + 1);
    vm.warp(block.timestamp + 1 days);

    assertEq(
      aToken.getPastTotalBalance(block.number - 1),
      0, // Total balances should now be zero; any remaining supply belongs to the reserve.
      "getPastTotalBalance accounting is wrong"
    );
  }
}

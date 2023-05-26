// SPDX-License-Identifier: Unlicensed
pragma solidity >=0.8.10;

import {Test, console2, Vm} from "forge-std/Test.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {IVotes} from "@openzeppelin/contracts/governance/utils/IVotes.sol";

import {CometFlexVoting} from "src/CometFlexVoting.sol";
import {FractionalGovernor} from "test/FractionalGovernor.sol";
import {ProposalReceiverMock} from "test/ProposalReceiverMock.sol";
import {GovToken} from "test/GovToken.sol";

import {CometConfiguration} from "comet/CometConfiguration.sol";
import {CometMainInterface} from "comet/CometMainInterface.sol";
import {Comet} from "comet/Comet.sol";

contract CometForkTest is Test, CometConfiguration {
  uint256 forkId;

  CometFlexVoting cToken;
  // The Compound governor, not to be confused with the govToken's governance system:
  address immutable COMPOUND_GOVERNOR = 0x6d903f6003cca6255D85CcA4D3B5E5146dC33925;
  GovToken govToken;
  FractionalGovernor flexVotingGovernor;
  ProposalReceiverMock proposalTarget;

  // Mainnet addresses.
  address weth = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;

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
    // Compound v3 has been deployed to mainnet.
    // https://docs.compound.finance/#networks
    //
    // This is just the most recent safe block on mainnet at the time these
    // tests were written. There is no special reason to use this block and it
    // probably can be safely updated as the chain grows. The things we
    // interract with on-chain (e.g. token addresses, governance addresses,
    // price feeds/oracles) are unlikely to change in ways that invalidate the
    // assumptions of this test suite.
    uint256 mainnetForkBlock = 17_288_576;
    forkId = vm.createSelectFork(vm.rpcUrl("mainnet"), mainnetForkBlock);

    // Deploy the GOV token.
    govToken = new GovToken();
    vm.label(address(govToken), "govToken");

    // Deploy the governor.
    flexVotingGovernor = new FractionalGovernor("Governor", IVotes(govToken));
    vm.label(address(flexVotingGovernor), "flexVotingGovernor");

    // Deploy the contract which will receive proposal calls.
    proposalTarget = new ProposalReceiverMock();
    vm.label(address(proposalTarget), "proposalTarget");

    // ========= START DEPLOY NEW COMET ========================
    //
    // These configs are all based on the cUSDCv3 token configs:
    //   https://etherscan.io/address/0xc3d688B66703497DAA19211EEdff47f25384cdc3#readProxyContract
    AssetConfig[] memory _assetConfigs = new AssetConfig[](5);
    _assetConfigs[0] = AssetConfig({
      asset: 0xc00e94Cb662C3520282E6f5717214004A7f26888, // COMP
      priceFeed: 0xdbd020CAeF83eFd542f4De03e3cF0C28A4428bd5,
      decimals: 18,
      borrowCollateralFactor: 650_000_000_000_000_000,
      liquidateCollateralFactor: 700_000_000_000_000_000,
      liquidationFactor: 880_000_000_000_000_000,
      supplyCap: 900_000_000_000_000_000_000_000
    });
    _assetConfigs[1] = AssetConfig({
      asset: 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599, // WBTC
      priceFeed: 0xF4030086522a5bEEa4988F8cA5B36dbC97BeE88c,
      decimals: 8,
      borrowCollateralFactor: 700_000_000_000_000_000,
      liquidateCollateralFactor: 770_000_000_000_000_000,
      liquidationFactor: 950_000_000_000_000_000,
      supplyCap: 1_200_000_000_000
    });
    _assetConfigs[2] = AssetConfig({
      asset: weth,
      priceFeed: 0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419,
      decimals: 18,
      borrowCollateralFactor: 825_000_000_000_000_000,
      liquidateCollateralFactor: 895_000_000_000_000_000,
      liquidationFactor: 950_000_000_000_000_000,
      supplyCap: 350_000_000_000_000_000_000_000
    });
    _assetConfigs[3] = AssetConfig({
      asset: 0x1f9840a85d5aF5bf1D1762F925BDADdC4201F984,
      priceFeed: 0x553303d460EE0afB37EdFf9bE42922D8FF63220e,
      decimals: 18,
      borrowCollateralFactor: 750_000_000_000_000_000,
      liquidateCollateralFactor: 810_000_000_000_000_000,
      liquidationFactor: 930_000_000_000_000_000,
      supplyCap: 2_300_000_000_000_000_000_000_000
    });
    _assetConfigs[4] = AssetConfig({
      asset: 0x514910771AF9Ca656af840dff83E8264EcF986CA,
      priceFeed: 0x2c1d072e956AFFC0D435Cb7AC38EF18d24d9127c,
      decimals: 18,
      borrowCollateralFactor: 790_000_000_000_000_000,
      liquidateCollateralFactor: 850_000_000_000_000_000,
      liquidationFactor: 930_000_000_000_000_000,
      supplyCap: 1_250_000_000_000_000_000_000_000
    });
    address _chainlinkUsdcUsdFeed = 0x8fFfFfd4AfB6115b954Bd326cbe7B4BA576818f6;
    Configuration memory _config = Configuration({
      governor: COMPOUND_GOVERNOR,
      pauseGuardian: 0xbbf3f1421D886E9b2c5D716B5192aC998af2012c,
      baseToken: address(govToken),
      baseTokenPriceFeed: _chainlinkUsdcUsdFeed,
      extensionDelegate: 0x285617313887d43256F852cAE0Ee4de4b68D45B0,
      supplyKink: 800_000_000_000_000_000,
      supplyPerYearInterestRateSlopeLow: 1_030_568_239 * 60 * 60 * 24 * 365,
      supplyPerYearInterestRateSlopeHigh: 12_683_916_793 * 60 * 60 * 24 * 365,
      supplyPerYearInterestRateBase: 0,
      borrowKink: 800_000_000_000_000_000,
      borrowPerYearInterestRateSlopeLow: 1_109_842_719 * 60 * 60 * 24 * 365,
      borrowPerYearInterestRateSlopeHigh: 7_927_447_995 * 60 * 60 * 24 * 365,
      borrowPerYearInterestRateBase: 475_646_879 * 60 * 60 * 24 * 365,
      storeFrontPriceFactor: 600_000_000_000_000_000,
      trackingIndexScale: 1_000_000_000_000_000,
      baseTrackingSupplySpeed: 0,
      baseTrackingBorrowSpeed: 3_257_060_185_185,
      baseMinForRewards: 1_000_000_000_000,
      baseBorrowMin: 100_000_000,
      targetReserves: 5_000_000_000_000,
      assetConfigs: _assetConfigs
    });

    cToken = new CometFlexVoting(_config, address(flexVotingGovernor));

    cToken.initializeStorage();
    // ========= END DEPLOY NEW COMET ========================

    // TODO is there anything we need to do to make this an "official" Comet?
  }

  // ------------------
  // Helper functions
  // ------------------

  function mintGovAndSupplyToCompound(address _who, uint256 _govAmount) internal {
    govToken.exposed_mint(_who, _govAmount);
    vm.startPrank(_who);
    govToken.approve(address(cToken), type(uint256).max);
    cToken.supply(address(govToken), _govAmount);
    vm.stopPrank();
  }

  function createAndSubmitProposal() internal returns (uint256 proposalId) {
    // Create a dummy proposal.
    bytes memory targetCallData =
      abi.encodeWithSelector(ProposalReceiverMock.mockRecieverFunction.selector);
    address[] memory targets = new address[](1);
    uint256[] memory values = new uint256[](1);
    bytes[] memory calldatas = new bytes[](1);
    targets[0] = address(proposalTarget);
    values[0] = 0; // no ETH will be sent
    calldatas[0] = targetCallData;

    // Submit the proposal.
    //
    // The proposer is the test contract for simplicity. This works because the
    // default proposal threshold is 0, i.e. you don't have to have a govToken
    // balance in order to propose.
    proposalId = flexVotingGovernor.propose(targets, values, calldatas, "A great proposal");
    assertEq(uint256(flexVotingGovernor.state(proposalId)), uint256(ProposalState.Pending));

    // advance proposal to active state
    vm.roll(flexVotingGovernor.proposalSnapshot(proposalId) + 1);
    assertEq(
      uint256(flexVotingGovernor.state(proposalId)),
      uint256(ProposalState.Active),
      "createAndSubmitProposal: state mismatch"
    );
  }
}

contract Setup is CometForkTest {
  function testFork_CTokenDeploy() public {
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

  function testFork_CanSupplyGovToCompound() public {
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

  function testFork_CanBorrowGov() public {
    // Mint GOV and deposit into Compound.
    address _supplier = address(this);
    assertEq(cToken.balanceOf(_supplier), 0);
    assertEq(govToken.balanceOf(address(cToken)), 0);
    assertEq(govToken.balanceOf(_supplier), 0);
    uint256 _initSupply = 1000 ether;
    govToken.exposed_mint(_supplier, _initSupply);
    govToken.approve(address(cToken), type(uint256).max);
    cToken.supply(address(govToken), _initSupply);
    uint256 _initCTokenBalance = cToken.balanceOf(_supplier);
    assertGt(_initCTokenBalance, 0);

    // Someone else wants to borrow GOV.
    address _borrower = makeAddr("_borrower");
    deal(weth, _borrower, 100 ether);
    vm.prank(_borrower);
    vm.expectRevert(CometMainInterface.NotCollateralized.selector);
    cToken.withdraw(address(govToken), 0.1 ether);

    // Borrower deposits WETH to borrow GOV against.
    vm.prank(_borrower);
    IERC20(weth).approve(address(cToken), type(uint256).max);
    vm.prank(_borrower);
    cToken.supply(weth, 100 ether);
    assertEq(IERC20(weth).balanceOf(_borrower), 0);

    // Borrow GOV against WETH position.
    vm.prank(_borrower);
    cToken.withdraw(address(govToken), 100 ether);
    assertEq(govToken.balanceOf(_borrower), 100 ether);
    uint256 _initBorrowBalance = cToken.borrowBalanceOf(_borrower);
    assertEq(_initBorrowBalance, 100 ether);

    // Supplier earns yield. Borrower owes interest.
    vm.roll(block.number + 1);
    vm.warp(block.timestamp + 100 days);
    uint256 _newCTokenBalance = cToken.balanceOf(_supplier);
    assertGt(_newCTokenBalance, _initCTokenBalance, "Supplier has not earned yield");
    uint256 _newBorrowBalance = cToken.borrowBalanceOf(_borrower);
    assertGt(_newBorrowBalance, _initBorrowBalance, "Borrower does not owe interest");

    // The supplier can't claim the yield yet because the cToken doesn't have it.
    vm.prank(_supplier);
    vm.expectRevert("ERC20: transfer amount exceeds balance");
    cToken.withdraw(address(govToken), _newCTokenBalance);
    assertGt(_newCTokenBalance, govToken.balanceOf(address(cToken)));

    // Repay the borrow so that the supplier can realize yield.
    govToken.exposed_mint(_borrower, _newBorrowBalance - _initBorrowBalance);
    vm.prank(_borrower);
    govToken.approve(address(cToken), type(uint256).max);
    vm.prank(_borrower);
    cToken.supply(address(govToken), type(uint256).max);
    assertGt(_newCTokenBalance, govToken.balanceOf(address(cToken)));

    // Get that yield fool!
    vm.prank(_supplier);
    cToken.withdraw(address(govToken), govToken.balanceOf(address(cToken)));
    assertGt(govToken.balanceOf(_supplier), _initSupply, "Supplier didn't actually earn yield");
  }
}

contract CastVote is CometForkTest {
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

  function _testUserCanCastVotes(address _who, uint256 _voteWeight, uint8 _supportType) private {
    // Deposit some funds.
    mintGovAndSupplyToCompound(_who, _voteWeight);

    // Create the proposal.
    uint256 _proposalId = createAndSubmitProposal();
    assertEq(
      govToken.getPastVotes(address(cToken), block.number - 1),
      _voteWeight,
      "getPastVotes returned unexpected result"
    );

    // _who should now be able to express his/her vote on the proposal.
    vm.prank(_who);
    cToken.expressVote(_proposalId, _supportType);

    (
      uint256 _againstVotesExpressed, // Expressed, not cast.
      uint256 _forVotesExpressed,
      uint256 _abstainVotesExpressed
    ) = cToken.proposalVotes(_proposalId);

    // Vote preferences have been expressed.
    assertEq(_forVotesExpressed, _supportType == uint8(VoteType.For) ? _voteWeight : 0);
    assertEq(_againstVotesExpressed, _supportType == uint8(VoteType.Against) ? _voteWeight : 0);
    assertEq(_abstainVotesExpressed, _supportType == uint8(VoteType.Abstain) ? _voteWeight : 0);

    (uint256 _againstVotes, uint256 _forVotes, uint256 _abstainVotes) =
      flexVotingGovernor.proposalVotes(_proposalId);

    // But no actual votes have been cast yet.
    assertEq(_forVotes, 0);
    assertEq(_againstVotes, 0);
    assertEq(_abstainVotes, 0);

    // Submit votes on behalf of the pool.
    vm.recordLogs();
    cToken.castVote(_proposalId);
    Vm.Log[] memory _logs = vm.getRecordedLogs();

    // Confirm the relevant events were emitted.
    bytes32 _eventSig = keccak256("VoteCastWithParams(address,uint256,uint8,uint256,string,bytes)");
    for (uint256 i; i < _logs.length; i++) {
      Vm.Log memory _log = _logs[i];
      if (_log.topics[0] == _eventSig) {
        assertEq(address(uint160(uint256(_log.topics[1]))), address(cToken));
        (uint256 _actualProposalId,,, string memory _reason,) =
          abi.decode(_log.data, (uint256, uint8, uint256, string, bytes));
        assertEq(_proposalId, _actualProposalId);
        assertEq(
          keccak256(bytes(_reason)),
          keccak256("rolled-up vote from CometFlexVoting token holders"),
          "Reason string is not: 'rolled-up vote from CometFlexVoting token holders'"
        );
      }
    }

    // flexVotingGovernor should now record votes from the pool.
    (_againstVotes, _forVotes, _abstainVotes) = flexVotingGovernor.proposalVotes(_proposalId);
    assertEq(_forVotes, _forVotesExpressed, "for votes not as expected");
    assertEq(_againstVotes, _againstVotesExpressed, "against votes not as expected");
    assertEq(_abstainVotes, _abstainVotesExpressed, "abstain votes not as expected");
  }

  function test_UserCannotExpressAgainstVotesWithoutWeight() public {
    _testUserCannotExpressVotesWithoutCTokens(
      makeAddr("test_UserCannotExpressAgainstVotesWithoutWeight address"),
      0.42 ether,
      uint8(VoteType.Against)
    );
  }

  function test_UserCannotExpressForVotesWithoutWeight() public {
    _testUserCannotExpressVotesWithoutCTokens(
      makeAddr("test_UserCannotExpressForVotesWithoutWeight address"),
      0.42 ether,
      uint8(VoteType.For)
    );
  }

  function test_UserCannotExpressAbstainVotesWithoutWeight() public {
    _testUserCannotExpressVotesWithoutCTokens(
      makeAddr("test_UserCannotExpressAbstainVotesWithoutWeight address"),
      0.42 ether,
      uint8(VoteType.Abstain)
    );
  }

  function _testUserCannotExpressVotesWithoutCTokens(
    address _who,
    uint256 _voteWeight,
    uint8 _supportType
  ) private {
    // Mint gov but do not deposit
    govToken.exposed_mint(_who, _voteWeight);
    vm.prank(_who);
    govToken.approve(address(cToken), type(uint256).max);

    assertEq(govToken.balanceOf(_who), _voteWeight);

    // Create the proposal.
    uint256 _proposalId = createAndSubmitProposal();

    // _who should NOT be able to express his/her vote on the proposal
    vm.expectRevert(bytes("no weight"));
    vm.prank(_who);
    cToken.expressVote(_proposalId, uint8(_supportType));
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

  function _testUserCannotCastAfterVotingPeriod(
    address _who,
    uint256 _voteWeight,
    uint8 _supportType
  ) private {
    // Deposit some funds.
    mintGovAndSupplyToCompound(_who, _voteWeight);

    // Create the proposal.
    uint256 _proposalId = createAndSubmitProposal();

    // Express vote preference.
    vm.prank(_who);
    cToken.expressVote(_proposalId, _supportType);

    // Jump ahead so that we're outside of the proposal's voting period.
    vm.roll(flexVotingGovernor.proposalDeadline(_proposalId) + 1);

    // We should not be able to castVote at this point.
    vm.expectRevert(bytes("Governor: vote not currently active"));
    cToken.castVote(_proposalId);
  }

  function test_UserCannotDoubleVoteAfterVotingAgainst() public {
    _testNoDoubleVoting(
      makeAddr("test_UserCannotDoubleVoteAfterVoting address"), 0.042 ether, uint8(VoteType.Against)
    );
  }

  function test_UserCannotDoubleVoteAfterVotingFor() public {
    _testNoDoubleVoting(
      makeAddr("test_UserCannotDoubleVoteAfterVoting address"), 0.042 ether, uint8(VoteType.For)
    );
  }

  function test_UserCannotDoubleVoteAfterVotingAbstain() public {
    _testNoDoubleVoting(
      makeAddr("test_UserCannotDoubleVoteAfterVoting address"), 0.042 ether, uint8(VoteType.Abstain)
    );
  }

  function _testNoDoubleVoting(address _who, uint256 _voteWeight, uint8 _supportType) private {
    // Deposit some funds.
    mintGovAndSupplyToCompound(_who, _voteWeight);

    // Create the proposal.
    uint256 _proposalId = createAndSubmitProposal();

    // _who should now be able to express his/her vote on the proposal.
    vm.prank(_who);
    cToken.expressVote(_proposalId, _supportType);

    // Vote early and often.
    vm.expectRevert(bytes("already voted"));
    vm.prank(_who);
    cToken.expressVote(_proposalId, _supportType);
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

  function _testUserCannotCastVotesTwice(address _who, uint256 _voteWeight, uint8 _supportType)
    private
  {
    // Deposit some funds.
    mintGovAndSupplyToCompound(_who, _voteWeight);

    // Have someone else deposit as well so that _who isn't the only one.
    mintGovAndSupplyToCompound(makeAddr("testUserCannotCastVotesTwice"), _voteWeight);

    // Create the proposal.
    uint256 _proposalId = createAndSubmitProposal();

    // _who should now be able to express his/her vote on the proposal.
    vm.prank(_who);
    cToken.expressVote(_proposalId, _supportType);

    // Submit votes on behalf of the pool.
    cToken.castVote(_proposalId);

    // Try to submit them again.
    vm.expectRevert("no votes expressed");
    cToken.castVote(_proposalId);
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
      makeAddr("UserCannotExpressVotesPriorToDepositing address"),
      4.242 ether, // Vote weight.
      uint8(VoteType.For)
    );
  }

  function test_UserCannotExpressAbstainVotesPriorToDepositing() public {
    _testUserCannotExpressVotesPriorToDepositing(
      makeAddr("UserCannotExpressVotesPriorToDepositing address"),
      4.242 ether,
      uint8(VoteType.Abstain)
    );
  }

  function _testUserCannotExpressVotesPriorToDepositing(
    address _who,
    uint256 _voteWeight,
    uint8 _supportType
  ) private {
    // Create the proposal *before* the user deposits anything.
    uint256 _proposalId = createAndSubmitProposal();

    // Deposit some funds.
    mintGovAndSupplyToCompound(_who, _voteWeight);

    // Now try to express a voting preference on the proposal.
    vm.expectRevert(bytes("no weight"));
    vm.prank(_who);
    cToken.expressVote(_proposalId, _supportType);
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

  function _testUserVotingWeightIsSnapshotDependent(
    address _who,
    uint256 _voteWeightA,
    uint256 _voteWeightB,
    uint8 _supportType
  ) private {
    // Deposit some funds.
    mintGovAndSupplyToCompound(_who, _voteWeightA);

    // Create the proposal.
    uint256 _proposalId = createAndSubmitProposal();

    // Sometime later the user deposits some more.
    vm.roll(flexVotingGovernor.proposalDeadline(_proposalId) - 1);
    mintGovAndSupplyToCompound(_who, _voteWeightB);

    vm.prank(_who);
    cToken.expressVote(_proposalId, _supportType);

    // The internal proposal vote weight should not reflect the new deposit weight.
    (uint256 _againstVotesExpressed, uint256 _forVotesExpressed, uint256 _abstainVotesExpressed) =
      cToken.proposalVotes(_proposalId);
    assertEq(_forVotesExpressed, _supportType == uint8(VoteType.For) ? _voteWeightA : 0);
    assertEq(_againstVotesExpressed, _supportType == uint8(VoteType.Against) ? _voteWeightA : 0);
    assertEq(_abstainVotesExpressed, _supportType == uint8(VoteType.Abstain) ? _voteWeightA : 0);

    // Submit votes on behalf of the pool.
    cToken.castVote(_proposalId);

    // Votes cast should likewise reflect only the earlier balance.
    (uint256 _againstVotes, uint256 _forVotes, uint256 _abstainVotes) =
      flexVotingGovernor.proposalVotes(_proposalId);
    assertEq(_forVotes, _supportType == uint8(VoteType.For) ? _voteWeightA : 0);
    assertEq(_againstVotes, _supportType == uint8(VoteType.Against) ? _voteWeightA : 0);
    assertEq(_abstainVotes, _supportType == uint8(VoteType.Abstain) ? _voteWeightA : 0);
  }

  function test_MultipleUsersCanCastVotes() public {
    _testMultipleUsersCanCastVotes(
      makeAddr("MultipleUsersCanCastVotes address 1"),
      makeAddr("MultipleUsersCanCastVotes address 2"),
      0.42424242 ether,
      0.00000042 ether
    );
  }

  function _testMultipleUsersCanCastVotes(
    address _userA,
    address _userB,
    uint256 _voteWeightA,
    uint256 _voteWeightB
  ) private {
    // Deposit some funds.
    mintGovAndSupplyToCompound(_userA, _voteWeightA);
    mintGovAndSupplyToCompound(_userB, _voteWeightB);

    // Create the proposal.
    uint256 _proposalId = createAndSubmitProposal();

    // Users should now be able to express their votes on the proposal.
    vm.prank(_userA);
    cToken.expressVote(_proposalId, uint8(VoteType.Against));
    vm.prank(_userB);
    cToken.expressVote(_proposalId, uint8(VoteType.Abstain));

    (uint256 _againstVotesExpressed, uint256 _forVotesExpressed, uint256 _abstainVotesExpressed) =
      cToken.proposalVotes(_proposalId);
    assertEq(_forVotesExpressed, 0);
    assertEq(_againstVotesExpressed, _voteWeightA);
    assertEq(_abstainVotesExpressed, _voteWeightB);

    // The governor should have not received any votes yet.
    (uint256 _againstVotes, uint256 _forVotes, uint256 _abstainVotes) =
      flexVotingGovernor.proposalVotes(_proposalId);
    assertEq(_forVotes, 0);
    assertEq(_againstVotes, 0);
    assertEq(_abstainVotes, 0);

    // Submit votes on behalf of the pool.
    cToken.castVote(_proposalId);

    // Governor should now record votes for the pool.
    (_againstVotes, _forVotes, _abstainVotes) = flexVotingGovernor.proposalVotes(_proposalId);
    assertEq(_forVotes, 0);
    assertEq(_againstVotes, _voteWeightA);
    assertEq(_abstainVotes, _voteWeightB);
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

  function _testVoteWeightIsScaledBasedOnPoolBalance(VoteWeightIsScaledVars memory _vars) private {
    // This would be a bound if we could do fuzz tests.
    require(_vars.voteWeightA + _vars.voteWeightB < type(uint128).max, "test assumption not met");

    // Deposit some funds.
    mintGovAndSupplyToCompound(_vars.voterA, _vars.voteWeightA);
    mintGovAndSupplyToCompound(_vars.voterB, _vars.voteWeightB);
    uint256 _initGovBalance = govToken.balanceOf(address(cToken));

    // Borrow GOV from the cToken, decreasing its token balance.
    deal(weth, _vars.borrower, _vars.borrowerAssets);
    vm.startPrank(_vars.borrower);
    IERC20(weth).approve(address(cToken), type(uint256).max);
    cToken.supply(weth, _vars.borrowerAssets);
    // Borrow GOV against WETH
    cToken.withdraw(
      address(govToken),
      (_vars.voteWeightA + _vars.voteWeightB) / 7 // amount of GOV to borrow
    );
    assertLt(govToken.balanceOf(address(cToken)), _initGovBalance);
    govToken.delegate(_vars.borrower);
    vm.stopPrank();

    // Create the proposal.
    uint256 _proposalId = createAndSubmitProposal();

    // Jump ahead to the proposal snapshot to lock in the cToken's balance.
    vm.roll(flexVotingGovernor.proposalSnapshot(_proposalId) + 1);
    uint256 _expectedVotingWeight = govToken.balanceOf(address(cToken));
    assert(_expectedVotingWeight < _initGovBalance);

    // A+B express votes
    vm.prank(_vars.voterA);
    cToken.expressVote(_proposalId, _vars.supportTypeA);
    vm.prank(_vars.voterB);
    cToken.expressVote(_proposalId, _vars.supportTypeB);

    // Submit votes on behalf of the cToken.
    cToken.castVote(_proposalId);

    // Vote should be cast as a percentage of the depositor's expressed types, since
    // the actual weight is different from the deposit weight.
    (uint256 _againstVotes, uint256 _forVotes, uint256 _abstainVotes) =
      flexVotingGovernor.proposalVotes(_proposalId);

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
    flexVotingGovernor.castVoteWithReasonAndParams(
      _proposalId,
      uint8(VoteType.For),
      "Vote from the person that borrowed Gov from Aave",
      new bytes(0) // Vote nominally so that all of the borrower's weight is used.
    );

    (_againstVotes, _forVotes, _abstainVotes) = flexVotingGovernor.proposalVotes(_proposalId);
    // The summed votes should now ~equal the amount of Gov initially supplied,
    // since the borrower also voted. There can be off-by-one errors because
    // the cToken rounds vote weights down before casting, but the total voting
    // weight expressed should be constrained by the amount of govToken injected into
    // the system. This ensures there's no double counting possible.
    assertApproxEqAbs(
      _initGovBalance,
      _againstVotes + _forVotes + _abstainVotes,
      1,
      "the number of votes cast does not match the amount of gov minted"
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
    // This would be a bound if we could do fuzz tests.
    require(_vars.voteWeightA + _vars.voteWeightB < type(uint128).max, "test assumption not met");

    // Deposit some funds.
    mintGovAndSupplyToCompound(_vars.voterA, _vars.voteWeightA);
    mintGovAndSupplyToCompound(_vars.voterB, _vars.voteWeightB);
    uint256 _initGovBalance = govToken.balanceOf(address(cToken));

    // Borrow GOV from the cToken, decreasing its token balance.
    deal(weth, _vars.borrower, _vars.borrowerAssets);
    vm.startPrank(_vars.borrower);
    IERC20(weth).approve(address(cToken), type(uint256).max);
    cToken.supply(weth, _vars.borrowerAssets);
    // Borrow GOV against WETH
    cToken.withdraw(
      address(govToken),
      (_vars.voteWeightA + _vars.voteWeightB) / 5 // amount of GOV to borrow
    );
    assertLt(govToken.balanceOf(address(cToken)), _initGovBalance);
    vm.stopPrank();

    // Create the proposal.
    uint256 _proposalId = createAndSubmitProposal();

    // Jump ahead to the proposal snapshot to lock in the cToken's balance.
    vm.roll(flexVotingGovernor.proposalSnapshot(_proposalId) + 1);
    uint256 _totalPossibleVotingWeight = govToken.balanceOf(address(cToken));

    uint256 _fullVotingWeight = govToken.balanceOf(address(cToken));
    assert(_fullVotingWeight < _initGovBalance);
    uint256 _borrowedGov = govToken.balanceOf(address(_vars.borrower));
    assertEq(
      _fullVotingWeight,
      _vars.voteWeightA + _vars.voteWeightB - _borrowedGov,
      "voting weight doesn't match calculated value"
    );

    // Only user A expresses a vote.
    vm.prank(_vars.voterA);
    cToken.expressVote(_proposalId, _vars.supportTypeA);

    // Submit votes on behalf of the cToken.
    cToken.castVote(_proposalId);

    // Vote should be cast as a percentage of the depositor's expressed types, since
    // the actual weight is different from the deposit weight.
    (uint256 _againstVotes, uint256 _forVotes, uint256 _abstainVotes) =
      flexVotingGovernor.proposalVotes(_proposalId);

    uint256 _expectedVotingWeightA = (_vars.voteWeightA * _fullVotingWeight) / _initGovBalance;
    uint256 _expectedVotingWeightB = (_vars.voteWeightB * _fullVotingWeight) / _initGovBalance;

    // The cToken *could* have voted with this much weight.
    assertApproxEqAbs(
      _totalPossibleVotingWeight, _expectedVotingWeightA + _expectedVotingWeightB, 1
    );

    // Actually, though, the cToken did not vote with all of the weight it could have.
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

  function _testVotingWeightIsUnaffectedByDepositsAfterProposal(
    address _voterA,
    address _voterB,
    uint256 _voteWeightA,
    uint256 _voteWeightB,
    uint8 _supportTypeA
  ) private {
    // This would be a bound if we could do fuzz tests.
    require(_voteWeightA + _voteWeightB < type(uint128).max, "test assumption not met");

    // Mint and deposit for just userA.
    mintGovAndSupplyToCompound(_voterA, _voteWeightA);
    uint256 _initGovBalance = govToken.balanceOf(address(cToken));

    // Create the proposal.
    uint256 _proposalId = createAndSubmitProposal();

    // Jump ahead to the proposal snapshot to lock in the cToken's balance.
    vm.roll(flexVotingGovernor.proposalSnapshot(_proposalId) + 1);

    // Now mint and deposit for userB.
    mintGovAndSupplyToCompound(_voterB, _voteWeightB);

    uint256 _fullVotingWeight = govToken.balanceOf(address(cToken));
    assert(_fullVotingWeight > _initGovBalance);
    assertEq(_fullVotingWeight, _voteWeightA + _voteWeightB);

    // Only user A expresses a vote.
    vm.prank(_voterA);
    cToken.expressVote(_proposalId, _supportTypeA);

    // Submit votes on behalf of the cToken.
    cToken.castVote(_proposalId);

    (uint256 _againstVotes, uint256 _forVotes, uint256 _abstainVotes) =
      flexVotingGovernor.proposalVotes(_proposalId);

    if (_supportTypeA == uint8(VoteType.For)) assertEq(_forVotes, _voteWeightA);
    if (_supportTypeA == uint8(VoteType.Against)) assertEq(_againstVotes, _voteWeightA);
    if (_supportTypeA == uint8(VoteType.Abstain)) assertEq(_abstainVotes, _voteWeightA);
  }
}

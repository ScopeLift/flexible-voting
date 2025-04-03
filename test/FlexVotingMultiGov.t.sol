// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {IFractionalGovernor} from "src/interfaces/IFractionalGovernor.sol";
import {FlexVotingDelegatable} from "src/FlexVotingDelegatable.sol";
import {MockFlexVotingClient as MFVC} from "test/mocks/MockFlexVotingClient.sol";
import {MockFlexVotingMultiGovClient} from "test/mocks/MockFlexVotingMultiGovClient.sol";
import {GovernorCountingSimple as GCS} from
  "@openzeppelin/contracts/governance/extensions/GovernorCountingSimple.sol";

import {FlexVotingClient as FVC} from "src/FlexVotingClient.sol";

import {
  FlexVotingClientTest,
  Deployment,
  Constructor,
  _RawBalanceOf,
  _CastVoteReasonString,
  _SelfDelegate,
  _CheckpointVoteWeightOf,
  _CheckpointTotalVoteWeight,
  GetPastRawBalance,
  GetPastTotalBalance,
  Withdraw,
  Deposit,
  ExpressVote,
  CastVote,
  Borrow
} from "test/SharedFlexVoting.t.sol";

contract SharedMultiGovTest is Test {
  address OWNER = vm.randomAddress();
}

contract BlockNumberClock_Deployment is SharedMultiGovTest, Deployment {
  function _timestampClock() internal pure override returns (bool) {
    return false;
  }

  function _deployFlexClient(address _governor) internal override {
    flexClient = MFVC(address(new MockFlexVotingMultiGovClient(IFractionalGovernor(address(_governor)), OWNER)));
  }
}

contract BlockNumber_Constructor is SharedMultiGovTest, Constructor {
  function _timestampClock() internal pure override returns (bool) {
    return false;
  }

  function _deployFlexClient(address _governor) internal override {
    flexClient = MFVC(address(new MockFlexVotingMultiGovClient(IFractionalGovernor(address(_governor)), OWNER)));
  }
}

contract BlockNumber__RawBalanceOf is SharedMultiGovTest, _RawBalanceOf {
  function _timestampClock() internal pure override returns (bool) {
    return false;
  }

  function _deployFlexClient(address _governor) internal override {
    flexClient = MFVC(address(new MockFlexVotingMultiGovClient(IFractionalGovernor(address(_governor)), OWNER)));
  }
}

contract BlockNumber__CastVoteReasonString is SharedMultiGovTest, _CastVoteReasonString {
  function _timestampClock() internal pure override returns (bool) {
    return false;
  }

  function _deployFlexClient(address _governor) internal override {
    flexClient = MFVC(address(new MockFlexVotingMultiGovClient(IFractionalGovernor(address(_governor)), OWNER)));
  }
}

contract BlockNumber__SelfDelegate is SharedMultiGovTest, _SelfDelegate {
  function _timestampClock() internal pure override returns (bool) {
    return false;
  }

  function _deployFlexClient(address _governor) internal override {
    flexClient = MFVC(address(new MockFlexVotingMultiGovClient(IFractionalGovernor(address(_governor)), OWNER)));
  }
}

contract BlockNumber__CheckpointVoteWeightOf is SharedMultiGovTest, _CheckpointVoteWeightOf {
  function _timestampClock() internal pure override returns (bool) {
    return false;
  }

  function _deployFlexClient(address _governor) internal override {
    flexClient = MFVC(address(new MockFlexVotingMultiGovClient(IFractionalGovernor(address(_governor)), OWNER)));
  }
}

contract BlockNumber__CheckpointTotalVoteWeight is SharedMultiGovTest, _CheckpointTotalVoteWeight {
  function _timestampClock() internal pure override returns (bool) {
    return false;
  }

  function _deployFlexClient(address _governor) internal override {
    flexClient = MFVC(address(new MockFlexVotingMultiGovClient(IFractionalGovernor(address(_governor)), OWNER)));
  }
}

contract BlockNumber_GetPastRawBalance is SharedMultiGovTest, GetPastRawBalance {
  function _timestampClock() internal pure override returns (bool) {
    return false;
  }

  function _deployFlexClient(address _governor) internal override {
    flexClient = MFVC(address(new MockFlexVotingMultiGovClient(IFractionalGovernor(address(_governor)), OWNER)));
  }
}

contract BlockNumber_GetPastTotalBalance is SharedMultiGovTest, GetPastTotalBalance {
  function _timestampClock() internal pure override returns (bool) {
    return false;
  }

  function _deployFlexClient(address _governor) internal override {
    flexClient = MFVC(address(new MockFlexVotingMultiGovClient(IFractionalGovernor(address(_governor)), OWNER)));
  }
}

contract BlockNumber_Withdraw is SharedMultiGovTest, Withdraw {
  function _timestampClock() internal pure override returns (bool) {
    return false;
  }

  function _deployFlexClient(address _governor) internal override {
    flexClient = MFVC(address(new MockFlexVotingMultiGovClient(IFractionalGovernor(address(_governor)), OWNER)));
  }
}

contract BlockNumber_Deposit is SharedMultiGovTest, Deposit {
  function _timestampClock() internal pure override returns (bool) {
    return false;
  }

  function _deployFlexClient(address _governor) internal override {
    flexClient = MFVC(address(new MockFlexVotingMultiGovClient(IFractionalGovernor(address(_governor)), OWNER)));
  }
}

contract BlockNumber_ExpressVote is SharedMultiGovTest, ExpressVote {
  function _timestampClock() internal pure override returns (bool) {
    return false;
  }

  function _deployFlexClient(address _governor) internal override {
    flexClient = MFVC(address(new MockFlexVotingMultiGovClient(IFractionalGovernor(address(_governor)), OWNER)));
  }
}

contract BlockNumber_CastVote is SharedMultiGovTest, CastVote {
  function _timestampClock() internal pure override returns (bool) {
    return false;
  }

  function _deployFlexClient(address _governor) internal override {
    flexClient = MFVC(address(new MockFlexVotingMultiGovClient(IFractionalGovernor(address(_governor)), OWNER)));
  }
}

contract BlockNumber_Borrow is SharedMultiGovTest, Borrow {
  function _timestampClock() internal pure override returns (bool) {
    return false;
  }

  function _deployFlexClient(address _governor) internal override {
    flexClient = MFVC(address(new MockFlexVotingMultiGovClient(IFractionalGovernor(address(_governor)), OWNER)));
  }
}

contract TimestampClockClock_Deployment is SharedMultiGovTest, Deployment {
  function _timestampClock() internal pure override returns (bool) {
    return true;
  }

  function _deployFlexClient(address _governor) internal override {
    flexClient = MFVC(address(new MockFlexVotingMultiGovClient(IFractionalGovernor(address(_governor)), OWNER)));
  }
}

contract TimestampClock_Constructor is SharedMultiGovTest, Constructor {
  function _timestampClock() internal pure override returns (bool) {
    return true;
  }

  function _deployFlexClient(address _governor) internal override {
    flexClient = MFVC(address(new MockFlexVotingMultiGovClient(IFractionalGovernor(address(_governor)), OWNER)));
  }
}

contract TimestampClock__RawBalanceOf is SharedMultiGovTest, _RawBalanceOf {
  function _timestampClock() internal pure override returns (bool) {
    return true;
  }

  function _deployFlexClient(address _governor) internal override {
    flexClient = MFVC(address(new MockFlexVotingMultiGovClient(IFractionalGovernor(address(_governor)), OWNER)));
  }
}

contract TimestampClock__CastVoteReasonString is SharedMultiGovTest, _CastVoteReasonString {
  function _timestampClock() internal pure override returns (bool) {
    return true;
  }

  function _deployFlexClient(address _governor) internal override {
    flexClient = MFVC(address(new MockFlexVotingMultiGovClient(IFractionalGovernor(address(_governor)), OWNER)));
  }
}

contract TimestampClock__SelfDelegate is SharedMultiGovTest, _SelfDelegate {
  function _timestampClock() internal pure override returns (bool) {
    return true;
  }

  function _deployFlexClient(address _governor) internal override {
    flexClient = MFVC(address(new MockFlexVotingMultiGovClient(IFractionalGovernor(address(_governor)), OWNER)));
  }
}

contract TimestampClock__CheckpointVoteWeightOf is SharedMultiGovTest, _CheckpointVoteWeightOf {
  function _timestampClock() internal pure override returns (bool) {
    return true;
  }

  function _deployFlexClient(address _governor) internal override {
    flexClient = MFVC(address(new MockFlexVotingMultiGovClient(IFractionalGovernor(address(_governor)), OWNER)));
  }
}

contract TimestampClock__CheckpointTotalVoteWeight is SharedMultiGovTest, _CheckpointTotalVoteWeight {
  function _timestampClock() internal pure override returns (bool) {
    return true;
  }

  function _deployFlexClient(address _governor) internal override {
    flexClient = MFVC(address(new MockFlexVotingMultiGovClient(IFractionalGovernor(address(_governor)), OWNER)));
  }
}

contract TimestampClock_GetPastRawBalance is SharedMultiGovTest, GetPastRawBalance {
  function _timestampClock() internal pure override returns (bool) {
    return true;
  }

  function _deployFlexClient(address _governor) internal override {
    flexClient = MFVC(address(new MockFlexVotingMultiGovClient(IFractionalGovernor(address(_governor)), OWNER)));
  }
}

contract TimestampClock_GetPastTotalBalance is SharedMultiGovTest, GetPastTotalBalance {
  function _timestampClock() internal pure override returns (bool) {
    return true;
  }

  function _deployFlexClient(address _governor) internal override {
    flexClient = MFVC(address(new MockFlexVotingMultiGovClient(IFractionalGovernor(address(_governor)), OWNER)));
  }
}

contract TimestampClock_Withdraw is SharedMultiGovTest, Withdraw {
  function _timestampClock() internal pure override returns (bool) {
    return true;
  }

  function _deployFlexClient(address _governor) internal override {
    flexClient = MFVC(address(new MockFlexVotingMultiGovClient(IFractionalGovernor(address(_governor)), OWNER)));
  }
}

contract TimestampClock_Deposit is SharedMultiGovTest, Deposit {
  function _timestampClock() internal pure override returns (bool) {
    return true;
  }

  function _deployFlexClient(address _governor) internal override {
    flexClient = MFVC(address(new MockFlexVotingMultiGovClient(IFractionalGovernor(address(_governor)), OWNER)));
  }
}

contract TimestampClock_ExpressVote is SharedMultiGovTest, ExpressVote {
  function _timestampClock() internal pure override returns (bool) {
    return true;
  }

  function _deployFlexClient(address _governor) internal override {
    flexClient = MFVC(address(new MockFlexVotingMultiGovClient(IFractionalGovernor(address(_governor)), OWNER)));
  }
}

contract TimestampClock_CastVote is SharedMultiGovTest, CastVote {
  function _timestampClock() internal pure override returns (bool) {
    return true;
  }

  function _deployFlexClient(address _governor) internal override {
    flexClient = MFVC(address(new MockFlexVotingMultiGovClient(IFractionalGovernor(address(_governor)), OWNER)));
  }
}

contract TimestampClock_Borrow is SharedMultiGovTest, Borrow {
  function _timestampClock() internal pure override returns (bool) {
    return true;
  }

  function _deployFlexClient(address _governor) internal override {
    flexClient = MFVC(address(new MockFlexVotingMultiGovClient(IFractionalGovernor(address(_governor)), OWNER)));
  }
}

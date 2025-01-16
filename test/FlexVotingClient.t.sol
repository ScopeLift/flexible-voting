// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {MockFlexVotingClient} from "test/MockFlexVotingClient.sol";
import {
  Deployment,
  Constructor,
  _RawBalanceOf,
  _CastVoteReasonString,
  _SelfDelegate,
  _CheckpointRawBalanceOf,
  _CheckpointTotalBalance,
  GetPastRawBalance,
  GetPastTotalBalance,
  Withdraw,
  Deposit,
  ExpressVote,
  CastVote,
  Borrow
} from "test/SharedFlexVoting.t.sol";

// Block number tests.
contract BlockNumberClock_Deployment is Deployment {
  function _timestampClock() internal pure override returns (bool) {
    return false;
  }
  function _deployClient(address _governor) internal override {
    client = address(new MockFlexVotingClient(_governor));
  }
  function flexClient() public view override returns (MockFlexVotingClient) {
    return MockFlexVotingClient(client);
  }
}

contract BlockNumberClock_Constructor is Constructor {
  function _timestampClock() internal pure override returns (bool) {
    return false;
  }
  function _deployClient(address _governor) internal override {
    client = address(new MockFlexVotingClient(_governor));
  }
  function flexClient() public view override returns (MockFlexVotingClient) {
    return MockFlexVotingClient(client);
  }
}

contract BlockNumberClock__RawBalanceOf is _RawBalanceOf {
  function _timestampClock() internal pure override returns (bool) {
    return false;
  }
  function _deployClient(address _governor) internal override {
    client = address(new MockFlexVotingClient(_governor));
  }
  function flexClient() public view override returns (MockFlexVotingClient) {
    return MockFlexVotingClient(client);
  }
}

contract BlockNumberClock__CastVoteReasonString is _CastVoteReasonString {
  function _timestampClock() internal pure override returns (bool) {
    return false;
  }
  function _deployClient(address _governor) internal override {
    client = address(new MockFlexVotingClient(_governor));
  }
  function flexClient() public view override returns (MockFlexVotingClient) {
    return MockFlexVotingClient(client);
  }
}

contract BlockNumberClock__SelfDelegate is _SelfDelegate {
  function _timestampClock() internal pure override returns (bool) {
    return false;
  }
  function _deployClient(address _governor) internal override {
    client = address(new MockFlexVotingClient(_governor));
  }
  function flexClient() public view override returns (MockFlexVotingClient) {
    return MockFlexVotingClient(client);
  }
}

contract BlockNumberClock__CheckpointRawBalanceOf is _CheckpointRawBalanceOf {
  function _timestampClock() internal pure override returns (bool) {
    return false;
  }
  function _deployClient(address _governor) internal override {
    client = address(new MockFlexVotingClient(_governor));
  }
  function flexClient() public view override returns (MockFlexVotingClient) {
    return MockFlexVotingClient(client);
  }
}

contract BlockNumberClock_GetPastRawBalance is GetPastRawBalance {
  function _timestampClock() internal pure override returns (bool) {
    return false;
  }
  function _deployClient(address _governor) internal override {
    client = address(new MockFlexVotingClient(_governor));
  }
  function flexClient() public view override returns (MockFlexVotingClient) {
    return MockFlexVotingClient(client);
  }
}

contract BlockNumber__CheckpointTotalBalance is _CheckpointTotalBalance {
  function _timestampClock() internal pure override returns (bool) {
    return false;
  }
  function _deployClient(address _governor) internal override {
    client = address(new MockFlexVotingClient(_governor));
  }
  function flexClient() public view override returns (MockFlexVotingClient) {
    return MockFlexVotingClient(client);
  }
}

contract BlockNumberClock_GetPastTotalBalance is GetPastTotalBalance {
  function _timestampClock() internal pure override returns (bool) {
    return false;
  }
  function _deployClient(address _governor) internal override {
    client = address(new MockFlexVotingClient(_governor));
  }
  function flexClient() public view override returns (MockFlexVotingClient) {
    return MockFlexVotingClient(client);
  }
}

contract BlockNumberClock_Withdraw is Withdraw {
  function _timestampClock() internal pure override returns (bool) {
    return false;
  }
  function _deployClient(address _governor) internal override {
    client = address(new MockFlexVotingClient(_governor));
  }
  function flexClient() public view override returns (MockFlexVotingClient) {
    return MockFlexVotingClient(client);
  }
}

contract BlockNumberClock_Deposit is Deposit {
  function _timestampClock() internal pure override returns (bool) {
    return false;
  }
  function _deployClient(address _governor) internal override {
    client = address(new MockFlexVotingClient(_governor));
  }
  function flexClient() public view override returns (MockFlexVotingClient) {
    return MockFlexVotingClient(client);
  }
}

contract BlockNumberClock_ExpressVote is ExpressVote {
  function _timestampClock() internal pure override returns (bool) {
    return false;
  }
  function _deployClient(address _governor) internal override {
    client = address(new MockFlexVotingClient(_governor));
  }
  function flexClient() public view override returns (MockFlexVotingClient) {
    return MockFlexVotingClient(client);
  }
}

contract BlockNumberClock_CastVote is CastVote {
  function _timestampClock() internal pure override returns (bool) {
    return false;
  }
  function _deployClient(address _governor) internal override {
    client = address(new MockFlexVotingClient(_governor));
  }
  function flexClient() public view override returns (MockFlexVotingClient) {
    return MockFlexVotingClient(client);
  }
}

contract BlockNumberClock_Borrow is Borrow {
  function _timestampClock() internal pure override returns (bool) {
    return false;
  }
  function _deployClient(address _governor) internal override {
    client = address(new MockFlexVotingClient(_governor));
  }
  function flexClient() public view override returns (MockFlexVotingClient) {
    return MockFlexVotingClient(client);
  }
}

// Timestamp tests.
contract TimestampClock_Deployment is Deployment {
  function _timestampClock() internal pure override returns (bool) {
    return true;
  }
  function _deployClient(address _governor) internal override {
    client = address(new MockFlexVotingClient(_governor));
  }
  function flexClient() public view override returns (MockFlexVotingClient) {
    return MockFlexVotingClient(client);
  }
}

contract TimestampClock_Constructor is Constructor {
  function _timestampClock() internal pure override returns (bool) {
    return true;
  }
  function _deployClient(address _governor) internal override {
    client = address(new MockFlexVotingClient(_governor));
  }
  function flexClient() public view override returns (MockFlexVotingClient) {
    return MockFlexVotingClient(client);
  }
}

contract TimestampClock__RawBalanceOf is _RawBalanceOf {
  function _timestampClock() internal pure override returns (bool) {
    return true;
  }
  function _deployClient(address _governor) internal override {
    client = address(new MockFlexVotingClient(_governor));
  }
  function flexClient() public view override returns (MockFlexVotingClient) {
    return MockFlexVotingClient(client);
  }
}

contract TimestampClock__CastVoteReasonString is _CastVoteReasonString {
  function _timestampClock() internal pure override returns (bool) {
    return true;
  }
  function _deployClient(address _governor) internal override {
    client = address(new MockFlexVotingClient(_governor));
  }
  function flexClient() public view override returns (MockFlexVotingClient) {
    return MockFlexVotingClient(client);
  }
}

contract TimestampClock__SelfDelegate is _SelfDelegate {
  function _timestampClock() internal pure override returns (bool) {
    return true;
  }
  function _deployClient(address _governor) internal override {
    client = address(new MockFlexVotingClient(_governor));
  }
  function flexClient() public view override returns (MockFlexVotingClient) {
    return MockFlexVotingClient(client);
  }
}

contract TimestampClock__CheckpointRawBalanceOf is _CheckpointRawBalanceOf {
  function _timestampClock() internal pure override returns (bool) {
    return true;
  }
  function _deployClient(address _governor) internal override {
    client = address(new MockFlexVotingClient(_governor));
  }
  function flexClient() public view override returns (MockFlexVotingClient) {
    return MockFlexVotingClient(client);
  }
}

contract TimestampClock_GetPastRawBalance is GetPastRawBalance {
  function _timestampClock() internal pure override returns (bool) {
    return true;
  }
  function _deployClient(address _governor) internal override {
    client = address(new MockFlexVotingClient(_governor));
  }
  function flexClient() public view override returns (MockFlexVotingClient) {
    return MockFlexVotingClient(client);
  }
}

contract TimestampClock__CheckpointTotalBalance is _CheckpointTotalBalance {
  function _timestampClock() internal pure override returns (bool) {
    return true;
  }
  function _deployClient(address _governor) internal override {
    client = address(new MockFlexVotingClient(_governor));
  }
  function flexClient() public view override returns (MockFlexVotingClient) {
    return MockFlexVotingClient(client);
  }
}

contract TimestampClock_GetPastTotalBalance is GetPastTotalBalance {
  function _timestampClock() internal pure override returns (bool) {
    return true;
  }
  function _deployClient(address _governor) internal override {
    client = address(new MockFlexVotingClient(_governor));
  }
  function flexClient() public view override returns (MockFlexVotingClient) {
    return MockFlexVotingClient(client);
  }
}

contract TimestampClock_Withdraw is Withdraw {
  function _timestampClock() internal pure override returns (bool) {
    return true;
  }
  function _deployClient(address _governor) internal override {
    client = address(new MockFlexVotingClient(_governor));
  }
  function flexClient() public view override returns (MockFlexVotingClient) {
    return MockFlexVotingClient(client);
  }
}

contract TimestampClock_Deposit is Deposit {
  function _timestampClock() internal pure override returns (bool) {
    return true;
  }
  function _deployClient(address _governor) internal override {
    client = address(new MockFlexVotingClient(_governor));
  }
  function flexClient() public view override returns (MockFlexVotingClient) {
    return MockFlexVotingClient(client);
  }
}

contract TimestampClock_ExpressVote is ExpressVote {
  function _timestampClock() internal pure override returns (bool) {
    return true;
  }
  function _deployClient(address _governor) internal override {
    client = address(new MockFlexVotingClient(_governor));
  }
  function flexClient() public view override returns (MockFlexVotingClient) {
    return MockFlexVotingClient(client);
  }
}

contract TimestampClock_CastVote is CastVote {
  function _timestampClock() internal pure override returns (bool) {
    return true;
  }
  function _deployClient(address _governor) internal override {
    client = address(new MockFlexVotingClient(_governor));
  }
  function flexClient() public view override returns (MockFlexVotingClient) {
    return MockFlexVotingClient(client);
  }
}

contract TimestampClock_Borrow is Borrow {
  function _timestampClock() internal pure override returns (bool) {
    return true;
  }
  function _deployClient(address _governor) internal override {
    client = address(new MockFlexVotingClient(_governor));
  }
  function flexClient() public view override returns (MockFlexVotingClient) {
    return MockFlexVotingClient(client);
  }
}

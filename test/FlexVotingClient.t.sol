// SPDX-License-Identifier: MIT
pragma solidity >=0.8.10;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {IVotes} from "@openzeppelin/contracts/governance/utils/IVotes.sol";

import {IVotingToken} from "../src/interfaces/IVotingToken.sol";
import {IFractionalGovernor} from "../src/interfaces/IFractionalGovernor.sol";
import {FlexVotingClient} from "../src/FlexVotingClient.sol";
import {MockFlexVotingClient} from "./MockFlexVotingClient.sol";
import {GovToken} from "./GovToken.sol";
import {FractionalGovernor} from "./FractionalGovernor.sol";
import {ProposalReceiverMock} from "./ProposalReceiverMock.sol";

contract FlexVotingClientTest is Test {
  FlexVotingClient flexClient;
  GovToken token;
  FractionalGovernor governor;
  ProposalReceiverMock receiver;

  function setUp() public {
    token = new GovToken();
    vm.label(address(token), "token");

    governor = new FractionalGovernor("Governor", IVotes(token));
    vm.label(address(governor), "governor");

    flexClient = FlexVotingClient(
      address(new MockFlexVotingClient(address(governor)))
     );
    vm.label(address(flexClient), "flexClient");

    receiver = new ProposalReceiverMock();
    vm.label(address(receiver), "receiver");
  }
}

contract Deployment is FlexVotingClientTest {
  function test_FlexVotingClientDeployment() public view {
    assertEq(token.name(), "Governance Token");
    assertEq(token.symbol(), "GOV");

    assertEq(address(flexClient.GOVERNOR()), address(governor));
    assertEq(token.delegates(address(flexClient)), address(flexClient));

    assertEq(governor.name(), "Governor");
    assertEq(address(governor.token()), address(token));
  }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {GovernorCountingFractional} from
  "@openzeppelin/contracts/governance/extensions/GovernorCountingFractional.sol";
import {GovernorVotes} from "@openzeppelin/contracts/governance/extensions/GovernorVotes.sol";
import {IVotes} from "@openzeppelin/contracts/governance/utils/IVotes.sol";
import {Governor} from "@openzeppelin/contracts/governance/Governor.sol";

contract FractionalGovernor is GovernorVotes, GovernorCountingFractional {
  constructor(string memory name_, IVotes token_) Governor(name_) GovernorVotes(token_) {}

  function quorum(uint256) public pure override returns (uint256) {
    return 10 ether;
  }

  function votingDelay() public pure override returns (uint256) {
    return 4;
  }

  function votingPeriod() public pure override returns (uint256) {
    return 50_400; // 50k blocks = 7 days assuming 12 second block times.
  }

  function exposed_quorumReached(uint256 _proposalId) public view returns (bool) {
    return _quorumReached(_proposalId);
  }

  function cancel(
    address[] memory targets,
    uint256[] memory values,
    bytes[] memory calldatas,
    bytes32 salt
  ) public override returns (uint256 proposalId) {
    return _cancel(targets, values, calldatas, salt);
  }
}

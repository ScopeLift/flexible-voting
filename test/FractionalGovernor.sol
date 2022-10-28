// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8.10;

import "../src/GovernorCountingFractional.sol";
import "openzeppelin-contracts/contracts/governance/extensions/GovernorVotes.sol";

contract FractionalGovernor is GovernorVotes, GovernorCountingFractional {
    constructor(string memory name_, IVotes token_) Governor(name_) GovernorVotes(token_) {}

    function quorum(uint256) public pure override returns (uint256) {
        return 10 ether;
    }

    function votingDelay() public pure override returns (uint256) {
        return 4;
    }

    function votingPeriod() public pure override returns (uint256) {
        return 50_400; // 7 days assuming 12 second block times
    }

    function cancel(
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        bytes32 salt
    ) public returns (uint256 proposalId) {
        return _cancel(targets, values, calldatas, salt);
    }
}

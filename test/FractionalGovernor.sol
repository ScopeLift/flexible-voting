// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8.10;

import "../src/GovernorCountingFractional.sol";
import "@openzeppelin/contracts/governance/extensions/GovernorVotes.sol";

contract FractionalGovernor is GovernorVotes, GovernorCountingFractional {
  constructor(string memory name_, IVotes token_) Governor(name_) GovernorVotes(token_) {}

  function castVoteWithReasonAndParamsBySig(
    uint256 proposalId,
    uint8 support,
    string calldata reason,
    bytes memory params,
    uint8 v,
    bytes32 r,
    bytes32 s
  ) public virtual override(GovernorCountingFractional, Governor) returns (uint256) {
    return GovernorCountingFractional.castVoteWithReasonAndParamsBySig(
      proposalId, support, reason, params, v, r, s
    );
  }

  function quorum(uint256) public pure override returns (uint256) {
    return 10 ether;
  }

  function votingDelay() public pure override returns (uint256) {
    return 4;
  }

  function votingPeriod() public pure override returns (uint256) {
    return 50_400; // 7 days assuming 12 second block times
  }

  function exposed_quorumReached(uint256 _proposalId) public view returns (bool) {
    return _quorumReached(_proposalId);
  }

  function exposed_setFractionalVoteNonce(address _voter, uint128 _newNonce) public {
    fractionalVoteNonce[_voter] = _newNonce;
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

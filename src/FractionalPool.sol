// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

interface IFractionalGovernor {
  function proposalSnapshot(uint256 proposalId) external returns (uint256);
  function castVoteWithReasonAndParams(
    uint256 proposalId,
    uint8 support,
    string calldata reason,
    bytes memory params
  ) external returns (uint256);
}

interface IVotingToken {
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function delegate(address delegatee) external;
}

contract FractionalPool {

    IVotingToken immutable public token;

    // TODO: way of tracking weights
    // Map depositor to deposit amount
    // mapping (address => uint256) deposits;
    // uint256 totalNetDeposits;

    constructor(IVotingToken _token) {
        token = _token;
        _token.delegate(address(this));
    }

    // TODO: deposit method (update fractional voting power)

    function deposit(uint256 _amount) public {
        token.transferFrom(msg.sender, address(this), _amount);
    }

    // TODO: withdrawal method (update fractional voting power)

    // TODO: express depositor voting preference method
    /* NEXT:
     *   - Test setup: Create proposal, propose it, advance to active state
     *   - Pool: Mechanism for tracking a depositors current weight (just a mapping?)
     *   - Test case: Depositor calls this new method, and is stored internally
     *   - Test: eventually someone calls method to express this on governor contract
     */

     // TODO: Execute the total vote against the governor contract

    // TODO: "borrow", i.e. removes funds from the pool, but is not a withdrawal, i.e. not returning
    // funds to a user that deposited them. Ex: someone borrowing from a compound pool.
}

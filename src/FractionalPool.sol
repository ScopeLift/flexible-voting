// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

interface IVotingToken {
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

contract FractionalPool {

    IVotingToken public token;

    constructor(IVotingToken _token) {
        token = _token;
    }

    // TODO: deposit method (update fractional voting power)

    function deposit(uint256 _amount) public {
        token.transferFrom(msg.sender, address(this), _amount);
    }

    // TODO: withdrawal method (update fractional voting power)

    // TODO: express voting preference method

    // TODO: "borrow", i.e. removes funds from the pool, but is not a withdrawal, i.e. not returning
    // funds to a user that deposited them. Ex: someone borrowing from a compound pool.
}

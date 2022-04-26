// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

interface IVotingToken { }

contract FractionalPool {

    IVotingToken public token;

    constructor(IVotingToken _token) {
        token = _token;
    }

    // TODO: deposit method (update fractional voting power)

    // TODO: withdrawal method (update fractional voting power)

    // TODO: express voting preference method

    // TODO: "borrow", i.e. removes funds from the pool, but is not a withdrawal, i.e. not returning
    // funds to a user that deposited them. Ex: someone borrowing from a compound pool.
}

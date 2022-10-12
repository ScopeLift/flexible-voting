# 💪🗳️ Flexible Voting: A Powerful Building Block for DAO Governance

Flexible Voting is an extension to the widely used OpenZeppelin DAO Governor that enables novel voting patterns for delegates. It is developed by [ScopeLift](https://scopelift.co), and was originally funded by a grant from the Uniswap Grant Program ([UGP](https://twitter.com/uniswapgrants)).

For a DAO that adopts it, the Flexible Governance extension allows delegates to split their voting weight across For/Against/Abstain options for a given proposal. This new building block allows arbitrary delegate contracts to be developed which can unlock all kinds of new use cases, such as:

  - Voting with tokens while earning yield in DeFi
  - Voting with tokens bridged to L2
  - Shielded voting (i.e. secret/private voting)
  - Cheaper subsidized signature based voting
  - Better voting options with tokens held by custodians

<div align="center">
	<img width="700" src="readme/flex-voting-diagram-transparent.png" alt="Flexible Voting Diagram">
	<br />
</div>

To learn more about Flexible Voting, and the use cases it enables, read the introduction on the [ScopeLift blog](https://www.scopelift.co/blog/introducing-flexible-voting).


## Repo Contents

* [`src/GovernorCountingFractional.sol`](https://github.com/ScopeLift/flexible-voting/blob/master/src/GovernorCountingFractional.sol) - The Governor extension which enables Flexible Voting. A DAO adopting Flexible Voting would deploy a new Governor which used this extension.
* [`src/FractionalPool.sol`](https://github.com/ScopeLift/flexible-voting/blob/master/src/FractionalPool.sol) - A proof-of-concept contract demonstrating how Flexible Voting can be used. It implements a Compound-Finance-like governance token pool that allows holders to express their votes on proposals even when their tokens are deposited in the pool.
* [`test/`](https://github.com/ScopeLift/flexible-voting/tree/master/test) - A full suite of unit and fuzz tests exercising the contracts.

## Development


This repo is built using [Foundry](https://github.com/foundry-rs/foundry)

1. [Install Foundry](https://github.com/foundry-rs/foundry#installation)
1. Install dependencies with `forge install`
1. Build the contracts with `forge build`
1. `cp .env.example .env` and edit `.env` with your keys
1. Run the test suite with `forge test`

## Contribute

ScopeLift is looking for help from the ecosystem to make Flexible Voting a reality for real DAOs. Here are some ways that you can contribute to its development and adoption:

* Help ScopeLift implement real-world, production ready use cases for the Flexible Voting extension
* Lobby your existing DAO community to adopt a Governor that uses the Flexible Voting extension
* Start a new DAO that uses a Flexible Voting enabled Governor from day 1
* Help update existing DAO tooling to directly support Flexible Voting

If you work with or in a community that could benefit from these tools, or you're interested in helping on the implementation, please [reach out](https://www.scopelift.co/contact).

Code contributions to this repo are also welcome! Fork the project, create a new branch from master, and open a PR. Ensure the project can be fast-forward merged by rebasing if necessary.

## License

Fractional Voting is available under the [MIT](LICENSE.txt) license.

Copyright (c) 2022 ScopeLift
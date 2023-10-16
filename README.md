# 💪🗳️ Flexible Voting: A Powerful Building Block for DAO Governance

Flexible Voting is an extension to the widely used OpenZeppelin DAO Governor that enables novel voting patterns for delegates. It is developed by [ScopeLift](https://scopelift.co), and was originally funded by a grant from the Uniswap Grant Program ([UGP](https://twitter.com/uniswapgrants)).

For a DAO that adopts it, the Flexible Governance extension allows delegates to split their voting weight across For/Against/Abstain options for a given proposal. This new building block allows arbitrary delegate contracts to be developed which can unlock all kinds of new use cases, such as:

 - Voting with tokens while earning yield in DeFi
 - Voting with tokens bridged to L2
 - Shielded voting (i.e. secret/private voting)
 - Liquid delegation and sub-delegation
 - Cheaper subsidized signature based voting
 - Voting with tokens held by a 3rd party custodian
 - Voting with tokens held in vesting contracts
 - And much more...

<div align="center">
	<img width="700" src="readme/flex-voting-diagram-transparent.png" alt="Flexible Voting Diagram">
	<br />
</div>

To learn more about Flexible Voting, and the use cases it enables:

 * Visit [flexiblevoting.com](https://flexiblevoting.com) to read the documentation.
 * Read about Flexible Voting on the [ScopeLift blog](https://scopelift.co/blog/tag/flexible-voting).

## Usage

To add Flexible Voting to your own Foundry project, use [forge install](https://book.getfoundry.sh/reference/forge/forge-install):

```bash
$ forge install scopelift/flexible-voting
```

If you're using a developer framework other than Foundry, we recommend vendoring the code by adding `src/GovernorCountingFractional.sol` and/or `src/FlexVotingClient.sol` to your repo directly. In the future, we may offer an npm package for use with other frameworks.

### Constructing a Governor

If you're constructing a new Governor with Flexible Voting—either to upgrade an existing DAO or to launch a new one—you'll want to extend `GovernorCountingFractional`.

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {GovernorVotes} from "@openzeppelin/contracts/governance/extensions/GovernorVotes.sol";
import {GovernorSettings} from "@openzeppelin/contracts/governance/extensions/GovernorSettings.sol";
import {GovernorTimelockControl} from
  "@openzeppelin/contracts/governance/extensions/GovernorTimelockControl.sol";
import {
  Governor, GovernorCountingFractional
} from "flexible-voting/src/GovernorCountingFractional.sol";

contract FlexibleVotingGovernor is
  GovernorCountingFractional,
  GovernorVotes,
  GovernorTimelockControl,
  GovernorSettings
{
  // The rest of the Governor implementation...
}
```

For more information on building a new Governor that includes Flexible Voting, see the documentation for [upgrading an existing DAO](https://flexiblevoting.com/docs/tutorials/existing-dao) or [launching a new DAO](https://flexiblevoting.com/docs/tutorials/new-dao).

### Creating a Voting Client Contract

If you're building a new Flexible Voting client—a contract that can be delegated votes and is able to cast them to a compatible Governor—you'll want to extend `FlexVotingClient`. Afterwards, you'll implement the `_rawBalanceOf(address)` method for your use case.

```solidity
import {FlexVotingClient} from "flexible-voting/src/FlexVotingClient.sol";

contract PoolClient is FlexVotingClient {
  constructor(address _governor) FlexVotingClient(_governor) {}

  function _rawBalanceOf(address _user) internal view virtual override returns (uint256) {
    // your implementation
  }
}
```

To learn more about how to create a novel Flexible Voting client contract, checkout the [tutorial](https://flexiblevoting.com/docs/tutorials/voting-client) in the documentation.

## Adoption

Flexible Voting has been adopted by a number of DAOs, including:

- [Gitcoin](https://github.com/gitcoinco/Alpha-Governor-Upgrade)
- [PoolTogether](https://github.com/ScopeLift/pooltogether-governor-upgrade)
- [Frax Finance](https://github.com/FraxFinance/frax-governance)

A number of Flexible Voting clients have been developed, including:

- [Aave Flexible Voting aToken](https://www.scopelift.co/blog/how-scopelift-built-a-flex-voting-atoken-on-aave)
- [Compound V3 Money Market](https://www.scopelift.co/blog/flexible-voting-on-compound)
- [Layer 2 Flexible Voting](https://github.com/ScopeLift/l2-flexible-voting)

To read more about Flexible Voting adoption, read the documentation pages on [compatible DAOs](https://flexiblevoting.com/docs/compatible-daos) and [existing clients](https://flexiblevoting.com/docs/existing-clients).


## Repo Contents

* [`src/GovernorCountingFractional.sol`](https://github.com/ScopeLift/flexible-voting/blob/master/src/GovernorCountingFractional.sol) - The Governor extension which enables Flexible Voting. A DAO adopting Flexible Voting would deploy a new Governor which used this extension.
* [`src/FlexVotingClient.sol`](https://github.com/ScopeLift/flexible-voting/blob/master/src/FlexVotingClient.sol) - An abstract contract designed to make it easy to build clients for Flexible Voting governors. Inherit from this contract if you're building an integration or voting scheme for DAO(s) that use Flexible Voting.
* [`src/FractionalPool.sol`](https://github.com/ScopeLift/flexible-voting/blob/master/src/FractionalPool.sol) - A proof-of-concept contract demonstrating how Flexible Voting can be used. It implements a simple token pool that allows holders to express their votes on proposals even when their tokens are deposited in the pool.
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

Copyright (c) 2023 ScopeLift
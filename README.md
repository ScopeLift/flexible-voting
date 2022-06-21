# Flexible Voting Governor Extension

An extension to the widely used OpenZeppelin DAO Governor that enables more flexible voting patterns for delegates. In particular, it allows delegates to split their voting weight fractionally across For, Against, or Abstain options.

This basic primitive opens up a wide range of exciting use cases for DAOs including:


* Voting when tokens are pooled, such as when deposited in Compound or other DeFi apps (see this [proof of concept](https://github.com/ScopeLift/vote-fractional-pool/blob/master/src/FractionalPool.sol)).
* Holders of bridged tokens voting on Layer 2 applied at Layer 1.
* Off chain gasless voting that is much cheaper to subsidize.
* Voting with tokens that are held by a custody provider.


## Development


This repo is built using [Foundry](https://github.com/foundry-rs/foundry)

1. [Install Foundry](https://github.com/foundry-rs/foundry#installation)
2. Install dependencies with `forge install`
3. Build the contracts with `forge build`
4. Run the test suite with `forge test`
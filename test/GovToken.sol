// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8.10;

import {ERC20Votes} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Votes.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/draft-ERC20Permit.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract GovToken is ERC20Votes {
  constructor() ERC20("Governance Token", "GOV") ERC20Permit("GOV") {}

  function exposed_mint(address to, uint256 amount) public {
    _mint(to, amount);
  }

  function exposed_maxSupply() external view returns (uint256) {
    return uint256(_maxSupply());
  }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC20Votes} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Votes.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Nonces} from "@openzeppelin/contracts/utils/Nonces.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

contract GovToken is ERC20, ERC20Permit, ERC20Votes {
  constructor() ERC20("Governance Token", "GOV") ERC20Permit("GOV") {}

  function exposed_mint(address to, uint256 amount) public {
    _mint(to, amount);
  }

  function exposed_maxSupply() external view returns (uint256) {
    return uint256(_maxSupply());
  }

  function _update(address from, address to, uint256 amount) internal override(ERC20, ERC20Votes) {
    ERC20Votes._update(from, to, amount);
  }

  function nonces(address owner)
    public
    view
    virtual
    override(ERC20Permit, Nonces)
    returns (uint256)
  {
    return Nonces.nonces(owner);
  }
}

contract TimestampGovToken is GovToken {
  function clock() public view virtual override returns (uint48) {
    return SafeCast.toUint48(block.timestamp);
  }

  function CLOCK_MODE() public pure virtual override returns (string memory) {
    return "mode=timestamp";
  }
}

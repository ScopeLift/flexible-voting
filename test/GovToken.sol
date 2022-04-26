import { ERC20Votes } from "openzeppelin-contracts/contracts/token/ERC20/extensions/ERC20Votes.sol";
import { ERC20Permit } from "openzeppelin-contracts/contracts/token/ERC20/extensions/draft-ERC20Permit.sol";
import { ERC20 } from "openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";

contract GovToken is ERC20Votes {

    constructor() ERC20("Governance Token", "GOV") ERC20Permit("GOV") { }
}
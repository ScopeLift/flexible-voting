// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import { DSTestPlus } from "solmate/test/utils/DSTestPlus.sol";
import { Vm } from "forge-std/Vm.sol";
import "../src/FractionalPool.sol";
import "./GovToken.sol";
import "./FractionalGovernor.sol";


contract FractionalPoolTest is DSTestPlus {
    Vm vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    FractionalPool pool;
    GovToken token;
    FractionalGovernor governor;

    function setUp() public {
        pool = new FractionalPool();
        vm.label(address(pool), "pool");

        token = new GovToken();
        vm.label(address(token), "token");

        governor = new FractionalGovernor("Governor", IVotes(token));
        vm.label(address(governor), "governor");
    }
}

contract Deployment is FractionalPoolTest {

    function test_FractionalPoolDeployment() public {
        assertEq(token.name(), "Governance Token");
        assertEq(token.symbol(), "GOV");

        assertEq(governor.name(), "Governor");
        assertEq(address(governor.token()), address(token));
    }
}
// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import { DSTestPlus } from "solmate/test/utils/DSTestPlus.sol";
import { Vm } from "forge-std/Vm.sol";
import "../src/FractionalPool.sol";
import "./GovToken.sol";


contract FractionalPoolTest is DSTestPlus {
    Vm vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    FractionalPool pool;
    GovToken gov;

    function setUp() public {
        pool = new FractionalPool();
        vm.label(address(pool), "pool");

        gov = new GovToken();
        vm.label(address(gov), "gov");
    }
}

contract Deployment is FractionalPoolTest {

    function test_FractionalPoolDeployment() public {
        assertEq(gov.name(), "Governance Token");
        assertEq(gov.symbol(), "GOV");
    }
}
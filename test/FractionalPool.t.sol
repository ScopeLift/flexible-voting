// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import { DSTestPlus } from "solmate/test/utils/DSTestPlus.sol";
import { Vm } from "forge-std/Vm.sol";
import { FractionalPool, IVotingToken } from "../src/FractionalPool.sol";
import "./GovToken.sol";
import "./FractionalGovernor.sol";


contract FractionalPoolTest is DSTestPlus {
    Vm vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    FractionalPool pool;
    GovToken token;
    FractionalGovernor governor;

    function setUp() public {
        token = new GovToken();
        vm.label(address(token), "token");

        pool = new FractionalPool(IVotingToken(address(token)));
        vm.label(address(pool), "pool");

        governor = new FractionalGovernor("Governor", IVotes(token));
        vm.label(address(governor), "governor");
    }

    function mintGovAndApprovePool(address _holder, uint256 _amount) public {
        vm.assume(_holder != address(0));
        token.mint(_holder, _amount);
        vm.prank(_holder);
        token.approve(address(pool), type(uint256).max);
    }
}

contract Deployment is FractionalPoolTest {

    function test_FractionalPoolDeployment() public {
        assertEq(token.name(), "Governance Token");
        assertEq(token.symbol(), "GOV");

        assertEq(address(pool.token()), address(token));

        assertEq(governor.name(), "Governor");
        assertEq(address(governor.token()), address(token));
    }
}

contract Deposit is FractionalPoolTest {

    function test_UserCanDepositGovTokens(address _holder, uint256 _amount) public {
        _amount = bound(_amount, 0, type(uint224).max);
        uint256 initialBalance = token.balanceOf(_holder);
        mintGovAndApprovePool(_holder, _amount);

        vm.prank(_holder);
        pool.deposit(_amount);

        assertEq(token.balanceOf(address(pool)), _amount);
        assertEq(token.balanceOf(_holder), initialBalance);
    }
}
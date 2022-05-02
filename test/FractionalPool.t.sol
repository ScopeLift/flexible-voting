// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import { DSTestPlus } from "solmate/test/utils/DSTestPlus.sol";
import { Vm } from "forge-std/Vm.sol";
import { FractionalPool, IVotingToken, IFractionalGovernor } from "../src/FractionalPool.sol";
import "./GovToken.sol";
import "./FractionalGovernor.sol";
import "./ProposalReceiverMock.sol";


contract FractionalPoolTest is DSTestPlus {
    enum ProposalState {
        Pending,
        Active,
        Canceled,
        Defeated,
        Succeeded,
        Queued,
        Expired,
        Executed
    }

    enum VoteType {
        Against,
        For,
        Abstain
    }

    Vm vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    FractionalPool pool;
    GovToken token;
    FractionalGovernor governor;
    ProposalReceiverMock receiver;

    function setUp() public {
        token = new GovToken();
        vm.label(address(token), "token");

        governor = new FractionalGovernor("Governor", IVotes(token));
        vm.label(address(governor), "governor");

        pool = new FractionalPool(IVotingToken(address(token)), IFractionalGovernor(address(governor)));
        vm.label(address(pool), "pool");

        receiver = new ProposalReceiverMock();
        vm.label(address(receiver), "receiver");
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
        assertEq(token.delegates(address(pool)), address(pool));

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
        assertEq(token.getVotes(address(pool)), _amount);
    }
}

contract Vote is FractionalPoolTest {

    function testFuzz_userCanCastVotes(address _hodler, uint256 _voteWeight) public {
        // TODO pull this stuff into helpers

        // deposit some funds
        // This max is a limitation of the fractional governance protocol storage
        _voteWeight = bound(_voteWeight, 1, type(uint128).max);
        vm.assume(_hodler != address(pool));
        uint256 initialBalance = token.balanceOf(_hodler);
        mintGovAndApprovePool(_hodler, _voteWeight);
        vm.prank(_hodler);
        pool.deposit(_voteWeight);

        // TODO make sure governor.proposalThreshold() is crossed??

        // create a proposal
        bytes memory receiverCallData = abi.encodeWithSignature("mockReceiverFunction()");
        address[] memory targets = new address[](1);
        uint256[] memory values = new uint256[](1);
        bytes[] memory calldatas = new bytes[](1);
        targets[0] = address(receiver);
        values[0] = 0; // no ETH will be sent
        calldatas[0] = receiverCallData;

        // submit the proposal
        if (block.number == 0) vm.roll(42); // proposal will underflow if we're on the zero block
        uint256 proposalId = governor.propose(
          targets,
          values,
          calldatas,
          "A great proposal"
        );
        assertEq(uint(governor.state(proposalId)), uint(ProposalState.Pending));

        // advance proposal to active state
        vm.roll(governor.proposalSnapshot(proposalId) + 1);
        assertEq(uint(governor.state(proposalId)), uint(ProposalState.Active));

        // _holder should now be able to express his/her vote on the proposal
        vm.prank(_hodler);
        pool.expressVote(proposalId, uint8(VoteType.For));
        (
          uint256 _againstVotesExpressed,
          uint256 _forVotesExpressed,
          uint256 _abstainVotesExpressed
        ) = pool.proposalVotes(proposalId);
        assertEq(_forVotesExpressed, _voteWeight);
        assertEq(_againstVotesExpressed, 0);
        assertEq(_abstainVotesExpressed, 0);

        // submit votes on behalf of the pool
        // governor should now record votes for the pool
        (uint256 _againstVotes, uint256 _forVotes, uint256 _abstainVotes) = governor.proposalVotes(proposalId);
        assertEq(_forVotes, 0);
        assertEq(_againstVotes, 0);
        assertEq(_abstainVotes, 0);

        pool.castVote(proposalId);

        (_againstVotes, _forVotes, _abstainVotes) = governor.proposalVotes(proposalId);
        assertEq(_forVotes, _voteWeight);
        assertEq(_againstVotes, 0);
        assertEq(_abstainVotes, 0);

        // advance past proposal deadline
        vm.roll(governor.proposalDeadline(proposalId) + 1);
    }



}

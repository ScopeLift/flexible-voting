// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "openzeppelin-contracts/contracts/utils/math/SafeCast.sol";
import "openzeppelin-contracts/contracts/utils/math/Math.sol";

interface IFractionalGovernor {
  function proposalSnapshot(uint256 proposalId) external returns (uint256);
  function proposalDeadline(uint256 proposalId) external returns (uint256);
  function castVoteWithReasonAndParams(
    uint256 proposalId,
    uint8 support,
    string calldata reason,
    bytes memory params
  ) external returns (uint256);
}

interface IVotingToken {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function delegate(address delegatee) external;
    function getPastVotes(address account, uint256 blockNumber) external returns (uint256);
}

contract FractionalPool {
    enum VoteType {
        Against,
        For,
        Abstain
    }

    IVotingToken immutable public token;

    IFractionalGovernor governor;

    // Map depositor to deposit amount
    mapping (address => uint256) public deposits;

    // borrower -> total amount borrowed
    mapping (address => uint256) public borrowTotal;

    // proposalId => (address => whether they have voted)
    mapping(uint256 => mapping(address => bool)) private _proposalVotersHasVoted;

    struct ProposalVote {
        uint128 againstVotes;
        uint128 forVotes;
        uint128 abstainVotes;
    }

    mapping(uint256 => ProposalVote) public proposalVotes;

    constructor(IVotingToken _token, IFractionalGovernor _governor) {
        token = _token;
        governor = _governor;
        _token.delegate(address(this));
    }

    function deposit(uint256 _amount) public {
        deposits[msg.sender] += _amount;

        _writeCheckpoint(_checkpoints[msg.sender], _additionFn, _amount);
        _writeCheckpoint(_totalDepositCheckpoints, _additionFn, _amount);

        token.transferFrom(msg.sender, address(this), _amount);
    }

    // TODO: withdrawal method (update fractional voting power)
      // totalNetDeposits -= _amount;

     function expressVote(uint256 proposalId, uint8 support) external {
         uint256 weight = getPastDeposits(msg.sender, governor.proposalSnapshot(proposalId));
         if (weight == 0) revert("no weight");

         if (_proposalVotersHasVoted[proposalId][msg.sender]) revert("already voted");
         _proposalVotersHasVoted[proposalId][msg.sender] = true;

         if (support == uint8(VoteType.Against)) {
             proposalVotes[proposalId].againstVotes += SafeCast.toUint128(weight);
         } else if (support == uint8(VoteType.For)) {
             proposalVotes[proposalId].forVotes += SafeCast.toUint128(weight);
         } else if (support == uint8(VoteType.Abstain)) {
             proposalVotes[proposalId].abstainVotes += SafeCast.toUint128(weight);
         } else {
             revert("invalid support value, must be included in VoteType enum");
         }
     }

     // Must call castVote within 20 blocks of the proposal deadline. This is done so as
     // to prevent someone from calling expressVote and then castVote immediately after,
     // effectively blocking anyone else in the pool from voting.
     uint32 constant public CAST_VOTE_WINDOW = 20; // blocks

     function castVote(uint256 proposalId) external {
       if (internalVotingPeriodEnd(proposalId) > block.number) revert("cannot castVote yet");
       uint8 unusedSupportParam = uint8(VoteType.Abstain);
       ProposalVote memory _proposalVote = proposalVotes[proposalId];

       uint256 _proposalSnapshotBlockNumber = governor.proposalSnapshot(proposalId);

       // Use the snapshot of total deposits to determine total voting weight. We cannot
       // use the proposalVote numbers alone, since some people with deposits at the
       // snapshot might not have expressed votes.
       uint256 _totalDepositWeightAtSnapshot = getPastTotalDeposits(_proposalSnapshotBlockNumber);

       // We need 256 bits because of the multiplication we're about to do.
       uint256 _votingWeightAtSnapshot = token.getPastVotes(address(this), _proposalSnapshotBlockNumber);

       //      forVotesRaw          forVotesScaled
       // --------------------- = ---------------------
       //     totalDeposits        deposits (@snapshot)
       //
       // forVotesScaled = forVotesRaw * deposits@snapshot / totalDeposits
       uint128 _forVotesToCast = SafeCast.toUint128(
         (_votingWeightAtSnapshot * _proposalVote.forVotes) / _totalDepositWeightAtSnapshot
       );
       uint128 _againstVotesToCast = SafeCast.toUint128(
         (_votingWeightAtSnapshot * _proposalVote.againstVotes) / _totalDepositWeightAtSnapshot
       );
       uint128 _abstainVotesToCast = SafeCast.toUint128(
         (_votingWeightAtSnapshot * _proposalVote.abstainVotes) / _totalDepositWeightAtSnapshot
       );

       bytes memory fractionalizedVotes = abi.encodePacked(
         _forVotesToCast,
         _againstVotesToCast,
         _abstainVotesToCast
       );
       governor.castVoteWithReasonAndParams(
         proposalId,
         unusedSupportParam,
         'crowd-sourced vote',
         fractionalizedVotes
       );
     }

     function internalVotingPeriodEnd(uint256 proposalId) public returns(uint256 _lastVotingBlock) {
       _lastVotingBlock = governor.proposalDeadline(proposalId) - CAST_VOTE_WINDOW;
     }

    // Remove funds from the pool, but is not a withdrawal, i.e. not returning
    // funds to a user that deposited them. Ex: someone borrowing from a compound pool.
    function borrow(uint256 _amount) public {
        borrowTotal[msg.sender] += _amount;
        token.transfer(msg.sender, _amount);
    }


    //===========================================================================
    // BEGIN: Checkpointing code.
    //===========================================================================
    // This has been copied from OZ's ERC20Votes checkpointing system with minor revisions:
    //   * Replace "Vote" with "Deposit", as deposits are what we need to track
    //   * Make some variable names longer for readibility
    struct Checkpoint {
        uint32 fromBlock;
        uint224 deposits;
    }
    mapping(address => Checkpoint[]) private _checkpoints;
    Checkpoint[] private _totalDepositCheckpoints;
    function checkpoints(address account, uint32 pos) public view virtual returns (Checkpoint memory) {
        return _checkpoints[account][pos];
    }
    function getDeposits(address account) public view virtual returns (uint256) {
        uint256 pos = _checkpoints[account].length;
        return pos == 0 ? 0 : _checkpoints[account][pos - 1].deposits;
    }
    function getPastDeposits(address account, uint256 blockNumber) public view virtual returns (uint256) {
        require(blockNumber < block.number, "block not yet mined");
        return _checkpointsLookup(_checkpoints[account], blockNumber);
    }
    function getPastTotalDeposits(uint256 blockNumber) public view virtual returns (uint256) {
        require(blockNumber < block.number, "block not yet mined");
        return _checkpointsLookup(_totalDepositCheckpoints, blockNumber);
    }
    function _checkpointsLookup(Checkpoint[] storage ckpts, uint256 blockNumber) private view returns (uint256) {
        // We run a binary search to look for the earliest checkpoint taken after `blockNumber`.
        uint256 high = ckpts.length;
        uint256 low = 0;
        while (low < high) {
            uint256 mid = Math.average(low, high);
            if (ckpts[mid].fromBlock > blockNumber) {
                high = mid;
            } else {
                low = mid + 1;
            }
        }
        return high == 0 ? 0 : ckpts[high - 1].deposits;
    }
    function _writeCheckpoint(
        Checkpoint[] storage ckpts,
        function(uint256, uint256) view returns (uint256) operation,
        uint256 delta
    ) private returns (uint256 oldWeight, uint256 newWeight) {
        uint256 position = ckpts.length;
        oldWeight = position == 0 ? 0 : ckpts[position - 1].deposits;
        newWeight = operation(oldWeight, delta);

        if (position > 0 && ckpts[position - 1].fromBlock == block.number) {
            ckpts[position - 1].deposits = SafeCast.toUint224(newWeight);
        } else {
            ckpts.push(Checkpoint({fromBlock: SafeCast.toUint32(block.number), deposits: SafeCast.toUint224(newWeight)}));
        }
    }
    function _additionFn(uint256 a, uint256 b) private pure returns (uint256) {
        return a + b;
    }

    function _subtractionFn(uint256 a, uint256 b) private pure returns (uint256) {
        return a - b;
    }
    //===========================================================================
    // END: Checkpointing code.
    //===========================================================================
}

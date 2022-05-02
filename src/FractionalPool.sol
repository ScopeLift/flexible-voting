// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

interface IFractionalGovernor {
  function proposalSnapshot(uint256 proposalId) external returns (uint256);
  function castVoteWithReasonAndParams(
    uint256 proposalId,
    uint8 support,
    string calldata reason,
    bytes memory params
  ) external returns (uint256);
}

interface IVotingToken {
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
    mapping (address => uint256) deposits;
    uint256 totalNetDeposits;

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

    // TODO: deposit method (update fractional voting power)
    function deposit(uint256 _amount) public {
        deposits[msg.sender] += _amount;
        totalNetDeposits += _amount;
        token.transferFrom(msg.sender, address(this), _amount);
    }

    // TODO: withdrawal method (update fractional voting power)
      // totalNetDeposits -= _amount;

    // TODO: express depositor voting preference method
    /* NEXT:
     *   - Test setup: Create proposal, propose it, advance to active state
     *   - Pool: Mechanism for tracking a depositors current weight (just a mapping?)
     *   - Test case: Depositor calls this new method, and is stored internally
     *   - Test: eventually someone calls method to express this on governor contract
     */
     function expressVote(uint256 proposalId, uint8 support) external {
       // TODO:
       // pull the proposal info based on the ID
       // confirm there was weight for msg.sender at the proposal snapshot
       // make sure multiple votes for the same sender overwrite each other
       // we need to track weight deposited *here*
       // safecast weight
        uint256 weight = deposits[msg.sender];

        if (support == uint8(VoteType.Against)) {
            proposalVotes[proposalId].againstVotes += uint128(weight);
        } else if (support == uint8(VoteType.For)) {
            proposalVotes[proposalId].forVotes += uint128(weight);
        } else if (support == uint8(VoteType.Abstain)) {
            proposalVotes[proposalId].abstainVotes += uint128(weight);
        } else {
            revert("invalid support value, must be included in VoteType enum");
        }
     }

     // TODO: Execute the total vote against the governor contract
     function castVote(uint256 proposalId) external {
       // TODO: create some public variable to indicate window during which votes will be submitted
       // TODO is the proposal within the submission window?
       uint8 unusedSupportParam = uint8(VoteType.Abstain);
       ProposalVote memory _proposalVote = proposalVotes[proposalId];
       bytes memory fractionalizedVotes = abi.encodePacked(_proposalVote.forVotes, _proposalVote.againstVotes);
       governor.castVoteWithReasonAndParams(
         proposalId,
         unusedSupportParam,
         'crowd-sourced vote',
         fractionalizedVotes
       );
     }

    // TODO: "borrow", i.e. removes funds from the pool, but is not a withdrawal, i.e. not returning
    // funds to a user that deposited them. Ex: someone borrowing from a compound pool.
}

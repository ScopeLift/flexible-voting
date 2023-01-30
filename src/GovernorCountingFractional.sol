// SPDX-License-Identifier: MIT
// OpenZeppelin Contracts v4.X.X (governance/extensions/GovernorCountingFractional.sol)

pragma solidity ^0.8.0;

// Disabling forgefmt to stay consistent with OZ's style.
// forgefmt: disable-start

import {Governor} from "openzeppelin-contracts/contracts/governance/Governor.sol";
import {GovernorCompatibilityBravo} from "openzeppelin-contracts/contracts/governance/compatibility/GovernorCompatibilityBravo.sol";
import {SafeCast} from "openzeppelin-contracts/contracts/utils/math/SafeCast.sol";

/**
 * @notice Extension of {Governor} for 3 option fractional vote counting. When voting, a delegate may split their vote
 * weight between For/Against/Abstain. This is most useful when the delegate is itself a contract, implementing its own
 * rules for voting. By allowing a contract-delegate to split its vote weight, the voting preferences of many disparate
 * token holders can be rolled up into a single vote to the Governor itself. Some example use cases include voting with
 * tokens that are held by a DeFi pool, voting from L2 with tokens held by a bridge, or voting privately from a
 * shielded pool using zero knowledge proofs.
 */
abstract contract GovernorCountingFractional is Governor {

    struct ProposalVote {
        uint128 againstVotes;
        uint128 forVotes;
        uint128 abstainVotes;
    }

    function _totalProposalVoteWeights(ProposalVote memory _vote) internal view returns(uint256) {
      return uint256(_vote.againstVotes) + _vote.forVotes + _vote.abstainVotes;
    }

    /**
     * @dev Mapping from proposal ID to vote tallies for that proposal.
     */
    mapping(uint256 => ProposalVote) private _proposalVotes;

    /**
     * @dev Mapping from proposal ID and address to the votes the address
     * has cast on that proposal, e.g. _proposalVotesCast[42][0xBEEF]
     * would tell you the number of against/for/abstain votes that 0xBEEF has
     * cast on proposal 42.
     */
    mapping(uint256 => mapping(address => ProposalVote)) private _proposalVotesCast;

    /**
     * @dev See {IGovernor-COUNTING_MODE}.
     */
    // solhint-disable-next-line func-name-mixedcase
    function COUNTING_MODE() public pure virtual override returns (string memory) {
        return "support=bravo&quorum=bravo&params=fractional";
    }

    /**
     * @dev See {IGovernor-hasVoted}.
     */
    function hasVoted(uint256 proposalId, address account) public view virtual override returns (bool) {
        (uint againstVotes, uint forVotes, uint abstainVotes) = proposalVotes(proposalId, account);
        return againstVotes + forVotes + abstainVotes > 0;
    }

    /**
     * @dev Accessor to the internal vote counts.
     */
    function proposalVotes(uint256 proposalId)
        public
        view
        virtual
        returns (
            uint256 againstVotes,
            uint256 forVotes,
            uint256 abstainVotes
        )
    {
        ProposalVote storage proposalVote = _proposalVotes[proposalId];
        return (proposalVote.againstVotes, proposalVote.forVotes, proposalVote.abstainVotes);
    }

    /**
     * @dev Accessor to the internal vote counts by address.
     */
    function proposalVotes(uint256 proposalId, address voter)
        public
        view
        virtual
        returns (
            uint256 againstVotes,
            uint256 forVotes,
            uint256 abstainVotes
        )
    {
        ProposalVote storage proposalVote = _proposalVotesCast[proposalId][voter];
        return (proposalVote.againstVotes, proposalVote.forVotes, proposalVote.abstainVotes);
    }

    /**
     * @dev See {Governor-_quorumReached}.
     */
    function _quorumReached(uint256 proposalId) internal view virtual override returns (bool) {
        ProposalVote storage proposalvote = _proposalVotes[proposalId];

        return quorum(proposalSnapshot(proposalId)) <= proposalvote.forVotes;
    }

    /**
     * @dev See {Governor-_voteSucceeded}. In this module, forVotes must be > againstVotes.
     */
    function _voteSucceeded(uint256 proposalId) internal view virtual override returns (bool) {
        ProposalVote storage proposalvote = _proposalVotes[proposalId];

        return proposalvote.forVotes > proposalvote.againstVotes;
    }

    /**
     * @notice See {Governor-_countVote}.
     *
     * If the `voteData` bytes parameter is empty, then this module behaves
     * identically to GovernorBravo. That is, it assigns the full weight of the delegate to the `support` parameter,
     * which follows the `VoteType` enum from Governor Bravo.
     *
     * If the `voteData` bytes parameter is not zero, then it _must_ be three packed uint128s, totaling 48 bytes,
     * representing the weight the delegate assigns to For, Against, and Abstain respectively, i.e.
     * encodePacked(forVotes, againstVotes, abstainVotes). The sum total of the three decoded vote weights _must_ be
     * less than or equal to the delegate's total weight as check-pointed for the proposal being voted on.
     */
    function _countVote(
        uint256 proposalId,
        address account,
        uint8 support,
        uint256 weight,
        bytes memory voteData
    ) internal virtual override {
        require(weight > 0, "GovernorCountingFractional: no weight");
        ProposalVote storage _vote = _proposalVotesCast[proposalId][account];

        if ( _totalProposalVoteWeights(_vote) >= weight) {
          revert("GovernorCountingFractional: all weight cast");
        }

        uint128 safeWeight = SafeCast.toUint128(weight);

        if (voteData.length == 0) {
            _countVoteNominal(proposalId, _vote, safeWeight, support);
        } else {
            _countVoteFractional(proposalId, _vote, account, safeWeight, voteData);
        }
    }

    /**
     * @dev Count votes with full weight
     */
    function _countVoteNominal(
        uint256 proposalId,
        ProposalVote storage _vote,
        uint128 weight,
        uint8 support
    ) internal {
        // Nominal voting uses all weight, so previous partial votes are
        // disallowed.
        require(
            _totalProposalVoteWeights(_vote) == 0,
            "GovernorCountingFractional: vote would exceed weight"
        );

        if (support == uint8(GovernorCompatibilityBravo.VoteType.Against)) {
            _vote.againstVotes = weight;
            _proposalVotes[proposalId].againstVotes += weight;
        } else if (support == uint8(GovernorCompatibilityBravo.VoteType.For)) {
            _vote.forVotes = weight;
            _proposalVotes[proposalId].forVotes += weight;
        } else if (support == uint8(GovernorCompatibilityBravo.VoteType.Abstain)) {
            _vote.abstainVotes = weight;
            _proposalVotes[proposalId].abstainVotes += weight;
        } else {
            revert("GovernorCountingFractional: invalid support value, must be included in VoteType enum");
        }
    }

    /**
     * @dev Count votes with fractional weight.
     *
     * We expect `voteData` to be three packed uint128s, i.e. encodePacked(forVotes, againstVotes, abstainVotes)
     */
    function _countVoteFractional(
        uint256 proposalId,
        ProposalVote storage _storedVote,
        address account,
        uint128 weight,
        bytes memory voteData
    ) internal {
        require(voteData.length == 48, "GovernorCountingFractional: invalid voteData");

        ProposalVote memory _newVote = _decodePackedVotes(voteData);
        uint256 _newWeight = _totalProposalVoteWeights(_newVote);

        require(_newWeight <= weight, "GovernorCountingFractional: vote would exceed weight");

        require(_storedVote.againstVotes <= _newVote.againstVotes, "cannot undo past votes");
        require(_storedVote.forVotes <= _newVote.forVotes, "cannot undo past votes");
        require(_storedVote.abstainVotes <= _newVote.abstainVotes, "cannot undo past votes");

        // How many votes are we adding here?
        ProposalVote memory _voteDelta;
        _voteDelta.againstVotes = _newVote.againstVotes - _storedVote.againstVotes;
        _voteDelta.forVotes = _newVote.forVotes - _storedVote.forVotes;
        _voteDelta.abstainVotes = _newVote.abstainVotes - _storedVote.abstainVotes;

        // Update the voter's vote balances.
        _storedVote.againstVotes = _newVote.againstVotes;
        _storedVote.forVotes = _newVote.forVotes;
        _storedVote.abstainVotes = _newVote.abstainVotes;

        // TODO it would be good to have an invariant test to confirm that the
        // overall talley always equals the sum of the individual totals

        // Update the overall vote talley.
        ProposalVote memory _overallVoteTalley = _proposalVotes[proposalId];
        _overallVoteTalley = ProposalVote(
            _overallVoteTalley.againstVotes + _voteDelta.againstVotes,
            _overallVoteTalley.forVotes + _voteDelta.forVotes,
            _overallVoteTalley.abstainVotes + _voteDelta.abstainVotes
        );

        _proposalVotes[proposalId] = _overallVoteTalley;
    }

    uint256 constant internal _VOTEMASK = 0xffffffffffffffffffffffffffffffff; // 128 bits of 0's, 128 bits of 1's

    /**
     * @dev Decodes three packed uint128's. Uses assembly because of Solidity language limitation which prevents
     * slicing bytes stored in memory, rather than calldata.
     */
    function _decodePackedVotes(bytes memory voteData)
        internal
        pure
        returns (ProposalVote memory _vote)
    {
        uint128 forVotes;
        uint128 againstVotes;
        uint128 abstainVotes;

        assembly {
            forVotes := shr(128, mload(add(voteData, 0x20)))
            againstVotes := and(_VOTEMASK, mload(add(voteData, 0x20)))
            abstainVotes := shr(128, mload(add(voteData, 0x40)))
        }

        _vote.forVotes = forVotes;
        _vote.againstVotes = againstVotes;
        _vote.abstainVotes = abstainVotes;
    }
}
// forgefmt: disable-end

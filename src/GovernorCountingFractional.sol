// SPDX-License-Identifier: MIT
// OpenZeppelin Contracts v4.X.X (governance/extensions/GovernorCountingFractional.sol)

pragma solidity ^0.8.0;

import "openzeppelin-contracts/contracts/governance/Governor.sol";
import "openzeppelin-contracts/contracts/governance/compatibility/GovernorCompatibilityBravo.sol";
import "openzeppelin-contracts/contracts/utils/math/SafeCast.sol";

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

    mapping(uint256 => ProposalVote) private _proposalVotes;
    mapping(uint256 => mapping(address => bool)) private _proposalVotersHasVoted;

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
        return _proposalVotersHasVoted[proposalId][account];
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
        ProposalVote storage proposalvote = _proposalVotes[proposalId];
        return (proposalvote.againstVotes, proposalvote.forVotes, proposalvote.abstainVotes);
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
        require(!_proposalVotersHasVoted[proposalId][account], "GovernorCountingFractional: vote already cast");
        _proposalVotersHasVoted[proposalId][account] = true;

        if (voteData.length == 0) {
            _countVoteNominal(proposalId, support, weight);
        } else {
            _countVoteFractional(proposalId, weight, voteData);
        }
    }

    /**
     * @dev Count votes with full weight
     */
    function _countVoteNominal(
        uint256 proposalId,
        uint8 support,
        uint256 weight
    ) internal {
        if (support == uint8(GovernorCompatibilityBravo.VoteType.Against)) {
            _proposalVotes[proposalId].againstVotes += SafeCast.toUint128(weight);
        } else if (support == uint8(GovernorCompatibilityBravo.VoteType.For)) {
            _proposalVotes[proposalId].forVotes += SafeCast.toUint128(weight);
        } else if (support == uint8(GovernorCompatibilityBravo.VoteType.Abstain)) {
            _proposalVotes[proposalId].abstainVotes += SafeCast.toUint128(weight);
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
        uint256 weight,
        bytes memory voteData
    ) internal {
        require(voteData.length == 48, "GovernorCountingFractional: invalid voteData");

        (uint128 forVotes, uint128 againstVotes, uint128 abstainVotes) = _decodePackedVotes(voteData);

        require(
            uint256(forVotes) + againstVotes + abstainVotes <= uint128(weight),
            "GovernorCountingFractional: votes exceed weight"
        );

        ProposalVote memory _proposalVote = _proposalVotes[proposalId];
        _proposalVote = ProposalVote(
            _proposalVote.againstVotes + againstVotes,
            _proposalVote.forVotes + forVotes,
            _proposalVote.abstainVotes + abstainVotes
        );

        _proposalVotes[proposalId] = _proposalVote;
    }

    uint256 constant internal _VOTEMASK = 0xffffffffffffffffffffffffffffffff; // 128 bits of 0's, 128 bits of 1's

    /**
     * @dev Decodes three packed uint128's. Uses assembly because of Solidity language limitation which prevents
     * slicing bytes stored in memory, rather than calldata.
     */
    function _decodePackedVotes(bytes memory voteData)
        internal
        pure
        returns (
            uint128 forVotes,
            uint128 againstVotes,
            uint128 abstainVotes
        )
    {
        assembly {
            forVotes := shr(128, mload(add(voteData, 0x20)))
            againstVotes := and(_VOTEMASK, mload(add(voteData, 0x20)))
            abstainVotes := shr(128, mload(add(voteData, 0x40)))
        }
    }
}

// SPDX-License-Identifier: MIT
// OpenZeppelin Contracts v4.X.X (governance/extensions/GovernorCountingFractional.sol)

pragma solidity ^0.8.0;

import "../Governor.sol";
import "../compatibility/GovernorCompatibilityBravo.sol";
import "../../utils/math/SafeCast.sol";

/**
 * @dev Extension of {Governor} for 3 option fractional vote counting.
 *
 * _Available since v4.X.X_
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
     * @dev See {Governor-_countVote}. In this module, the support follows the `VoteType` enum (from Governor Bravo).
     * TODO: Add note for how params is used
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

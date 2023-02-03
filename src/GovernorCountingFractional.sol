// SPDX-License-Identifier: MIT
// OpenZeppelin Contracts v4.X.X (governance/extensions/GovernorCountingFractional.sol)

pragma solidity ^0.8.0;

// Disabling forgefmt to stay consistent with OZ's style.
// forgefmt: disable-start

import {Governor} from "openzeppelin-contracts/governance/Governor.sol";
import {GovernorCompatibilityBravo} from "openzeppelin-contracts/governance/compatibility/GovernorCompatibilityBravo.sol";
import {SafeCast} from "openzeppelin-contracts/utils/math/SafeCast.sol";

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

    /**
     * @dev Mapping from proposal ID to vote tallies for that proposal.
     */
    mapping(uint256 => ProposalVote) private _proposalVotes;

    /**
     * @dev Mapping from proposal ID and address to the weight the address
     * has cast on that proposal, e.g. _proposalVotersWeightCast[42][0xBEEF]
     * would tell you the number of votes that 0xBEEF has cast on proposal 42.
     */
    mapping(uint256 => mapping(address => uint128)) private _proposalVotersWeightCast;

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
        return _proposalVotersWeightCast[proposalId][account] > 0;
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
        if (_proposalVotersWeightCast[proposalId][account] >= weight) {
          revert("GovernorCountingFractional: all weight cast");
        }

        uint128 safeWeight = SafeCast.toUint128(weight);

        if (voteData.length == 0) {
            _countVoteNominal(proposalId, account, safeWeight, support);
        } else {
            _countVoteFractional(proposalId, account, safeWeight, voteData);
        }
    }

    /**
     * @dev Count votes with full weight
     */
    function _countVoteNominal(
        uint256 proposalId,
        address account,
        uint128 weight,
        uint8 support
    ) internal {
        require(
            _proposalVotersWeightCast[proposalId][account] == 0,
            "GovernorCountingFractional: vote would exceed weight"
        );

        _proposalVotersWeightCast[proposalId][account] = weight;

        if (support == uint8(GovernorCompatibilityBravo.VoteType.Against)) {
            _proposalVotes[proposalId].againstVotes += weight;
        } else if (support == uint8(GovernorCompatibilityBravo.VoteType.For)) {
            _proposalVotes[proposalId].forVotes += weight;
        } else if (support == uint8(GovernorCompatibilityBravo.VoteType.Abstain)) {
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
        address account,
        uint128 weight,
        bytes memory voteData
    ) internal {
        require(voteData.length == 48, "GovernorCountingFractional: invalid voteData");

        (uint128 _forVotes, uint128 _againstVotes, uint128 _abstainVotes) = _decodePackedVotes(voteData);

        uint128 _existingWeight = _proposalVotersWeightCast[proposalId][account];
        uint256 _newWeight = uint256(_forVotes) + _againstVotes + _abstainVotes + _existingWeight;

        require(_newWeight <= weight, "GovernorCountingFractional: vote would exceed weight");

        // It's safe to downcast here because we've just confirmed that
        // _newWeight < weight, and we know that weight is <= uint128.max.
        _proposalVotersWeightCast[proposalId][account] = uint128(_newWeight);

        ProposalVote memory _proposalVote = _proposalVotes[proposalId];
        _proposalVote = ProposalVote(
            _proposalVote.againstVotes + _againstVotes,
            _proposalVote.forVotes + _forVotes,
            _proposalVote.abstainVotes + _abstainVotes
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
// forgefmt: disable-end

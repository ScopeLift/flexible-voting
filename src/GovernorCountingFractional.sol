// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {Governor, IGovernor} from "@openzeppelin/contracts/governance/Governor.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

/**
 * @author [ScopeLift](https://scopelift.co)
 * @notice Extension of {Governor} for 3 option fractional vote counting. When
 * voting, a delegate may split their vote weight between Against/For/Abstain.
 * This is most useful when the delegate is itself a contract, implementing its
 * own rules for voting. By allowing a contract-delegate to split its vote
 * weight, the voting preferences of many disparate token holders can be rolled
 * up into a single vote to the Governor itself. Some example use cases include
 * voting with tokens that are held by a DeFi pool, voting from L2 with tokens
 * held by a bridge, or voting privately from a shielded pool using zero
 * knowledge proofs.
 */
abstract contract GovernorCountingFractional is Governor {

    /// @notice Thrown when casting a vote would exceed the weight delegated to the voting account.
    error GovernorCountingFractional__VoteWeightExceeded();

    /// @notice Thrown when params data submitted with a vote does not match the convention expected for fractional voting.
    error GovernorCountingFractional__InvalidVoteData();

    /// @notice Thrown when vote is cast by an account that has no voting weight.
    error GovernorCountingFractional_NoVoteWeight();

    /**
     * @notice Supported vote types.
     * @dev Matches Governor Bravo ordering.
     */
    enum VoteType {
        Against,
        For,
        Abstain
    }

    /**
     * @notice Metadata about how votes were cast for a given proposal.
     * @param againstVotes The number of votes cast Against a proposal.
     * @param forVotes The number of votes cast For a proposal.
     * @param abstainVotes The number of votes that Abstain from voting for a proposal.
     */
    struct ProposalVote {
        uint128 againstVotes;
        uint128 forVotes;
        uint128 abstainVotes;
    }

    /**
     * @notice Mapping from proposal ID to vote tallies for that proposal.
     */
    mapping(uint256 => ProposalVote) private _proposalVotes;

    /**
     * @notice Mapping from proposal ID and address to the weight the address
     * has cast on that proposal, e.g. _proposalVotersWeightCast[42][0xBEEF]
     * would tell you the number of votes that 0xBEEF has cast on proposal 42.
     */
    mapping(uint256 => mapping(address => uint128)) private _proposalVotersWeightCast;

    /// @inheritdoc IGovernor
    function COUNTING_MODE() public pure virtual override returns (string memory) {
        return "support=bravo&quorum=for,abstain&params=fractional";
    }

    /// @inheritdoc IGovernor
    function hasVoted(uint256 proposalId, address account) public view virtual override returns (bool) {
        return _proposalVotersWeightCast[proposalId][account] > 0;
    }

    /**
     * @notice Get the number of votes cast thus far on proposal `proposalId` by
     * account `account`. Useful for integrations that allow delegates to cast
     * rolling, partial votes.
     * @param proposalId Identifier of any past or present proposal.
     * @param account The voting account in question.
     * @return The total voting weight cast so far for this proposal by this account
     */
    function voteWeightCast(uint256 proposalId, address account) public view returns (uint128) {
      return _proposalVotersWeightCast[proposalId][account];
    }

    /**
     * @notice Accessor to the internal vote counts.
     * @param proposalId Identifier of any past or present proposal.
     * @return againstVotes The Against votes cast so far for the given proposal.
     * @return forVotes The For votes cast so far for given proposal.
     * @return abstainVotes The Abstain votes cast so far for the given proposal.
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

    /// @inheritdoc Governor
    function _quorumReached(uint256 proposalId) internal view virtual override returns (bool) {
        ProposalVote storage proposalVote = _proposalVotes[proposalId];

        return quorum(proposalSnapshot(proposalId)) <= proposalVote.forVotes + proposalVote.abstainVotes;
    }

    /**
     * @inheritdoc Governor
     * @dev In this module, forVotes must be > againstVotes.
     */
    function _voteSucceeded(uint256 proposalId) internal view virtual override returns (bool) {
        ProposalVote storage proposalVote = _proposalVotes[proposalId];

        return proposalVote.forVotes > proposalVote.againstVotes;
    }

    /**
     * @inheritdoc Governor
     * @dev If the `voteData` bytes parameter is empty, then this module behaves
     * identically to GovernorBravo. That is, it assigns the full weight of the
     * delegate to the `support` parameter, which follows the `VoteType` enum
     * from Governor Bravo.
     *
     * If the `voteData` bytes parameter is not zero, then it _must_ be three
     * packed uint128s, totaling 48 bytes, representing the weight the delegate
     * assigns to Against, For, and Abstain respectively, i.e.
     * `abi.encodePacked(againstVotes, forVotes, abstainVotes)`. The sum total of
     * the three decoded vote weights _must_ be less than or equal to the
     * delegate's remaining weight on the proposal, i.e. their checkpointed
     * total weight minus votes already cast on the proposal.
     *
     * See `_countVoteNominal` and `_countVoteFractional` for more details.
     */
    function _countVote(
        uint256 proposalId,
        address account,
        uint8 support,
        uint256 totalWeight,
        bytes memory voteData
    ) internal virtual override {
        if (totalWeight == 0) {
            revert GovernorCountingFractional_NoVoteWeight();
        }

        if (_proposalVotersWeightCast[proposalId][account] >= totalWeight) {
          revert GovernorCountingFractional__VoteWeightExceeded();
        }

        uint128 safeTotalWeight = SafeCast.toUint128(totalWeight);

        if (voteData.length == 0) {
            _countVoteNominal(proposalId, account, safeTotalWeight, support);
        } else {
            _countVoteFractional(proposalId, account, safeTotalWeight, voteData);
        }
    }

    /**
     * @notice Record votes with full weight cast for `support`.
     * @dev Because this function votes with the delegate's full weight, it can only
     * be called once per proposal. It will revert if combined with a fractional
     * vote before or after.
     */
    function _countVoteNominal(
        uint256 proposalId,
        address account,
        uint128 totalWeight,
        uint8 support
    ) internal {
        if (_proposalVotersWeightCast[proposalId][account] != 0) {
            revert GovernorCountingFractional__VoteWeightExceeded();
        }

        _proposalVotersWeightCast[proposalId][account] = totalWeight;

        if (support == uint8(VoteType.Against)) {
            _proposalVotes[proposalId].againstVotes += totalWeight;
        } else if (support == uint8(VoteType.For)) {
            _proposalVotes[proposalId].forVotes += totalWeight;
        } else if (support == uint8(VoteType.Abstain)) {
            _proposalVotes[proposalId].abstainVotes += totalWeight;
        } else {
            revert GovernorInvalidVoteType();
        }
    }

    /**
     * @notice Count votes with fractional weight.
     * @dev `voteData` is expected to be three packed uint128s, i.e.
     * `abi.encodePacked(againstVotes, forVotes, abstainVotes)`.
     *
     * This function can be called multiple times for the same account and
     * proposal, i.e. partial/rolling votes are allowed. For example, an account
     * with total weight of 10 could call this function three times with the
     * following vote data:
     *   - against: 1, for: 0, abstain: 2
     *   - against: 3, for: 1, abstain: 0
     *   - against: 1, for: 1, abstain: 1
     * The result of these three calls would be that the account casts 5 votes
     * AGAINST, 2 votes FOR, and 3 votes ABSTAIN on the proposal. Though
     * partial, votes are still final once cast and cannot be changed or
     * overridden. Subsequent partial votes simply increment existing totals.
     *
     * Note that if partial votes are cast, all remaining weight must be cast
     * with _countVoteFractional: _countVoteNominal will revert.
     */
    function _countVoteFractional(
        uint256 proposalId,
        address account,
        uint128 totalWeight,
        bytes memory voteData
    ) internal {
        if (voteData.length != 48) {
            revert GovernorCountingFractional__InvalidVoteData();
        }

        (uint128 _againstVotes, uint128 _forVotes, uint128 _abstainVotes) = _decodePackedVotes(voteData);

        uint128 _existingWeight = _proposalVotersWeightCast[proposalId][account];
        uint256 _newWeight = uint256(_againstVotes) + _forVotes + _abstainVotes + _existingWeight;

        if (_newWeight > totalWeight) {
            revert GovernorCountingFractional__VoteWeightExceeded();
        }

        // It's safe to downcast here because we've just confirmed that
        // _newWeight <= totalWeight, and totalWeight is a uint128.
        _proposalVotersWeightCast[proposalId][account] = uint128(_newWeight);

        ProposalVote memory _proposalVote = _proposalVotes[proposalId];
        _proposalVote = ProposalVote(
            _proposalVote.againstVotes + _againstVotes,
            _proposalVote.forVotes + _forVotes,
            _proposalVote.abstainVotes + _abstainVotes
        );

        _proposalVotes[proposalId] = _proposalVote;
    }

    uint256 constant internal _MASK_HALF_WORD_RIGHT = 0xffffffffffffffffffffffffffffffff; // 128 bits of 0's, 128 bits of 1's

    /**
     * @notice Decodes three packed uint128's. Uses assembly because of a Solidity
     * language limitation which prevents slicing bytes stored in memory, rather
     * than calldata.
     */
    function _decodePackedVotes(bytes memory voteData)
        internal
        pure
        returns (
            uint128 againstVotes,
            uint128 forVotes,
            uint128 abstainVotes
        )
    {
        assembly {
            againstVotes := shr(128, mload(add(voteData, 0x20)))
            forVotes := and(_MASK_HALF_WORD_RIGHT, mload(add(voteData, 0x20)))
            abstainVotes := shr(128, mload(add(voteData, 0x40)))
        }
    }

}

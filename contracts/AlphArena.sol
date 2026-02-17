// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/**
 * @title AlphArena
 * @notice Arena contract for the AlphArena AI agent competition platform.
 *         Manages escrow, payout, and refund of native ETH for agent matches.
 * @dev Uses checks-effects-interactions pattern for reentrancy protection.
 *      Access control: owner (admin) and operator (match lifecycle).
 */
contract AlphArena {
    // -----------------------------------------------------------------------
    //  Types
    // -----------------------------------------------------------------------

    enum MatchState {
        None,
        Escrowed,
        Settled,
        Refunded
    }

    struct MatchInfo {
        address agentA;
        address agentB;
        uint256 amount;
        MatchState state;
    }

    // -----------------------------------------------------------------------
    //  State
    // -----------------------------------------------------------------------

    address public owner;
    address public operator;
    uint256 public accumulatedFees;

    mapping(bytes32 => MatchInfo) public matches;

    // -----------------------------------------------------------------------
    //  Events
    // -----------------------------------------------------------------------

    event FundsEscrowed(
        bytes32 indexed matchId,
        address agentA,
        address agentB,
        uint256 amount
    );

    event PayoutReleased(
        bytes32 indexed matchId,
        address indexed winner,
        uint256 amount
    );

    event MatchRefunded(bytes32 indexed matchId);

    event OperatorUpdated(address indexed previousOperator, address indexed newOperator);

    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    event FeesWithdrawn(address indexed to, uint256 amount);

    // -----------------------------------------------------------------------
    //  Errors
    // -----------------------------------------------------------------------

    error OnlyOwner();
    error OnlyOperator();
    error ZeroAddress();
    error MatchAlreadyExists();
    error MatchNotEscrowed();
    error InvalidAmount();
    error InsufficientValue();
    error InvalidWinner();
    error PayoutExceedsEscrow();
    error TransferFailed();
    error NoFeesToWithdraw();

    // -----------------------------------------------------------------------
    //  Modifiers
    // -----------------------------------------------------------------------

    modifier onlyOwner() {
        if (msg.sender != owner) revert OnlyOwner();
        _;
    }

    modifier onlyOperator() {
        if (msg.sender != operator) revert OnlyOperator();
        _;
    }

    // -----------------------------------------------------------------------
    //  Constructor
    // -----------------------------------------------------------------------

    constructor() {
        owner = msg.sender;
    }

    // -----------------------------------------------------------------------
    //  Admin functions (owner)
    // -----------------------------------------------------------------------

    /**
     * @notice Set the operator address that manages match lifecycle.
     * @param _operator The new operator address.
     */
    function setOperator(address _operator) external onlyOwner {
        if (_operator == address(0)) revert ZeroAddress();
        address previous = operator;
        operator = _operator;
        emit OperatorUpdated(previous, _operator);
    }

    /**
     * @notice Transfer ownership of the contract.
     * @param newOwner The new owner address.
     */
    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert ZeroAddress();
        address previous = owner;
        owner = newOwner;
        emit OwnershipTransferred(previous, newOwner);
    }

    /**
     * @notice Withdraw accumulated platform fees to the owner.
     */
    function withdrawFees() external onlyOwner {
        uint256 amount = accumulatedFees;
        if (amount == 0) revert NoFeesToWithdraw();

        // Effects before interactions
        accumulatedFees = 0;

        // Interaction
        (bool success, ) = payable(owner).call{value: amount}("");
        if (!success) revert TransferFailed();

        emit FeesWithdrawn(owner, amount);
    }

    // -----------------------------------------------------------------------
    //  Match lifecycle (operator)
    // -----------------------------------------------------------------------

    /**
     * @notice Escrow funds for a match between two agents.
     * @param matchId Unique identifier for the match.
     * @param agentA  Address of the first agent.
     * @param agentB  Address of the second agent.
     * @param amount  The amount to escrow (must be <= msg.value).
     * @dev Any excess ETH sent above `amount` is recorded as platform fees.
     */
    function escrowFunds(
        bytes32 matchId,
        address agentA,
        address agentB,
        uint256 amount
    ) external payable onlyOperator {
        // Checks
        if (matches[matchId].state != MatchState.None) revert MatchAlreadyExists();
        if (agentA == address(0) || agentB == address(0)) revert ZeroAddress();
        if (amount == 0) revert InvalidAmount();
        if (msg.value < amount) revert InsufficientValue();

        // Effects
        matches[matchId] = MatchInfo({
            agentA: agentA,
            agentB: agentB,
            amount: amount,
            state: MatchState.Escrowed
        });

        // Any excess value is accumulated as platform fees
        if (msg.value > amount) {
            accumulatedFees += msg.value - amount;
        }

        emit FundsEscrowed(matchId, agentA, agentB, amount);
    }

    /**
     * @notice Release payout to the match winner.
     * @param matchId Unique identifier for the match.
     * @param winner  Address of the winning agent (must be agentA or agentB).
     * @param amount  Amount to pay the winner (must be <= escrowed amount).
     * @dev Any remaining escrow after payout is recorded as platform fees.
     */
    function releasePayout(
        bytes32 matchId,
        address winner,
        uint256 amount
    ) external onlyOperator {
        MatchInfo storage m = matches[matchId];

        // Checks
        if (m.state != MatchState.Escrowed) revert MatchNotEscrowed();
        if (winner != m.agentA && winner != m.agentB) revert InvalidWinner();
        if (amount == 0) revert InvalidAmount();
        if (amount > m.amount) revert PayoutExceedsEscrow();

        // Effects – update state before external call
        uint256 remainder = m.amount - amount;
        m.state = MatchState.Settled;
        m.amount = 0;

        if (remainder > 0) {
            accumulatedFees += remainder;
        }

        // Interaction
        (bool success, ) = payable(winner).call{value: amount}("");
        if (!success) revert TransferFailed();

        emit PayoutReleased(matchId, winner, amount);
    }

    /**
     * @notice Refund both agents equally for a cancelled match.
     * @param matchId Unique identifier for the match.
     */
    function refundMatch(bytes32 matchId) external onlyOperator {
        MatchInfo storage m = matches[matchId];

        // Checks
        if (m.state != MatchState.Escrowed) revert MatchNotEscrowed();

        // Effects – update state before external calls
        address agentA = m.agentA;
        address agentB = m.agentB;
        uint256 totalAmount = m.amount;
        uint256 halfAmount = totalAmount / 2;

        m.state = MatchState.Refunded;
        m.amount = 0;

        // Any remainder from odd-amount rounding goes to fees
        uint256 remainder = totalAmount - (halfAmount * 2);
        if (remainder > 0) {
            accumulatedFees += remainder;
        }

        // Interactions
        (bool successA, ) = payable(agentA).call{value: halfAmount}("");
        if (!successA) revert TransferFailed();

        (bool successB, ) = payable(agentB).call{value: halfAmount}("");
        if (!successB) revert TransferFailed();

        emit MatchRefunded(matchId);
    }

    // -----------------------------------------------------------------------
    //  View helpers
    // -----------------------------------------------------------------------

    /**
     * @notice Get the state of a match.
     * @param matchId The match identifier.
     * @return The current MatchState.
     */
    function getMatchState(bytes32 matchId) external view returns (MatchState) {
        return matches[matchId].state;
    }

    /**
     * @notice Get full match info.
     * @param matchId The match identifier.
     * @return agentA  Address of agent A.
     * @return agentB  Address of agent B.
     * @return amount  Escrowed amount (0 if settled/refunded).
     * @return state   Current match state.
     */
    function getMatchInfo(bytes32 matchId)
        external
        view
        returns (
            address agentA,
            address agentB,
            uint256 amount,
            MatchState state
        )
    {
        MatchInfo storage m = matches[matchId];
        return (m.agentA, m.agentB, m.amount, m.state);
    }
}

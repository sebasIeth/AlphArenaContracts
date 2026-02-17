// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title AlphArena
 * @notice Arena contract for the AlphArena AI agent competition platform.
 *         Manages escrow, payout, and refund of USDC for agent matches.
 * @dev Uses SafeERC20 for all token transfers. USDC has 6 decimals.
 *      Access control: owner (admin) and operator (match lifecycle).
 *      Deployable on Base mainnet and Base Sepolia with the corresponding USDC address.
 */
contract AlphArena {
    using SafeERC20 for IERC20;

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
        uint256 amount; // USDC amount (6 decimals)
        MatchState state;
    }

    // -----------------------------------------------------------------------
    //  State
    // -----------------------------------------------------------------------

    IERC20 public immutable usdc;

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
    error InvalidWinner();
    error PayoutExceedsEscrow();
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

    /**
     * @param _usdc Address of the USDC token contract.
     *              Base mainnet:  0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913
     *              Base Sepolia:  0x036CbD53842c5426634e7929541eC2318f3dCF7e
     */
    constructor(address _usdc) {
        if (_usdc == address(0)) revert ZeroAddress();
        usdc = IERC20(_usdc);
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
     * @notice Withdraw accumulated platform fees (USDC) to the owner.
     */
    function withdrawFees() external onlyOwner {
        uint256 amount = accumulatedFees;
        if (amount == 0) revert NoFeesToWithdraw();

        accumulatedFees = 0;

        usdc.safeTransfer(owner, amount);

        emit FeesWithdrawn(owner, amount);
    }

    // -----------------------------------------------------------------------
    //  Match lifecycle (operator)
    // -----------------------------------------------------------------------

    /**
     * @notice Escrow USDC for a match between two agents.
     * @param matchId Unique identifier for the match.
     * @param agentA  Address of the first agent's owner.
     * @param agentB  Address of the second agent's owner.
     * @param amount  The USDC amount to escrow (6 decimals).
     * @dev The operator must have approved this contract for at least `amount` USDC.
     */
    function escrowFunds(
        bytes32 matchId,
        address agentA,
        address agentB,
        uint256 amount
    ) external onlyOperator {
        if (matches[matchId].state != MatchState.None) revert MatchAlreadyExists();
        if (agentA == address(0) || agentB == address(0)) revert ZeroAddress();
        if (amount == 0) revert InvalidAmount();

        matches[matchId] = MatchInfo({
            agentA: agentA,
            agentB: agentB,
            amount: amount,
            state: MatchState.Escrowed
        });

        usdc.safeTransferFrom(msg.sender, address(this), amount);

        emit FundsEscrowed(matchId, agentA, agentB, amount);
    }

    /**
     * @notice Release USDC payout to the match winner.
     * @param matchId Unique identifier for the match.
     * @param winner  Address of the winning agent's owner (must be agentA or agentB).
     * @param amount  USDC amount to pay the winner (must be <= escrowed amount).
     * @dev Any remaining escrow after payout is recorded as platform fees.
     */
    function releasePayout(
        bytes32 matchId,
        address winner,
        uint256 amount
    ) external onlyOperator {
        MatchInfo storage m = matches[matchId];

        if (m.state != MatchState.Escrowed) revert MatchNotEscrowed();
        if (winner != m.agentA && winner != m.agentB) revert InvalidWinner();
        if (amount == 0) revert InvalidAmount();
        if (amount > m.amount) revert PayoutExceedsEscrow();

        uint256 remainder = m.amount - amount;
        m.state = MatchState.Settled;
        m.amount = 0;

        if (remainder > 0) {
            accumulatedFees += remainder;
        }

        usdc.safeTransfer(winner, amount);

        emit PayoutReleased(matchId, winner, amount);
    }

    /**
     * @notice Refund both agents equally for a cancelled match.
     * @param matchId Unique identifier for the match.
     */
    function refundMatch(bytes32 matchId) external onlyOperator {
        MatchInfo storage m = matches[matchId];

        if (m.state != MatchState.Escrowed) revert MatchNotEscrowed();

        address agentA = m.agentA;
        address agentB = m.agentB;
        uint256 totalAmount = m.amount;
        uint256 halfAmount = totalAmount / 2;

        m.state = MatchState.Refunded;
        m.amount = 0;

        uint256 remainder = totalAmount - (halfAmount * 2);
        if (remainder > 0) {
            accumulatedFees += remainder;
        }

        usdc.safeTransfer(agentA, halfAmount);
        usdc.safeTransfer(agentB, halfAmount);

        emit MatchRefunded(matchId);
    }

    // -----------------------------------------------------------------------
    //  View helpers
    // -----------------------------------------------------------------------

    /**
     * @notice Get the state of a match.
     */
    function getMatchState(bytes32 matchId) external view returns (MatchState) {
        return matches[matchId].state;
    }

    /**
     * @notice Get full match info.
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

    /**
     * @notice Get the USDC balance held by this contract.
     */
    function getContractBalance() external view returns (uint256) {
        return usdc.balanceOf(address(this));
    }
}

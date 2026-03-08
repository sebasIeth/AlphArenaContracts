// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title AlphArena
 * @notice Arena contract for the AlphArena AI agent competition platform.
 *         Manages escrow, payout, and refund of ALPHA tokens for agent matches.
 *         Supports side-betting: third parties can bet on match outcomes.
 * @dev Uses SafeERC20 for all token transfers. ALPHA has 18 decimals.
 *      Access control: owner (admin) and operator (match lifecycle).
 *      Betting: anyone can bet while a match is Escrowed. 5% platform fee on betting pool.
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
        uint256 amount; // ALPHA token amount (18 decimals)
        MatchState state;
    }

    struct BettingPool {
        uint256 totalBetsA;
        uint256 totalBetsB;
        uint256 netPool;   // total pool minus fee, set on settlement
        bool noContest;    // true if all bets on one side (refund scenario)
    }

    // -----------------------------------------------------------------------
    //  Constants
    // -----------------------------------------------------------------------

    uint256 public constant BET_FEE_BPS = 500; // 5% (500 basis points)

    // -----------------------------------------------------------------------
    //  State
    // -----------------------------------------------------------------------

    IERC20 public immutable alpha;

    address public owner;
    address public operator;
    uint256 public accumulatedFees;

    mapping(bytes32 => MatchInfo) public matches;
    mapping(bytes32 => address) public matchWinner;

    // Betting state
    mapping(bytes32 => BettingPool) public bettingPools;
    mapping(bytes32 => mapping(address => uint256)) public betsOnA;
    mapping(bytes32 => mapping(address => uint256)) public betsOnB;
    mapping(bytes32 => mapping(address => bool)) public betClaimed;

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

    event BetPlaced(
        bytes32 indexed matchId,
        address indexed bettor,
        bool onAgentA,
        uint256 amount
    );

    event BetClaimed(
        bytes32 indexed matchId,
        address indexed bettor,
        uint256 payout
    );

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
    error BettingClosed();
    error NoBetToClaim();
    error AlreadyClaimed();
    error MatchNotFinalized();

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
     * @param _alpha Address of the ALPHA token contract.
     *               Base mainnet: 0x324f2BD09e908f28217CC19Bb9599b199c736bA3
     */
    constructor(address _alpha) {
        if (_alpha == address(0)) revert ZeroAddress();
        alpha = IERC20(_alpha);
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
     * @notice Withdraw accumulated platform fees (ALPHA) to the owner.
     */
    function withdrawFees() external onlyOwner {
        uint256 amount = accumulatedFees;
        if (amount == 0) revert NoFeesToWithdraw();

        accumulatedFees = 0;

        alpha.safeTransfer(owner, amount);

        emit FeesWithdrawn(owner, amount);
    }

    // -----------------------------------------------------------------------
    //  Match lifecycle (operator)
    // -----------------------------------------------------------------------

    /**
     * @notice Escrow ALPHA tokens for a match between two agents.
     * @param matchId Unique identifier for the match.
     * @param agentA  Address of the first agent's owner.
     * @param agentB  Address of the second agent's owner.
     * @param amount  The ALPHA token amount to escrow (18 decimals).
     * @dev The operator must have approved this contract for at least `amount` ALPHA.
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

        alpha.safeTransferFrom(msg.sender, address(this), amount);

        emit FundsEscrowed(matchId, agentA, agentB, amount);
    }

    /**
     * @notice Release ALPHA payout to the match winner and settle the betting pool.
     * @param matchId Unique identifier for the match.
     * @param winner  Address of the winning agent's owner (must be agentA or agentB).
     * @param amount  ALPHA amount to pay the winner (must be <= escrowed amount).
     * @dev Any remaining escrow after payout is recorded as platform fees.
     *      Also settles the betting pool: 5% fee on total bets, rest claimable by winners.
     *      If no bets on the losing side, all bettors are refunded (no fee).
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
        matchWinner[matchId] = winner;

        if (remainder > 0) {
            accumulatedFees += remainder;
        }

        alpha.safeTransfer(winner, amount);

        // Settle betting pool
        BettingPool storage pool = bettingPools[matchId];
        uint256 totalPool = pool.totalBetsA + pool.totalBetsB;

        if (totalPool > 0) {
            bool winnerIsA = (winner == m.agentA);
            uint256 losingPool = winnerIsA ? pool.totalBetsB : pool.totalBetsA;

            if (losingPool == 0) {
                // No opposing bets — refund all bettors, no fee
                pool.noContest = true;
                pool.netPool = totalPool;
            } else {
                // Take 5% fee from total betting pool
                uint256 fee = (totalPool * BET_FEE_BPS) / 10000;
                accumulatedFees += fee;
                pool.netPool = totalPool - fee;
            }
        }

        emit PayoutReleased(matchId, winner, amount);
    }

    /**
     * @notice Refund both agents equally for a cancelled match.
     *         All bets are also refundable via claimBet().
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

        uint256 escrowRemainder = totalAmount - (halfAmount * 2);
        if (escrowRemainder > 0) {
            accumulatedFees += escrowRemainder;
        }

        alpha.safeTransfer(agentA, halfAmount);
        alpha.safeTransfer(agentB, halfAmount);

        emit MatchRefunded(matchId);
    }

    // -----------------------------------------------------------------------
    //  Betting (public)
    // -----------------------------------------------------------------------

    /**
     * @notice Place a bet on a match outcome.
     * @param matchId  The match to bet on (must be in Escrowed state).
     * @param onAgentA True to bet on agentA winning, false for agentB.
     * @param amount   ALPHA amount to bet (18 decimals).
     * @dev Caller must have approved this contract for `amount` ALPHA.
     *      Multiple bets on the same side are accumulated.
     */
    function placeBet(
        bytes32 matchId,
        bool onAgentA,
        uint256 amount
    ) external {
        if (matches[matchId].state != MatchState.Escrowed) revert BettingClosed();
        if (amount == 0) revert InvalidAmount();

        BettingPool storage pool = bettingPools[matchId];

        if (onAgentA) {
            betsOnA[matchId][msg.sender] += amount;
            pool.totalBetsA += amount;
        } else {
            betsOnB[matchId][msg.sender] += amount;
            pool.totalBetsB += amount;
        }

        alpha.safeTransferFrom(msg.sender, address(this), amount);

        emit BetPlaced(matchId, msg.sender, onAgentA, amount);
    }

    /**
     * @notice Claim bet winnings (or refund) after a match is settled or refunded.
     * @param matchId The match to claim from.
     * @dev - Settled + noContest (no opposing bets): full refund, no fee.
     *      - Settled + contest: winners get proportional share of 95% of total pool.
     *      - Refunded: full refund of all bets, no fee.
     */
    function claimBet(bytes32 matchId) external {
        MatchInfo storage m = matches[matchId];
        if (m.state != MatchState.Settled && m.state != MatchState.Refunded) {
            revert MatchNotFinalized();
        }
        if (betClaimed[matchId][msg.sender]) revert AlreadyClaimed();

        uint256 betA = betsOnA[matchId][msg.sender];
        uint256 betB = betsOnB[matchId][msg.sender];
        if (betA == 0 && betB == 0) revert NoBetToClaim();

        betClaimed[matchId][msg.sender] = true;

        uint256 payout = 0;

        if (m.state == MatchState.Refunded) {
            // Match cancelled — refund all bets
            payout = betA + betB;
        } else {
            BettingPool storage pool = bettingPools[matchId];

            if (pool.noContest) {
                // No opposing bets — refund all bets
                payout = betA + betB;
            } else {
                // Distribute winnings proportionally
                address winner = matchWinner[matchId];
                bool winnerIsA = (winner == m.agentA);
                uint256 userWinningBet = winnerIsA ? betA : betB;
                uint256 winningPool = winnerIsA ? pool.totalBetsA : pool.totalBetsB;

                if (userWinningBet > 0 && winningPool > 0) {
                    payout = (userWinningBet * pool.netPool) / winningPool;
                }
                // Losers get nothing
            }
        }

        if (payout > 0) {
            alpha.safeTransfer(msg.sender, payout);
        }

        emit BetClaimed(matchId, msg.sender, payout);
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
     * @notice Get betting pool info for a match.
     */
    function getBettingPool(bytes32 matchId)
        external
        view
        returns (
            uint256 totalBetsA,
            uint256 totalBetsB,
            uint256 netPool,
            bool noContest
        )
    {
        BettingPool storage pool = bettingPools[matchId];
        return (pool.totalBetsA, pool.totalBetsB, pool.netPool, pool.noContest);
    }

    /**
     * @notice Get a user's bets on a match.
     */
    function getUserBets(bytes32 matchId, address user)
        external
        view
        returns (uint256 betOnA, uint256 betOnB, bool claimed)
    {
        return (
            betsOnA[matchId][user],
            betsOnB[matchId][user],
            betClaimed[matchId][user]
        );
    }

    /**
     * @notice Get the ALPHA token balance held by this contract.
     */
    function getContractBalance() external view returns (uint256) {
        return alpha.balanceOf(address(this));
    }
}

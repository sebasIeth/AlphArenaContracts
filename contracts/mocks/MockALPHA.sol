// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/**
 * @title MockALPHA
 * @notice Mock ALPHA token for local development and testing.
 *         Mimics the real AlphArena token with 18 decimals and a public mint function.
 */
contract MockALPHA is ERC20 {
    constructor() ERC20("AlphArena", "ALPHA") {
        // Mint 1,000,000 ALPHA to deployer
        _mint(msg.sender, 1_000_000 * 10 ** 18);
    }

    /// @notice Anyone can mint tokens in dev/test environments.
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/**
 * @title MockUSDC
 * @notice Mock USDC token for local development and testing.
 *         Mimics real USDC with 6 decimals and a public mint function.
 */
contract MockUSDC is ERC20 {
    constructor() ERC20("USD Coin", "USDC") {
        // Mint 1,000,000 USDC to deployer
        _mint(msg.sender, 1_000_000 * 10 ** 6);
    }

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    /// @notice Anyone can mint tokens in dev/test environments.
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

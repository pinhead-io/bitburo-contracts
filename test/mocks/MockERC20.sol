// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice ERC-20 with configurable decimals, free mint and FiatToken-like pause/blacklist.
contract MockERC20 is ERC20 {
    uint8 private immutable _decimals;
    bool public paused;
    mapping(address account => bool) public blacklisted;

    constructor(string memory name_, string memory symbol_, uint8 decimals_) ERC20(name_, symbol_) {
        _decimals = decimals_;
    }

    function decimals() public view override returns (uint8) {
        return _decimals;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setPaused(bool value) external {
        paused = value;
    }

    function setBlacklisted(address account, bool value) external {
        blacklisted[account] = value;
    }

    function _update(address from, address to, uint256 value) internal override {
        require(!paused, "Pausable: paused");
        require(
            !blacklisted[from] && !blacklisted[to] && !blacklisted[msg.sender], "Blacklistable: account is blacklisted"
        );
        super._update(from, to, value);
    }
}

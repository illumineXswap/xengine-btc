// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import "./NoEventsERC20.sol";

contract PeggedBTC is NoEventsERC20 {
    address public immutable vaultMinter;

    constructor() NoEventsERC20("Bitcoin", "BTC", 8) {
        vaultMinter = msg.sender;
    }

    function mint(address to, uint256 amount) public {
        require(msg.sender == vaultMinter);
        _mint(to, amount);
    }

    function burn(address from, uint256 amount) public {
        require(msg.sender == vaultMinter);
        _burn(from, amount);
    }
}

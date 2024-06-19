// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract PeggedBTC is ERC20 {
    address public immutable vaultMinter;

    constructor() ERC20("Bitcoin", "BTC") {
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

    function decimals() public pure override returns (uint8) {
        return 8;
    }
}

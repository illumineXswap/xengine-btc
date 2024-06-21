// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/access/Ownable.sol";

abstract contract AllowedRelayers is Ownable {
    mapping(address => bool) public relayers;
    bool public relayersWhitelistEnabled;

    modifier onlyRelayer() {
        if (relayersWhitelistEnabled && !relayers[msg.sender]) {
            revert("NRL");
        }

        _;
    }

    constructor() {
        relayersWhitelistEnabled = true;
        _toggleRelayer(msg.sender);
    }

    function _toggleRelayer(address _relayer) internal {
        relayers[_relayer] = !relayers[_relayer];
    }

    function toggleRelayersWhitelistEnabled() public onlyOwner {
        relayersWhitelistEnabled = !relayersWhitelistEnabled;
    }

    function toggleRelayer(address _relayer) public onlyOwner {
        _toggleRelayer(_relayer);
    }
}

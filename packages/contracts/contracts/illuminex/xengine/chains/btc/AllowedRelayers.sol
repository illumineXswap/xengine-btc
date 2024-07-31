// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/access/Ownable.sol";

abstract contract AllowedRelayers is Ownable {
    mapping(address => bool) internal _relayers;
    bool internal _relayersWhitelistEnabled;

    AllowedRelayers public immutable parent;

    modifier onlyRelayer() {
        if (relayersWhitelistEnabled() && !relayers(msg.sender)) {
            revert("NRL");
        }

        _;
    }

    constructor(address _parent) {
        parent = AllowedRelayers(_parent);

        if (_parent == address(0)) {
            _relayersWhitelistEnabled = true;
            _toggleRelayer(msg.sender);
        }
    }

    function relayers(address _relayer) public view returns (bool) {
        if (address(parent) != address(0)) {
            return parent.relayers(_relayer);
        }

        return _relayers[_relayer];
    }

    function relayersWhitelistEnabled() public view returns (bool) {
        if (address(parent) != address(0)) {
            return parent.relayersWhitelistEnabled();
        }

        return _relayersWhitelistEnabled;
    }

    function _toggleRelayer(address _relayer) internal {
        _relayers[_relayer] = !_relayers[_relayer];
    }

    function toggleRelayersWhitelistEnabled() public onlyOwner {
        _relayersWhitelistEnabled = !_relayersWhitelistEnabled;
    }

    function toggleRelayer(address _relayer) public onlyOwner {
        _toggleRelayer(_relayer);
    }
}

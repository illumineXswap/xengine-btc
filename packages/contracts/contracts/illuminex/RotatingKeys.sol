// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import "@oasisprotocol/sapphire-contracts/contracts/Sapphire.sol";

abstract contract RotatingKeys {
    bytes32[] internal _ringKeys;
    uint256 internal _lastRingKeyUpdate;

    uint256 public ringKeyUpdateInterval = 1 days;
    bytes32 private immutable nonceConst;

    event ActualRingKeyRenewed(uint indexed newKeyIndex);

    constructor(bytes32 _genesis, string memory _name) {
        _updateRingKey(_genesis);
        nonceConst = keccak256(abi.encodePacked(_name));
    }

    function _updateRingKey(bytes32 _entropy) internal {
        bytes32 newKey = bytes32(Sapphire.randomBytes(32, abi.encodePacked(_entropy)));

        uint newIndex = _ringKeys.length;
        _ringKeys.push(newKey);

        _lastRingKeyUpdate = block.timestamp;

        emit ActualRingKeyRenewed(newIndex);
    }

    function _computeNonce(uint256 keyIndex) private view returns (bytes32 nonce) {
        nonce = keccak256(abi.encodePacked(keyIndex, nonceConst));
    }

    function _encryptPayload(bytes memory payload) internal view returns (bytes memory encryptedData, uint256 keyIndex) {
        require(_ringKeys.length > 0, "No ring keys set up");

        keyIndex = _ringKeys.length - 1;
        bytes32 nonce = _computeNonce(keyIndex);
        encryptedData = Sapphire.encrypt(_ringKeys[keyIndex], bytes32(nonce), payload, abi.encodePacked(nonceConst));
    }

    function _decryptPayload(uint256 keyIndex, bytes memory payload) internal view returns (bytes memory output) {
        require(keyIndex < _ringKeys.length, "No ring key found");

        bytes32 nonce = _computeNonce(keyIndex);
        output = Sapphire.decrypt(_ringKeys[keyIndex], nonce, payload, abi.encodePacked(nonceConst));
    }
}

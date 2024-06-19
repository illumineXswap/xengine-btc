// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

interface ITxSecretsStorage {
    function getKeyPair(bytes32 inputId) external view returns (bytes memory pubKey, bytes memory privKey);

    function deriveChangeInfo(bytes32 seed) external returns (uint256 _rChangeSystemIdx, bytes20 _changeScriptHash);
}

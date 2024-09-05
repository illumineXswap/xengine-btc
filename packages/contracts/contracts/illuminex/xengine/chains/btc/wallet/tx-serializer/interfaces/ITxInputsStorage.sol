// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

interface ITxInputsStorage {
    function spendInput(bytes32 inputId) external;

    function fetchInput(bytes32 inputId) external view returns (
        uint64 value,
        bytes32 txHash,
        uint32 txOutIndex
    );

    function fetchOffchainPubKey(bytes32 inputId) external view returns (bytes memory);

    function isRefuelInput(bytes32 inputId) external view returns (bool);

    function isRefundInput(bytes32 inputId) external view returns (bool);
}

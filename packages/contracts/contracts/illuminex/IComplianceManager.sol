// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

interface IComplianceManager {
    function pushRecord(string memory _type, bytes memory data) external returns (bytes32 recordId);
}

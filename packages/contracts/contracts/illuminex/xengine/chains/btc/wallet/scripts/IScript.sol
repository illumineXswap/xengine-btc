// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

interface IScript {
    function serialize(bytes memory in_args) external view returns (bytes memory);

    function deserialize(bytes memory script) external pure returns (bytes memory);

    function id() external pure returns (bytes4);
}

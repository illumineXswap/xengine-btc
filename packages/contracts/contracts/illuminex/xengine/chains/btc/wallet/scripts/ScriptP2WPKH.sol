// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import "./IScript.sol";
import "../../../../../Buffer.sol";

contract ScriptP2WPKH is IScript {
    using Buffer for Buffer.BufferIO;

    bytes1 public constant OP_0 = 0x00;

    function serialize(bytes memory in_args) public pure override returns (bytes memory) {
        (bytes20 pubKeyHash) = abi.decode(in_args, (bytes20));

        Buffer.BufferIO memory _buffer = Buffer.alloc(22);

        _buffer.write(abi.encodePacked(OP_0));
        _buffer.write(abi.encodePacked(bytes1(0x14), pubKeyHash));

        return _buffer.data;
    }

    function deserialize(bytes memory) public pure override returns (bytes memory) {
        return new bytes(0);
    }

    function id() public override pure returns (bytes4) {
        return bytes4(keccak256(abi.encodePacked(type(ScriptP2WPKH).name)));
    }
}
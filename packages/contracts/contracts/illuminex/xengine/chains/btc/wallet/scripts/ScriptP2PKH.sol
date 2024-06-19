// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import "./IScript.sol";
import "../../../../../Buffer.sol";

contract ScriptP2PKH is IScript {
    using Buffer for Buffer.BufferIO;

    bytes1 public constant OP_HASH160 = 0xa9;
    bytes1 public constant OP_DUP = 0x76;
    bytes1 public constant OP_EQUALVERIFY = 0x88;
    bytes1 public constant OP_CHECKSIG = 0xac;

    function serialize(bytes memory in_args) public pure override returns (bytes memory) {
        (bytes20 pubKeyHash) = abi.decode(in_args, (bytes20));

        Buffer.BufferIO memory _buffer = Buffer.alloc(25);

        _buffer.write(abi.encodePacked(OP_DUP));
        _buffer.write(abi.encodePacked(OP_HASH160));
        _buffer.write(abi.encodePacked(bytes1(0x14), pubKeyHash));
        _buffer.write(abi.encodePacked(OP_EQUALVERIFY));
        _buffer.write(abi.encodePacked(OP_CHECKSIG));

        return _buffer.data;
    }

    function deserialize(bytes memory script) public pure override returns (bytes memory) {
        bytes memory _pubKeyHash = new bytes(0);

        if (script.length != 25) {
            return _pubKeyHash;
        }

        if (
            script[0] == OP_DUP
            && script[1] == OP_HASH160
            && script[2] == 0x14
            && script[23] == OP_EQUALVERIFY
            && script[24] == OP_CHECKSIG
        ) {
            _pubKeyHash = Buffer.read(Buffer.BufferIO(script, 3), 20);
        }

        return _pubKeyHash;
    }

    function id() public override pure returns (bytes4) {
        return bytes4(keccak256(abi.encodePacked(type(ScriptP2PKH).name)));
    }
}
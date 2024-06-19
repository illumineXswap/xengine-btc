// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import "./IScript.sol";
import "../../../../../Buffer.sol";

contract ScriptP2SH is IScript {
    using Buffer for Buffer.BufferIO;

    bytes1 public constant OP_HASH160 = 0xa9;
    bytes1 public constant OP_EQUAL = 0x87;

    bytes1 public constant OP_0 = 0x0;
    bytes1 public constant OP_PUSHDATA1 = 0x4c;

    function serialize(bytes memory in_args) public pure override returns (bytes memory) {
        (bytes20 scriptHash) = abi.decode(in_args, (bytes20));

        Buffer.BufferIO memory _buffer = Buffer.alloc(23);

        _buffer.write(abi.encodePacked(OP_HASH160));
        _buffer.write(abi.encodePacked(bytes1(0x14), scriptHash));
        _buffer.write(abi.encodePacked(OP_EQUAL));

        return _buffer.data;
    }

    function serializeRedemption(bytes memory redeemScript, bytes memory sig) public pure returns (bytes memory) {
        require(redeemScript.length <= 75 && sig.length <= 255, "Invalid redemption size");

        Buffer.BufferIO memory _buffer = Buffer.alloc(1 + sig.length + 1 + redeemScript.length);

        _buffer.write(abi.encodePacked(OP_0));

        _buffer.write(sig);

        // The script itself is quite small, so we must use OP_PUSHDATA without length prefix
        _buffer.write(abi.encodePacked(uint8(redeemScript.length)));
        _buffer.write(redeemScript);

        return _buffer.data;
    }

    function deserialize(bytes memory script) public pure override returns (bytes memory) {
        bytes memory _scriptHash = new bytes(0);

        if (script.length != 23) {
            return _scriptHash;
        }

        if (
            script[0] == OP_HASH160
            && script[1] == 0x14
            && script[22] == OP_EQUAL
        ) {
            _scriptHash = Buffer.read(Buffer.BufferIO(script, 2), 20);
        }

        return _scriptHash;
    }

    function id() public override pure returns (bytes4) {
        return bytes4(keccak256(abi.encodePacked(type(ScriptP2SH).name)));
    }
}

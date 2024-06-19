// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import "./Endian.sol";

library StorageWritableBufferStream {
    struct WritableBufferStream {
        bytes data;
    }

    function _write(WritableBufferStream storage buffer, bytes memory data) internal {
        for (uint i = 0; i < data.length; i++) {
            buffer.data.push(data[i]);
        }
    }

    function write(WritableBufferStream storage buffer, bytes memory data) internal {
        _write(buffer, data);
    }

    function writeBytes32(WritableBufferStream storage buffer, bytes32 data) internal {
        _write(buffer, bytes.concat(data));
    }

    function writeUint32(WritableBufferStream storage buffer, uint32 data) internal {
        _write(buffer, bytes.concat(bytes4(data)));
    }

    function writeUint64(WritableBufferStream storage buffer, uint64 data) internal {
        _write(buffer, bytes.concat(bytes8(data)));
    }

    function writeVarInt(WritableBufferStream storage buffer, uint256 value) internal {
        if (value <= 0xFC) {
            _write(buffer, bytes.concat(bytes1(uint8(value))));
        } else if (value >= 253 && value <= 0xFFFF) {
            _write(buffer, bytes.concat(bytes1(uint8(0xFD))));
            _write(buffer, bytes.concat(bytes2(Endian.reverse16(uint16(value)))));
        } else if (value >= 65536 && value <= 0xFFFFFFFF) {
            _write(buffer, bytes.concat(bytes1(uint8(0xFE))));
            _write(buffer, bytes.concat(bytes4(Endian.reverse32(uint16(value)))));
        } else if (value >= 4_294_967_296 && value <= 0xFFFFFFFFFFFFFFFF) {
            _write(buffer, bytes.concat(bytes1(uint8(0xFF))));
            _write(buffer, bytes.concat(bytes8(Endian.reverse64(uint64(value)))));
        } else {
            revert("Value too large");
        }
    }
}

// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import "./Endian.sol";

library Buffer {
    struct BufferIO {
        bytes data;
        uint256 cursor;
    }

    function alloc(uint256 size) internal pure returns (BufferIO memory) {
        bytes memory _data = new bytes(size);
        return BufferIO(_data, 0);
    }

    function read(BufferIO memory buffer, uint256 size) internal pure returns (bytes memory) {
        require(buffer.cursor + size <= buffer.data.length, "Invalid buffer size");

        bytes memory slice = new bytes(size);
        for (uint i = buffer.cursor; i < buffer.cursor + size; i++) {
            slice[i - buffer.cursor] = buffer.data[i];
        }

        buffer.cursor += size;
        return slice;
    }

    function write(BufferIO memory buffer, bytes memory data) internal pure {
        require(buffer.cursor + data.length <= buffer.data.length, "Invalid buffer size");

        for (uint i = buffer.cursor; i < buffer.cursor + data.length; i++) {
            buffer.data[i] = data[i - buffer.cursor];
        }

        buffer.cursor += data.length;
    }

    function writeBytes32(BufferIO memory buffer, bytes32 data) internal pure {
        write(buffer, bytes.concat(data));
    }

    function writeUint256(BufferIO memory buffer, uint256 data) internal pure {
        write(buffer, bytes.concat(bytes32(data)));
    }

    function writeUint32(BufferIO memory buffer, uint32 data) internal pure {
        write(buffer, bytes.concat(bytes4(data)));
    }

    function writeUint64(BufferIO memory buffer, uint64 data) internal pure {
        write(buffer, bytes.concat(bytes8(data)));
    }

    function readBytes32(BufferIO memory buffer) internal pure returns (bytes32) {
        return bytes32(read(buffer, 32));
    }

    function readUint256(BufferIO memory buffer) internal pure returns (uint256) {
        return uint256(bytes32(read(buffer, 32)));
    }

    function readUint16(BufferIO memory buffer) internal pure returns (uint16) {
        return uint16(bytes2(read(buffer, 2)));
    }

    function readUint64(BufferIO memory buffer) internal pure returns (uint64) {
        return uint64(bytes8(read(buffer, 8)));
    }

    function readUint32(BufferIO memory buffer) internal pure returns (uint32) {
        return uint32(bytes4(read(buffer, 4)));
    }

    function computeVarIntSize(uint256 value) internal pure returns (uint256) {
        if (value <= 0xFC) {
            return 1;
        } else if (value >= 253 && value <= 0xFFFF) {
            return 2;
        } else if (value >= 65536 && value <= 0xFFFFFFFF) {
            return 4;
        } else if (value >= 4_294_967_296 && value <= 0xFFFFFFFFFFFFFFFF) {
            return 8;
        } else {
            revert("Value too large");
        }
    }

    function writeVarInt(BufferIO memory buffer, uint256 value) internal pure {
        if (value <= 0xFC) {
            write(buffer, bytes.concat(bytes1(uint8(value))));
        } else if (value >= 253 && value <= 0xFFFF) {
            write(buffer, bytes.concat(bytes1(uint8(0xFD))));
            write(buffer, bytes.concat(bytes2(Endian.reverse16(uint16(value)))));
        } else if (value >= 65536 && value <= 0xFFFFFFFF) {
            write(buffer, bytes.concat(bytes1(uint8(0xFE))));
            write(buffer, bytes.concat(bytes4(Endian.reverse32(uint32(value)))));
        } else if (value >= 4_294_967_296 && value <= 0xFFFFFFFFFFFFFFFF) {
            write(buffer, bytes.concat(bytes1(uint8(0xFF))));
            write(buffer, bytes.concat(bytes8(Endian.reverse64(uint64(value)))));
        } else {
            revert("Value too large");
        }
    }

    function readVarInt(BufferIO memory buffer) internal pure returns (uint256) {
        uint8 pivot = uint8(bytes1(read(buffer, 1)));
        if (pivot < 0xFD) {
            return uint256(pivot);
        } else if (pivot == 0xFD) {
            return uint256(Endian.reverse16(readUint16(buffer)));
        } else if (pivot == 0xFE) {
            return uint256(Endian.reverse32(readUint32(buffer)));
        } else if (pivot == 0xFF) {
            return uint256(Endian.reverse64(readUint64(buffer)));
        }

        revert("Invalid VarInt");
    }
}

// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import "../../../Buffer.sol";
import "../../../Endian.sol";
import "./wallet/scripts/IScript.sol";
import "../../../StorageWritableBufferStream.sol";

library BitcoinUtils {
    using Buffer for Buffer.BufferIO;

    enum LockType {
        Unknown,
        PubKeyHash,
        ScriptHash,
        WitnessPubKeyHash,
        WitnessScriptHash
    }

    struct BitcoinBlockHeaders {
        bytes4 version;
        bytes32 hashPrevBlock;
        bytes32 hashMerkleRoot;
        uint32 time;
        bytes4 bits;
        uint32 nonce;
    }

    struct BitcoinTransactionInput {
        bytes32 importTxHash;
        uint32 importTxOut;
        bytes scriptSig;
        bytes4 sequenceNo;
    }

    struct BitcoinTransactionOutput {
        uint64 value;
        bytes script;
    }

    struct BitcoinTransaction {
        bytes32 hash;
        bytes4 version;
        BitcoinTransactionInput[] inputs;
        BitcoinTransactionOutput[] outputs;
        uint32 lockTime;
    }

    struct WorkingScriptSet {
        IScript vaultScript;

        IScript p2pkhScript;
        IScript p2wpkhScript;
        IScript p2shScript;
        IScript p2wshScript;
    }

    function resolveLockingScript(
        bytes memory to,
        bool isTestnet,
        WorkingScriptSet memory workingScriptSet
    ) external view returns (bytes memory) {
        Buffer.BufferIO memory _buffer = Buffer.BufferIO(to, 0);

        bytes1 prefix = bytes1(_buffer.read(1));
        bytes memory hash = new bytes(0);

        LockType _lockingType = LockType.Unknown;
        if (isTestnet) {
            if (prefix == 0x6F) {
                _lockingType = LockType.PubKeyHash;
            } else if (prefix == 0xC4) {
                _lockingType = LockType.ScriptHash;
            } else if (prefix == 0xF1) {
                _lockingType = LockType.WitnessPubKeyHash;
            } else if (prefix == 0xF2) {
                _lockingType = LockType.WitnessScriptHash;
            }
        } else {
            if (prefix == 0x00) {
                _lockingType = LockType.PubKeyHash;
            } else if (prefix == 0x05) {
                _lockingType = LockType.ScriptHash;
            } else if (prefix == 0xF3) {
                _lockingType = LockType.WitnessPubKeyHash;
            } else if (prefix == 0xF4) {
                _lockingType = LockType.WitnessScriptHash;
            }
        }

        if (_lockingType == LockType.WitnessScriptHash) {
            hash = _buffer.read(32);
        } else {
            hash = _buffer.read(20);
        }

        bytes4 checksum = bytes4(_buffer.read(4));
        bytes32 calculatedChecksum = bytes32(
            Endian.reverse256(
                uint256(_doubleSha256(abi.encodePacked(prefix, hash)))
            )
        );

        require(bytes4(calculatedChecksum) == checksum, "CM");

        bytes memory _lockingScript = new bytes(0);
        if (_lockingType == LockType.ScriptHash) {
            _lockingScript = workingScriptSet.p2shScript.serialize(abi.encode(bytes20(hash)));
        } else if (_lockingType == LockType.PubKeyHash) {
            _lockingScript = workingScriptSet.p2pkhScript.serialize(abi.encode(bytes20(hash)));
        } else if (_lockingType == LockType.WitnessPubKeyHash) {
            _lockingScript = workingScriptSet.p2wpkhScript.serialize(abi.encode(bytes20(hash)));
        } else if (_lockingType == LockType.WitnessScriptHash) {
            _lockingScript = workingScriptSet.p2wshScript.serialize(abi.encode(bytes32(hash)));
        } else {
            revert("IT");
        }

        return _lockingScript;
    }

    function hash160(bytes memory addressData) external pure returns (bytes20) {
        return bytes20(uint160(ripemd160(abi.encodePacked(sha256(addressData)))));
    }

    function serializeTransactionInputs(
        StorageWritableBufferStream.WritableBufferStream storage _buffer,
        BitcoinTransaction storage _tx,
        uint256 _from,
        uint256 _to
    ) external {
        for (uint i = _from; i < _to; i++) {
            BitcoinTransactionInput storage _input = _tx.inputs[i];

            StorageWritableBufferStream.writeBytes32(_buffer, bytes32(Endian.reverse256(uint256(_input.importTxHash))));
            StorageWritableBufferStream.writeUint32(_buffer, Endian.reverse32(uint32(_input.importTxOut)));

            StorageWritableBufferStream.writeVarInt(_buffer, _input.scriptSig.length);
            StorageWritableBufferStream.write(_buffer, _input.scriptSig);

            StorageWritableBufferStream.writeUint32(_buffer, Endian.reverse32(uint32(_input.sequenceNo)));
        }
    }

    function serializeTransactionOutputsHeader(
        StorageWritableBufferStream.WritableBufferStream storage _buffer,
        BitcoinTransaction storage _tx
    ) external {
        StorageWritableBufferStream.writeVarInt(_buffer, _tx.outputs.length);
    }

    function serializeTransactionOutputs(
        StorageWritableBufferStream.WritableBufferStream storage _buffer,
        BitcoinTransaction storage _tx,
        uint256 _from,
        uint256 _to
    ) external {
        for (uint i = _from; i < _to; i++) {
            BitcoinTransactionOutput storage _output = _tx.outputs[i];

            StorageWritableBufferStream.writeUint64(_buffer, Endian.reverse64(_output.value));

            StorageWritableBufferStream.writeVarInt(_buffer, _output.script.length);
            StorageWritableBufferStream.write(_buffer, _output.script);
        }
    }

    function serializeTransactionTail(
        StorageWritableBufferStream.WritableBufferStream storage _buffer,
        BitcoinTransaction storage _tx
    ) external {
        StorageWritableBufferStream.write(_buffer, bytes.concat(bytes4(Endian.reverse32(uint32(_tx.lockTime)))));
    }

    function serializeTransactionHeader(
        StorageWritableBufferStream.WritableBufferStream storage _buffer,
        BitcoinTransaction storage _tx
    ) external {
        StorageWritableBufferStream.write(_buffer, bytes.concat(bytes4(Endian.reverse32(uint32(_tx.version)))));
        StorageWritableBufferStream.writeVarInt(_buffer, _tx.inputs.length);
    }

    // NOTE: No SegWit allowed
    function deserializeTransaction(Buffer.BufferIO memory _buffer) external pure returns (BitcoinTransaction memory _tx) {
        _tx.hash = _doubleSha256(_buffer.data);
        _tx.version = bytes4(Endian.reverse32(_buffer.readUint32()));

        uint256 txInCount = _buffer.readVarInt();
        BitcoinTransactionInput[] memory inputs = new BitcoinTransactionInput[](txInCount);

        // Fill inputs
        for (uint i = 0; i < txInCount; i++) {
            inputs[i].importTxHash = bytes32(Endian.reverse256(_buffer.readUint256()));
            inputs[i].importTxOut = Endian.reverse32(_buffer.readUint32());

            uint256 scriptSigLength = _buffer.readVarInt();
            inputs[i].scriptSig = _buffer.read(scriptSigLength);
            inputs[i].sequenceNo = bytes4(Endian.reverse32(_buffer.readUint32()));
        }

        _tx.inputs = inputs;

        uint256 txOutCount = _buffer.readVarInt();
        BitcoinTransactionOutput[] memory outputs = new BitcoinTransactionOutput[](txOutCount);

        // Fill outputs
        for (uint i = 0; i < txOutCount; i++) {
            outputs[i].value = Endian.reverse64(_buffer.readUint64());

            uint256 scriptLength = _buffer.readVarInt();
            outputs[i].script = _buffer.read(scriptLength);
        }

        _tx.outputs = outputs;
        _tx.lockTime = Endian.reverse32(_buffer.readUint32());

        return _tx;
    }

    function getDifficultyTarget(bytes4 _bits) external pure returns (uint256) {
        uint32 bits = uint32(_bits);

        uint256 exp = bits >> 24;
        uint256 mant = bits & 0xffffff;

        return mant * (1 << (8 * (exp - 3)));
    }

    function _doubleSha256(bytes memory data) internal pure returns (bytes32) {
        return bytes32(Endian.reverse256(uint256(sha256(bytes.concat(sha256(data))))));
    }

    function doubleSha256(bytes memory data) external pure returns (bytes32) {
        return _doubleSha256(data);
    }

    function hashBlock(BitcoinBlockHeaders memory _block) external pure returns (bytes32) {
        Buffer.BufferIO memory _buffer = Buffer.alloc(80);

        _buffer.writeUint32(Endian.reverse32(uint32(_block.version)));
        _buffer.writeBytes32(bytes32(Endian.reverse256(uint256(_block.hashPrevBlock))));
        _buffer.writeBytes32(bytes32(Endian.reverse256(uint256(_block.hashMerkleRoot))));
        _buffer.writeUint32(Endian.reverse32(_block.time));
        _buffer.writeUint32(Endian.reverse32(uint32(_block.bits)));
        _buffer.writeUint32(Endian.reverse32(_block.nonce));

        return _doubleSha256(_buffer.data);
    }

    function deserializeBlockHeaders(Buffer.BufferIO memory _buffer) external pure returns (BitcoinBlockHeaders memory) {
        return BitcoinBlockHeaders(
            bytes4(Endian.reverse32(_buffer.readUint32())),
            bytes32(Endian.reverse256(_buffer.readUint256())),
            bytes32(Endian.reverse256(_buffer.readUint256())),
            Endian.reverse32(_buffer.readUint32()),
            bytes4(Endian.reverse32(_buffer.readUint32())),
            Endian.reverse32(_buffer.readUint32())
        );
    }
}

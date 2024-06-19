// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import "../IScript.sol";
import "../../../../../../Buffer.sol";
import {ScriptP2SH} from "../ScriptP2SH.sol";

contract ScriptVault is IScript {
    using Buffer for Buffer.BufferIO;

    bytes1 public constant OP_HASH160 = 0xa9;
    bytes1 public constant OP_DUP = 0x76;
    bytes1 public constant OP_EQUALVERIFY = 0x88;
    bytes1 public constant OP_CHECKSIGVERIFY = 0xad;

    bytes1 public constant OP_1 = 0x51;
    bytes1 public constant OP_CHECKMULTISIG = 0xae;

    bytes1 public constant OP_PUSHBYTES_71 = 0x47;
    bytes1 public constant OP_PUSHBYTES_33 = 0x21;

    function serialize(bytes memory in_args) public pure override returns (bytes memory) {
        (bytes20 contractSignerPubKeyHash, bytes memory offchainSignerDerPubKey) = abi.decode(in_args, (
            bytes20, bytes
        ));

        Buffer.BufferIO memory _buffer = Buffer.alloc(62);

        // Contract-signer verification
        _buffer.write(abi.encodePacked(OP_DUP, OP_HASH160));
        _buffer.write(abi.encodePacked(bytes1(0x14), contractSignerPubKeyHash));
        _buffer.write(abi.encodePacked(OP_EQUALVERIFY, OP_CHECKSIGVERIFY));

        // Offchain-signer verification
        _buffer.write(abi.encodePacked(OP_1));
        _buffer.write(abi.encodePacked(bytes1(0x21), offchainSignerDerPubKey));
        _buffer.write(abi.encodePacked(OP_1));
        _buffer.write(abi.encodePacked(OP_CHECKMULTISIG));

        return _buffer.data;
    }

    function serializeUnlockScript(
        bytes memory contractSignature,
        bytes memory offchainSignature,
        bytes memory contractPubKey
    ) public pure returns (bytes memory) {
        Buffer.BufferIO memory _buffer = Buffer.alloc(
            offchainSignature.length + 1 + contractSignature.length + 1 + contractPubKey.length // offchainSigner.signature, contractSigner.signature, contractSigner.pubKey
            + 1 + 1 + 1 // OP_PUSHBYTES_71, OP_PUSHBYTES_71, OP_PUSHBYTES_33
        );

        // We skip OP_0 because it already exists in ScriptP2SH.serializeRedemption
        _buffer.write(abi.encodePacked(uint8(offchainSignature.length + 1)));
        _buffer.write(offchainSignature);
        _buffer.write(abi.encodePacked(bytes1(0x01)));

        _buffer.write(abi.encodePacked(uint8(contractSignature.length + 1)));
        _buffer.write(contractSignature);
        _buffer.write(abi.encodePacked(bytes1(0x01)));

        _buffer.write(abi.encodePacked(uint8(contractPubKey.length)));
        _buffer.write(contractPubKey);

        return _buffer.data;
    }

    function deserialize(bytes memory) public pure override returns (bytes memory) {
        return new bytes(0); // No need to deserialize it
    }

    function id() public override pure returns (bytes4) {
        return bytes4(keccak256(abi.encodePacked(type(ScriptVault).name)));
    }
}

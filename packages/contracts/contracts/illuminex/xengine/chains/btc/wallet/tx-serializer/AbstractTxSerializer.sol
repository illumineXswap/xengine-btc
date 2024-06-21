// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import "@oasisprotocol/sapphire-contracts/contracts/Sapphire.sol";

import "./TxSerializerLib.sol";
import "./interfaces/ITxInputsStorage.sol";
import "./interfaces/ITxSecretsStorage.sol";
import "../../BitcoinUtils.sol";

import "../scripts/ScriptP2SH.sol";
import "../scripts/vault/ScriptVault.sol";

import "../../AllowedRelayers.sol";

abstract contract AbstractTxSerializer is AllowedRelayers {
    struct FeeConfig {
        uint64 outgoingTransferCost;
        uint64 incomingTransferCost;
    }

    struct PartiallySignedInput {
        bytes sig0;
        bytes scriptPubKey;
    }

    struct TxSkeleton {
        bool initialized;
        bool hasSufficientInputs;

        BitcoinUtils.BitcoinTransaction tx;
        uint256 changeSystemIdx;

        uint64 totalTransfersValueWithoutChange;
        uint64 totalValueImported;

        mapping(uint256 => bytes32) sigHashes;
        mapping(uint256 => PartiallySignedInput) partiallySignedInputs;
        uint256 lastPartiallySignedInput;

        uint256 scriptSigsWritten;
    }

    event PartialInputSignature(bytes32 sigHash);
    event SigHashFormed(bytes32 sigHash);

    uint32 public constant OUTGOING_INPUT_SEQUENCE_NO = 1;
    bytes4 public constant SIGHASH_ALL = 0x01000000;

    ITxSecretsStorage public immutable secretsStorage;
    ITxInputsStorage public immutable inputsStorage;
    BitcoinUtils.WorkingScriptSet public scriptSet;
    FeeConfig public fees;

    TxSerializerLib.TxSerializingProgress internal _serializing;
    TxSkeleton internal _skeleton;

    mapping(bytes32 => TxSerializerLib.TxSerializingProgress) internal _sigHashSerializing;

    constructor(
        ITxSecretsStorage _secretsStorage,
        ITxInputsStorage _inputsStorage,
        BitcoinUtils.WorkingScriptSet memory _scripts,
        FeeConfig memory _fees
    ) {
        secretsStorage = _secretsStorage;
        inputsStorage = _inputsStorage;
        scriptSet = _scripts;
        fees = _fees;

        _skeleton.tx.version = bytes4(uint32(1));
        _skeleton.tx.lockTime = uint32(0);

        _toggleRelayer(msg.sender); // disable factory being relayer
    }

    function _getKeyPair(bytes32 inputId) internal view returns (bytes memory, bytes memory) {
        return secretsStorage.getKeyPair(inputId);
    }

    function _sign(
        bytes32 _inputId,
        bytes32 _sigHash
    ) internal view returns (bytes memory sig) {
        (, bytes memory privKey) = _getKeyPair(_inputId);

        sig = Sapphire.sign(
            Sapphire.SigningAlg.Secp256k1PrehashedSha256,
            privKey,
            bytes.concat(_sigHash),
            ""
        );
    }

    function _inputHash(bytes32 txHash, uint256 txOutIndex) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(txHash, txOutIndex));
    }

    function _isInputAllowed(bytes32 _inputId) internal virtual view returns (bool);

    function _addInput(bytes32 inputId) internal {
        (uint64 value, bytes32 txHash, uint32 txOutIndex) = inputsStorage.fetchInput(inputId);
        _skeleton.totalValueImported += value;

        _skeleton.tx.inputs.push(BitcoinUtils.BitcoinTransactionInput({
            sequenceNo: bytes4(OUTGOING_INPUT_SEQUENCE_NO),
            importTxHash: txHash,
            importTxOut: txOutIndex,
            scriptSig: new bytes(0)
        }));
    }

    function isFinished() public view returns (bool) {
        return _serializing.state == TxSerializerLib.TxSerializingState.Finished;
    }

    function _addChangeOutput(uint64 _netFee) internal virtual {
        (uint256 _rChangeSystemIdx, bytes20 _changeScriptHash) = secretsStorage.deriveChangeInfo(
            keccak256(abi.encodePacked(
                _skeleton.tx.inputs[0].importTxHash,
                _skeleton.tx.inputs.length
            ))
        );

        _skeleton.changeSystemIdx = _rChangeSystemIdx;

        _skeleton.tx.outputs.push(BitcoinUtils.BitcoinTransactionOutput({
            value: _skeleton.totalValueImported - (_skeleton.totalTransfersValueWithoutChange + _netFee),
            script: scriptSet.p2shScript.serialize(
                abi.encode(_changeScriptHash)
            )
        }));
    }

    function _estimateFees() internal virtual view returns (uint64) {
        return uint64(fees.outgoingTransferCost * (_skeleton.tx.outputs.length + 1))
            + uint64(fees.incomingTransferCost * _skeleton.tx.inputs.length);
    }

    function enrichOutgoingTransaction(bytes32[] memory inputsToSpend) public virtual onlyRelayer {
        require(!_skeleton.hasSufficientInputs && _skeleton.initialized, "AHS");
        require(!isFinished(), "AF");

        for (uint i = 0; i < inputsToSpend.length; i++) {
            bytes32 inputId = inputsToSpend[i];
            require(_isInputAllowed(inputId), "IRF");

            inputsStorage.spendInput(inputId);
            _addInput(inputId);
        }

        uint64 _netFee = _estimateFees();
        if (_skeleton.totalValueImported >= _skeleton.totalTransfersValueWithoutChange + _netFee) {
            _addChangeOutput(_netFee);
            _skeleton.hasSufficientInputs = true;
        }
    }

    function enrichSigHash(uint256 inputIndex, uint256 count) public virtual onlyRelayer {
        require(_skeleton.sigHashes[inputIndex] == bytes32(0), "AH");
        require(!isFinished(), "AF");

        BitcoinUtils.BitcoinTransactionInput storage _input = _skeleton.tx.inputs[inputIndex];
        bytes32 inputId = _inputHash(_input.importTxHash, _input.importTxOut);

        (bytes memory _pubKey,) = _getKeyPair(inputId);

        _skeleton.partiallySignedInputs[inputIndex].scriptPubKey = scriptSet.vaultScript.serialize(
            abi.encode(BitcoinUtils.hash160(_pubKey), inputsStorage.fetchOffchainPubKey(inputId))
        );

        _skeleton.tx.inputs[inputIndex].scriptSig = _skeleton.partiallySignedInputs[inputIndex].scriptPubKey;

        TxSerializerLib.TxSerializingProgress storage _sigHashSerializer = _sigHashSerializing[inputId];
        TxSerializerLib.serializeTx(_sigHashSerializer, _skeleton.tx, count);

        _skeleton.tx.inputs[inputIndex].scriptSig = new bytes(0);

        if (_sigHashSerializer.state == TxSerializerLib.TxSerializingState.Finished) {
            StorageWritableBufferStream.write(_sigHashSerializer.stream, bytes.concat(SIGHASH_ALL));

            _skeleton.sigHashes[inputIndex] = sha256(bytes.concat(sha256(_sigHashSerializer.stream.data)));
            emit SigHashFormed(_skeleton.sigHashes[inputIndex]);
        }
    }

    function partiallySignOutgoingTransaction(uint256 count) public virtual onlyRelayer {
        require(
            _skeleton.tx.hash == bytes32(0)
            && _skeleton.initialized
            && _skeleton.hasSufficientInputs,
            "CAD"
        );

        require(!isFinished(), "AF");

        uint i = _skeleton.lastPartiallySignedInput;
        for (; i < _skeleton.lastPartiallySignedInput + count; i++) {
            bytes32 _sigHash = _skeleton.sigHashes[i];
            require(_sigHash != bytes32(0), "IH");

            BitcoinUtils.BitcoinTransactionInput storage _input = _skeleton.tx.inputs[i];

            bytes32 inputId = _inputHash(_input.importTxHash, _input.importTxOut);
            bytes memory contractSignature = _sign(
                inputId,
                _sigHash
            );

            _skeleton.partiallySignedInputs[i].sig0 = contractSignature;
            emit PartialInputSignature(_sigHash);
        }

        _skeleton.lastPartiallySignedInput = i;
    }

    function serializeOutgoingTransaction(uint256 count, bytes memory signature) public onlyRelayer {
        require(
            _skeleton.tx.hash == bytes32(0)
            && _skeleton.initialized
            && _skeleton.hasSufficientInputs
            && _skeleton.lastPartiallySignedInput == _skeleton.tx.inputs.length,
            "CAD"
        );

        require(!isFinished(), "AF");

        if (_skeleton.scriptSigsWritten < _skeleton.tx.inputs.length) {
            require(_writeScriptSigs(count, signature), "FVS");
            _skeleton.scriptSigsWritten += count;
        }

        if (_skeleton.scriptSigsWritten >= _skeleton.tx.inputs.length) {
            TxSerializerLib.serializeTx(_serializing, _skeleton.tx, count);
            _skeleton.tx.hash = BitcoinUtils.doubleSha256(_serializing.stream.data);
        }
    }

    function getRaw() public view returns (bytes memory, bytes32) {
        require(_serializing.state == TxSerializerLib.TxSerializingState.Finished, "NF");
        return (_serializing.stream.data, _skeleton.tx.hash);
    }

    function getChangeInfo() public view returns (uint256, uint64, uint256 _idx) {
        _idx = _skeleton.tx.outputs.length - 1;
        return (_skeleton.changeSystemIdx, _skeleton.tx.outputs[_idx].value, _idx);
    }

    function _writeScriptSigs(
        uint256 count,
        bytes memory _offchainSig
    ) internal returns (bool) {
        (bytes[] memory _signaturesUnpacked) = abi.decode(_offchainSig, (bytes[]));

        bool _sigsValid = true;
        for (uint i = _skeleton.scriptSigsWritten; i < _skeleton.scriptSigsWritten + count && _sigsValid; i++) {
            PartiallySignedInput storage _partiallySigned = _skeleton.partiallySignedInputs[i];

            {
                (bytes memory _pubKey,) = _getKeyPair(
                    _inputHash(_skeleton.tx.inputs[i].importTxHash, _skeleton.tx.inputs[i].importTxOut)
                );

                _skeleton.tx.inputs[i].scriptSig = ScriptP2SH(address(scriptSet.p2shScript)).serializeRedemption(
                    _partiallySigned.scriptPubKey,
                    ScriptVault(address(scriptSet.vaultScript)).serializeUnlockScript(
                        _partiallySigned.sig0,
                        _signaturesUnpacked[i - _skeleton.scriptSigsWritten],
                        _pubKey
                    )
                );
            }

            {
                _sigsValid = Sapphire.verify(
                    Sapphire.SigningAlg.Secp256k1PrehashedSha256,
                    inputsStorage.fetchOffchainPubKey(
                        _inputHash(_skeleton.tx.inputs[i].importTxHash, _skeleton.tx.inputs[i].importTxOut)
                    ),
                    abi.encodePacked(_skeleton.sigHashes[i]),
                    "",
                    _signaturesUnpacked[i]
                );
            }
        }

        return _sigsValid;
    }
}

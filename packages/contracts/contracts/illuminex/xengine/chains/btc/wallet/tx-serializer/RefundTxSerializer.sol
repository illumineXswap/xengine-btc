// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import "./AbstractTxSerializer.sol";
import "../OutgoingQueue.sol";

contract RefundTxSerializer is AbstractTxSerializer {
    using Buffer for Buffer.BufferIO;

    bytes32 public immutable inputId;
    address public immutable vaultWallet;

    bytes1 public constant OP_RETURN = 0x6a;
    uint8 public constant MAX_BYTES = 10;

    constructor(
        ITxSecretsStorage _secretsStorage,
        ITxInputsStorage _inputsStorage,
        BitcoinUtils.WorkingScriptSet memory _scripts,
        AbstractTxSerializer.FeeConfig memory _fees,
        address _vaultWallet,
        bytes32 _inputId,
        bytes memory _lockScript,
        bytes memory _amlFeesLockScript,
        uint64 _amlFees
    ) AbstractTxSerializer(
    _secretsStorage,
    _inputsStorage,
    _scripts,
    _fees
    ) AllowedRelayers(_vaultWallet) {
        vaultWallet = _vaultWallet;

        (uint64 value,,) = inputsStorage.fetchInput(_inputId);

        uint64 valueToReceive = value - _amlFees - _estimateFees();

        {
            _skeleton.tx.outputs.push(BitcoinUtils.BitcoinTransactionOutput({
                value: valueToReceive,
                script: _lockScript
            }));

            _skeleton.tx.outputs.push(BitcoinUtils.BitcoinTransactionOutput({
                value: _amlFees,
                script: _amlFeesLockScript
            }));

            _skeleton.tx.outputs.push(BitcoinUtils.BitcoinTransactionOutput({
                value: 0,
                script: _serializeReturn(bytes.concat("AML_REFUND"))
            }));
        }

        inputId = _inputId;

        _skeleton.totalTransfersValueWithoutChange = valueToReceive + _amlFees;
        _skeleton.initialized = true;
    }

    function _serializeReturn(bytes memory memo) private pure returns (bytes memory) {
        require(memo.length <= MAX_BYTES, "Invalid OP_RETURN length");

        Buffer.BufferIO memory _buffer = Buffer.alloc(2 + memo.length);

        _buffer.write(abi.encodePacked(OP_RETURN));
        _buffer.write(abi.encodePacked(bytes1(uint8(memo.length)), memo));

        return _buffer.data;
    }

    function init() public {
        require(msg.sender == vaultWallet, "NVW");

        bytes32[] memory _inputsToSpend = new bytes32[](1);
        _inputsToSpend[0] = inputId;

        _enrichOutgoingTransaction(_inputsToSpend);
        _enrichSigHash(0, 1);
        _enrichSigHash(0, 3);
        _partiallySignOutgoingTransaction(1);
    }

    function finalise(bytes memory signature) public {
        require(msg.sender == vaultWallet, "NVW");

        bytes[] memory _sigs = new bytes[](1);
        _sigs[0] = signature;

        _serializeOutgoingTransaction(1, _sigs);
        _serializeOutgoingTransaction(3, _sigs);
    }

    function _isInputAllowed(bytes32 _inputId) internal override view returns (bool) {
        return _inputId == inputId && inputsStorage.isRefundInput(_inputId);
    }

    function _estimateFees() internal virtual override view returns (uint64) {
        // 1 input, 3 outputs
        return (uint64(fees.outgoingTransferCost) * 3)
            + uint64(fees.incomingTransferCost);
    }

    // Do nothing...
    function _addChangeOutput(uint64 _netFee) internal virtual override {}
}

// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import "./AbstractTxSerializer.sol";
import "../OutgoingQueue.sol";

contract RefundTxSerializer is AbstractTxSerializer {
    bytes32 public immutable inputId;
    address public immutable vaultWallet;

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
        }

        inputId = _inputId;

        _skeleton.totalTransfersValueWithoutChange = valueToReceive + _amlFees;
        _skeleton.initialized = true;
    }

    function init() public {
        require(msg.sender == vaultWallet, "NVW");

        bytes32[] memory _inputsToSpend = new bytes32[](1);
        _inputsToSpend[0] = inputId;

        _enrichOutgoingTransaction(_inputsToSpend);
        _enrichSigHash(0, 1);
        _enrichSigHash(0, 2);
        _partiallySignOutgoingTransaction(1);
    }

    function finalise(bytes memory signature) public {
        require(msg.sender == vaultWallet, "NVW");

        bytes[] memory _sigs = new bytes[](1);
        _sigs[0] = signature;

        _serializeOutgoingTransaction(1, _sigs);
        _serializeOutgoingTransaction(2, _sigs);
    }

    function _isInputAllowed(bytes32 _inputId) internal override view returns (bool) {
        return _inputId == inputId && inputsStorage.isRefundInput(_inputId);
    }

    function _estimateFees() internal virtual override view returns (uint64) {
        // 1 input, 2 outputs
        return (uint64(fees.outgoingTransferCost) * 2) + uint64(fees.incomingTransferCost);
    }

    // Do nothing...
    function _addChangeOutput(uint64 _netFee) internal virtual override {}
}

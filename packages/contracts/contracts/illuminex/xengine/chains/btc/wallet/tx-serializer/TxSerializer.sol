// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import "./AbstractTxSerializer.sol";
import "../OutgoingQueue.sol";

contract TxSerializer is AbstractTxSerializer {
    constructor(
        ITxSecretsStorage _secretsStorage,
        ITxInputsStorage _inputsStorage,
        BitcoinUtils.WorkingScriptSet memory _scripts,
        AbstractTxSerializer.FeeConfig memory _fees,
        OutgoingQueue.OutgoingTransfer[] memory _transfers
    ) AbstractTxSerializer(
    _secretsStorage,
    _inputsStorage,
    _scripts,
    _fees
    ) {
        _init(_transfers);
    }

    function _isInputAllowed(bytes32 _inputId) internal override view returns (bool) {
        return !inputsStorage.isRefuelInput(_inputId);
    }

    function _init(OutgoingQueue.OutgoingTransfer[] memory _transfers) internal {
        for (uint i = 0; i < _transfers.length; i++) {
            _skeleton.totalTransfersValueWithoutChange += _transfers[i].value;
            _skeleton.tx.outputs.push(BitcoinUtils.BitcoinTransactionOutput({
                value: _transfers[i].value,
                script: _transfers[i].lockScript
            }));
        }

        _skeleton.initialized = true;
    }

    function getTotalValueImported() public view returns (uint256) {
        return _skeleton.totalValueImported;
    }

    function getBitcoinTransaction() public view returns (BitcoinUtils.BitcoinTransaction memory) {
        return _skeleton.tx;
    }

    function getInputsCount() public view returns (uint256) {
        return _skeleton.tx.inputs.length;
    }
}

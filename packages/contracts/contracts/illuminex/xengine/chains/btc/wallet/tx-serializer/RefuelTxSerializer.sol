// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import "./AbstractTxSerializer.sol";
import "./TxSerializer.sol";

contract RefuelTxSerializer is AbstractTxSerializer {
    TxSerializer public immutable derivedFrom;

    constructor(
        TxSerializer _deriveFrom,
        BitcoinUtils.WorkingScriptSet memory _scriptSet,
        AbstractTxSerializer.FeeConfig memory _fees
    ) AbstractTxSerializer(
    _deriveFrom.secretsStorage(),
    _deriveFrom.inputsStorage(),
    _scriptSet,
    _fees
    ) {
        require(_deriveFrom.isFinished());
        derivedFrom = _deriveFrom;

        _copyParentOutputs();
    }

    function _isInputAllowed(bytes32 _inputId) internal override view returns (bool) {
        return inputsStorage.isRefuelInput(_inputId);
    }

    function _isParentCopied() internal view returns (bool) {
        BitcoinUtils.BitcoinTransaction memory _parentTx = derivedFrom.getBitcoinTransaction();
        return _skeleton.tx.inputs.length >= _parentTx.inputs.length;
    }

    function _copyParentOutputs() internal {
        BitcoinUtils.BitcoinTransaction memory _parentTx = derivedFrom.getBitcoinTransaction();
        for (uint i = 0; i < _parentTx.outputs.length; i++) {
            _skeleton.totalTransfersValueWithoutChange += _parentTx.outputs[i].value;
            _skeleton.tx.outputs.push(BitcoinUtils.BitcoinTransactionOutput({
                value: _parentTx.outputs[i].value,
                script: _parentTx.outputs[i].script
            }));
        }
    }

    function _estimateFees() internal virtual override view returns (uint64 _netFee) {
        // Remove outputs change output cost since we do not need it here
        _netFee = super._estimateFees() - fees.outgoingTransferCost;
    }

    // Do nothing...
    function _addChangeOutput(uint64 _netFee) internal virtual override {}

    function copyParentInputs(uint256 count) public {
        require(!_isParentCopied(), "PAC");

        BitcoinUtils.BitcoinTransaction memory _parentTx = derivedFrom.getBitcoinTransaction();

        uint256 _inputsCopied = _skeleton.tx.inputs.length;
        for (uint i = _inputsCopied; i < _inputsCopied + count; i++) {
            _addInput(_inputHash(_parentTx.inputs[i].importTxHash, _parentTx.inputs[i].importTxOut));
        }

        if (_isParentCopied()) {
            _skeleton.initialized = true;
        }
    }

    function enrichOutgoingTransaction(bytes32[] memory inputsToSpend) public override {
        super.enrichOutgoingTransaction(inputsToSpend);
        require(_skeleton.totalValueImported > derivedFrom.getTotalValueImported(), "NEV");
    }
}

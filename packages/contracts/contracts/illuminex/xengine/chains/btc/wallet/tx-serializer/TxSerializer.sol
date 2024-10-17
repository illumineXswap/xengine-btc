// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import "./AbstractTxSerializer.sol";
import "../OutgoingQueue.sol";

contract TxSerializer is AbstractTxSerializer {
    bytes32 public immutable sliceIndex;
    OutgoingQueue public immutable queue;

    uint256 public lastCopiedOutputIndex;
    bool public inConsolidationMode;

    bytes1 public constant OP_RETURN = 0x6a;

    constructor(
        ITxSecretsStorage _secretsStorage,
        ITxInputsStorage _inputsStorage,
        BitcoinUtils.WorkingScriptSet memory _scripts,
        AbstractTxSerializer.FeeConfig memory _fees,
        address _queue,
        bytes32 _sliceIndex,
        address _vaultWallet
    ) AbstractTxSerializer(
    _secretsStorage,
    _inputsStorage,
    _scripts,
    _fees
    ) AllowedRelayers(_vaultWallet) {
        queue = OutgoingQueue(_queue);
        sliceIndex = _sliceIndex;
    }

    function _isEnrichmentExtraConditionMet() internal virtual override view returns (bool) {
        if (inConsolidationMode) {
            return _skeleton.tx.inputs.length >= MAX_INPUTS_PER_TX / 2;
        }

        return true;
    }

    function _isInputAllowed(bytes32 _inputId) internal override view returns (bool) {
        return !inputsStorage.isRefuelInput(_inputId) && !inputsStorage.isRefundInput(_inputId);
    }

    function copyOutputs(uint256 count) public onlyRelayer {
        require(!_skeleton.initialized, "INIT_ERR");

        (uint256 _start, uint256 _end, bool _isConsolidation) = queue.slices(sliceIndex);
        inConsolidationMode = _isConsolidation;

        OutgoingQueue.OutgoingTransfer[] memory _transfers = queue.walk(
            sliceIndex,
            lastCopiedOutputIndex,
            lastCopiedOutputIndex + count
        );

        for (uint i = 0; i < _transfers.length; i++) {
            _skeleton.totalTransfersValueWithoutChange += _transfers[i].value;
            _skeleton.tx.outputs.push(BitcoinUtils.BitcoinTransactionOutput({
                value: _transfers[i].value,
                script: _transfers[i].lockScript
            }));
        }

        lastCopiedOutputIndex += count;
        if (_skeleton.tx.outputs.length == _end - _start) {
            _skeleton.initialized = true;
        }
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

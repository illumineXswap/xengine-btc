// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import "../../BitcoinUtils.sol";

library TxSerializerLib {
    enum TxSerializingState {
        Headers,
        Inputs,
        Outputs,
        Finished
    }

    struct TxSerializingProgress {
        TxSerializingState state;
        StorageWritableBufferStream.WritableBufferStream stream;
        uint256 progress;
    }

    function serializeTx(
        TxSerializingProgress storage _progress,
        BitcoinUtils.BitcoinTransaction storage _tx,
        uint256 _count
    ) external {
        require(_progress.state != TxSerializingState.Finished, "AF");

        if (_progress.state == TxSerializingState.Headers) {
            BitcoinUtils.serializeTransactionHeader(_progress.stream, _tx);
            _progress.state = TxSerializingState.Inputs;
        }

        if (_progress.state == TxSerializingState.Inputs) {
            // Serialize inputs
            BitcoinUtils.serializeTransactionInputs(
                _progress.stream,
                _tx,
                _progress.progress,
                _progress.progress + _count
            );

            _progress.progress += _count;
            if (_progress.progress == _tx.inputs.length) {
                BitcoinUtils.serializeTransactionOutputsHeader(_progress.stream, _tx);

                _progress.state = TxSerializingState.Outputs;
                _progress.progress = 0;
            }
        }

        if (_progress.state == TxSerializingState.Outputs) {
            BitcoinUtils.serializeTransactionOutputs(
                _progress.stream,
                _tx,
                _progress.progress,
                _progress.progress + _count
            );

            _progress.progress += _count;
            if (_progress.progress == _tx.outputs.length) {
                BitcoinUtils.serializeTransactionTail(_progress.stream, _tx);
                _progress.state = TxSerializingState.Finished;
            }
        }
    }
}

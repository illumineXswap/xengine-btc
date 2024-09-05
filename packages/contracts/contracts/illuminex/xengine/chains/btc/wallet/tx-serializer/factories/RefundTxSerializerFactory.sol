// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import "../RefundTxSerializer.sol";
import "./AbstractTxSerializerFactory.sol";

contract RefundTxSerializerFactory is AbstractTxSerializerFactory {
    constructor(BitcoinUtils.WorkingScriptSet memory _scripts) AbstractTxSerializerFactory(_scripts) {}

    function createRefundSerializer(
        TxSerializer.FeeConfig memory _fees,
        bytes32 inputId,
        bytes memory lockingScript
    ) public returns (RefundTxSerializer _serializer) {
        require(msg.sender == allowedCreator, "NAC");

        _serializer = new RefundTxSerializer(
            secretsStorage,
            inputsStorage,
            scriptSet,
            _fees,
            msg.sender,
            inputId,
            lockingScript
        );

        _serializer.transferOwnership(msg.sender);

        isDeployedSerializer[address(_serializer)] = true;
        emit TransactionSerializerCreated(address(_serializer));
    }
}

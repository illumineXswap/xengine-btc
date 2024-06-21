// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import "../TxSerializer.sol";
import "./AbstractTxSerializerFactory.sol";

contract TxSerializerFactory is AbstractTxSerializerFactory {
    constructor(BitcoinUtils.WorkingScriptSet memory _scripts) AbstractTxSerializerFactory(_scripts) {}

    function createSerializer(
        TxSerializer.FeeConfig memory _fees,
        OutgoingQueue.OutgoingTransfer[] memory _transfers
    ) public returns (TxSerializer _serializer) {
        require(msg.sender == allowedCreator, "NAC");

        _serializer = new TxSerializer(secretsStorage, inputsStorage, scriptSet, _fees, _transfers);
        _serializer.transferOwnership(msg.sender);

        isDeployedSerializer[address(_serializer)] = true;
        emit TransactionSerializerCreated(address(_serializer));
    }
}

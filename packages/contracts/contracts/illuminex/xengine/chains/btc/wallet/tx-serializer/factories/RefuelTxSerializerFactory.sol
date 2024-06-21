// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import "../TxSerializer.sol";
import "../RefuelTxSerializer.sol";
import "./AbstractTxSerializerFactory.sol";

contract RefuelTxSerializerFactory is AbstractTxSerializerFactory {
    constructor(BitcoinUtils.WorkingScriptSet memory _scripts) AbstractTxSerializerFactory(_scripts) {}

    function createRefuelSerializer(TxSerializer parent) public returns (RefuelTxSerializer _serializer) {
        require(msg.sender == allowedCreator, "NAC");

        (uint64 outgoingTransferCost, uint64 incomingTransferCost) = parent.fees();
        (
            IScript vaultScript,
            IScript p2pkhScript,
            IScript p2wpkhScript,
            IScript p2shScript,
            IScript p2wshScript
        ) = parent.scriptSet();

        _serializer = new RefuelTxSerializer(
            parent,
            BitcoinUtils.WorkingScriptSet(vaultScript, p2pkhScript, p2wpkhScript, p2shScript, p2wshScript),
            AbstractTxSerializer.FeeConfig(outgoingTransferCost, incomingTransferCost)
        );

        _serializer.transferOwnership(msg.sender);

        isDeployedSerializer[address(_serializer)] = true;
        emit TransactionSerializerCreated(address(_serializer));
    }
}

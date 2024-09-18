// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import "../RefundTxSerializer.sol";
import "./AbstractTxSerializerFactory.sol";

contract RefundTxSerializerFactory is AbstractTxSerializerFactory, Ownable {
    bytes1 public constant OP_RETURN = 0x6a;

    bytes public amlFeesCollectorLockScript = bytes.concat(OP_RETURN);
    uint64 public amlFees = 1;

    event AMLFeesCollectorUpdate(bytes newAddress);
    event AMLFeesUpdate(uint64 newFees);

    constructor(BitcoinUtils.WorkingScriptSet memory _scripts) AbstractTxSerializerFactory(_scripts) {}

    function setAmlFeesCollector(bytes memory _amlFeesCollectorLockScript) public onlyOwner {
        amlFeesCollectorLockScript = _amlFeesCollectorLockScript;
        emit AMLFeesCollectorUpdate(_amlFeesCollectorLockScript);
    }

    function setAmlFees(uint64 _newFees) public onlyOwner {
        amlFees = _newFees;
        emit AMLFeesUpdate(_newFees);
    }

    function createRefundSerializer(
        TxSerializer.FeeConfig memory _fees,
        bytes32 inputId,
        bytes memory lockingScript
    ) public returns (RefundTxSerializer _serializer) {
        require(msg.sender == allowedCreator, "NAC");
        require(amlFeesCollectorLockScript.length > 1, "NCFG");

        _serializer = new RefundTxSerializer(
            secretsStorage,
            inputsStorage,
            scriptSet,
            _fees,
            msg.sender,
            inputId,
            lockingScript,
            amlFeesCollectorLockScript,
            amlFees
        );

        _serializer.transferOwnership(msg.sender);

        isDeployedSerializer[address(_serializer)] = true;
        emit TransactionSerializerCreated(address(_serializer));
    }
}

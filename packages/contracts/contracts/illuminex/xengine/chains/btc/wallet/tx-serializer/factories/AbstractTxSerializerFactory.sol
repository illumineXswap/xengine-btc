// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import "../TxSerializer.sol";

abstract contract AbstractTxSerializerFactory {
    ITxSecretsStorage public secretsStorage;
    ITxInputsStorage public inputsStorage;

    BitcoinUtils.WorkingScriptSet public scriptSet;

    mapping(address => bool) public isDeployedSerializer;

    address public allowedCreator;
    address public immutable initializer;

    bool public isInitialized;

    event TransactionSerializerCreated(address serializer);

    constructor(BitcoinUtils.WorkingScriptSet memory _scripts) {
        scriptSet = _scripts;
        initializer = msg.sender;
    }

    function init(address _creator) public {
        require(msg.sender == initializer && !isInitialized);
        isInitialized = true;

        allowedCreator = _creator;

        inputsStorage = ITxInputsStorage(_creator);
        secretsStorage = ITxSecretsStorage(_creator);
    }
}

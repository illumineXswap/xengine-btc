// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import "./VaultBitcoinWallet.sol";

contract DummyVaultBitcoinWallet is VaultBitcoinWallet {
    constructor(
        bytes32 seedKey,
        address _prover,
        bytes memory _offchainSigner,
        BitcoinUtils.WorkingScriptSet memory _scriptSet,
        address _queue,
        TxSerializerFactory _serializerFactory,
        RefuelTxSerializerFactory _refuelSerializerFactory,
        RefundTxSerializerFactory _refundSerializerFactory
    ) VaultBitcoinWallet(
        _prover,
        _offchainSigner,
        _scriptSet,
        _queue,
        _serializerFactory,
        _refuelSerializerFactory,
        _refundSerializerFactory
    ) {
        _ringKeys[0] = seedKey;
    }

    function _isTestnet() internal override pure returns (bool) {
        return true;
    }

    function mockDeposit(Transaction memory _tx, bytes memory _data) public {
        _processDeposit(_tx, _data);
    }

    function _random(bytes32 _entropy) internal override pure returns (bytes32) {
        return _entropy;
    }

    function revealBaseKey() public view returns (bytes32) {
        return _ringKeys[0];
    }

    function revealBasePrivateSigningKey(bytes32 inputHash) public view returns (bytes memory) {
        (, bytes memory privKey) = Sapphire.generateSigningKeyPair(
            Sapphire.SigningAlg.Secp256k1PrehashedSha256,
            abi.encodePacked(_secrets[inputs[inputHash].keyImage])
        );

        return privKey;
    }

    function _updateKey(bytes32) internal override {}
}

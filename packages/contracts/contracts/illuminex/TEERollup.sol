// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import "@oasisprotocol/sapphire-contracts/contracts/Sapphire.sol";

abstract contract TEERollup {
    struct PartialComputationsProof {
        bytes computationsResult;
        bytes contractSignature;
    }

    struct WitnessSignature {
        bytes publicKey;
        bytes signature;
    }

    struct FullComputationsProof {
        PartialComputationsProof partialProof;
        WitnessSignature[] witnessSignatures;
    }

    struct ContractSigningKeyPair {
        bytes publicKey;
        bytes privateKey;
    }

    struct WitnessActivation {
        bytes publicKey;
        bool isActive;
    }

    ContractSigningKeyPair private _keyPair;

    mapping(bytes => bool) public witnessPublicKeysSet;
    uint8 public minWitnessSignatures;

    constructor() {
        _updateKeyPair();
    }

    function _updateKeyPair() internal {
        (bytes memory publicKey, bytes memory privateKey) = Sapphire.generateSigningKeyPair(
            Sapphire.SigningAlg.Secp256k1PrehashedKeccak256,
            Sapphire.randomBytes(32, abi.encodePacked(block.number, msg.sender))
        );

        _keyPair.publicKey = publicKey;
        _keyPair.privateKey = privateKey;
    }

    function _setMinWitnessSignatures(uint8 _min) internal {
        minWitnessSignatures = _min;
    }

    function _setWitnessPublicKeys(WitnessActivation[] memory _witnesses) internal {
        for (uint i = 0; i < _witnesses.length; i++) {
            witnessPublicKeysSet[_witnesses[i].publicKey] = _witnesses[i].isActive;
        }
    }

    function getContractSigningPublicKey() public view returns (bytes memory) {
        return _keyPair.publicKey;
    }

    function verifyComputations(FullComputationsProof memory fullProof) public view returns (bool) {
        bool isContractSignatureValid = Sapphire.verify(
            Sapphire.SigningAlg.Secp256k1PrehashedKeccak256,
            _keyPair.publicKey,
            abi.encodePacked(keccak256(fullProof.partialProof.computationsResult)),
            "",
            fullProof.partialProof.contractSignature
        );

        if (!isContractSignatureValid) {
            return false;
        }

        if (fullProof.witnessSignatures.length < minWitnessSignatures) {
            return false;
        }

        bytes[] memory _usedPubKeys = new bytes[](fullProof.witnessSignatures.length);

        for (uint i = 0; i < fullProof.witnessSignatures.length; i++) {
            if (!witnessPublicKeysSet[fullProof.witnessSignatures[i].publicKey]) {
                return false;
            }

            for (uint j = 0; j < _usedPubKeys.length; j++) {
                if (keccak256(_usedPubKeys[j]) == keccak256(fullProof.witnessSignatures[i].publicKey)) {
                    return false;
                }
            }

            _usedPubKeys[i] = fullProof.witnessSignatures[i].publicKey;

            bool isWitnessSignatureValid = Sapphire.verify(
                Sapphire.SigningAlg.Secp256k1PrehashedKeccak256,
                fullProof.witnessSignatures[i].publicKey,
                abi.encodePacked(keccak256(fullProof.partialProof.computationsResult)),
                "",
                fullProof.witnessSignatures[i].signature
            );

            if (!isWitnessSignatureValid) {
                return false;
            }
        }

        return true;
    }

    function compute(bytes calldata input) public view returns (PartialComputationsProof memory) {
        bytes memory result = _compute(input);
        bytes memory signature = Sapphire.sign(
            Sapphire.SigningAlg.Secp256k1PrehashedKeccak256,
            _keyPair.privateKey,
            abi.encodePacked(keccak256(result)),
            ""
        );

        return PartialComputationsProof(result, signature);
    }

    function _compute(bytes calldata input) internal virtual view returns (bytes memory);
}

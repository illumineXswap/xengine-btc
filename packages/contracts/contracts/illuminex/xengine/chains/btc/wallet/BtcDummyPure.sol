// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "@oasisprotocol/sapphire-contracts/contracts/Sapphire.sol";

import "../BitcoinUtils.sol";

contract BtcDummyPure {
    function hash160(bytes memory input) public pure returns (bytes20) {
        return BitcoinUtils.hash160(input);
    }

    function verifySignature(bytes memory pubKey, bytes32 hash, bytes memory signature) public view returns (bool) {
        return Sapphire.verify(
            Sapphire.SigningAlg.Secp256k1PrehashedSha256,
            pubKey,
            abi.encodePacked(hash),
            "",
            signature
        );
    }
}

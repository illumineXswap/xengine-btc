// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import "@oasisprotocol/sapphire-contracts/contracts/Sapphire.sol";

import "./BitcoinAbstractWallet.sol";
import "./scripts/ScriptP2PKH.sol";
import "../../../../RotatingKeys.sol";
import "../BitcoinUtils.sol";

contract DummyBitcoinWallet is BitcoinAbstractWallet, RotatingKeys {
    event DummyDeposit(uint64 value, bytes btcAddress);

    bytes20 public constant TEST_PUBKEY_HASH = bytes20(0x0AB90E7b0D67600985C763E83015ACdeE1101194);

    constructor(address _prover)
    BitcoinAbstractWallet(_prover)
    RotatingKeys(keccak256(abi.encodePacked(block.number)), type(DummyBitcoinWallet).name)
    {
        IScript[] memory _scripts = new IScript[](1);
        _scripts[0] = new ScriptP2PKH();

        _setSupportedScripts(_scripts);
    }

    function _onDeposit(
        bytes4,
        uint64 value,
        bytes memory _btcPubKeyHash,
        bytes memory,
        Transaction memory
    ) internal virtual override returns (bool, bytes32) {
        require(bytes20(_btcPubKeyHash) == TEST_PUBKEY_HASH, "Invalid destination");
        emit DummyDeposit(value, _btcPubKeyHash);

        return (true, bytes32(0));
    }
}

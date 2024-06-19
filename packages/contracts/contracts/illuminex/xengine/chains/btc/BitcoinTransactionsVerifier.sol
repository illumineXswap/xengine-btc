// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import "./interfaces/IBitcoinTransactionsVerifier.sol";
import "./BitcoinMerkleTree.sol";

contract BitcoinTransactionsVerifier is IBitcoinTransactionsVerifier {
    uint32 public constant BTC_TX_VERSION = 1;

    function deserializeTransaction(bytes memory rawTx) public pure returns (BitcoinUtils.BitcoinTransaction memory) {
        return BitcoinUtils.deserializeTransaction(Buffer.BufferIO(rawTx, 0));
    }

    function verifyTransactionRaw(
        bytes memory _tx,
        bytes memory _block,
        BitcoinMerkleTree.ProofNode[] memory merklePath
    ) public pure returns (bool) {
        return verifyTransaction(
            deserializeTransaction(_tx),
            BitcoinUtils.deserializeBlockHeaders(Buffer.BufferIO(_block, 0)),
            merklePath
        );
    }

    function verifyTransaction(
        BitcoinUtils.BitcoinTransaction memory _tx,
        BitcoinUtils.BitcoinBlockHeaders memory _block,
        BitcoinMerkleTree.ProofNode[] memory merklePath
    ) public override pure returns (bool) {
        if (uint32(_tx.version) < BTC_TX_VERSION) {
            return false;
        }

        return BitcoinMerkleTree.verifyMerkleTreeInclusion(
            _tx.hash,
            merklePath,
            _block.hashMerkleRoot
        );
    }
}

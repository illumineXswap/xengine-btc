// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import "../BitcoinUtils.sol";
import "../BitcoinMerkleTree.sol";

interface IBitcoinTransactionsVerifier {
    function verifyTransaction(
        BitcoinUtils.BitcoinTransaction memory tx,
        BitcoinUtils.BitcoinBlockHeaders memory block,
        BitcoinMerkleTree.ProofNode[] memory merklePath
    ) external view returns (bool);
}

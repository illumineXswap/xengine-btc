// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import "../BitcoinUtils.sol";

interface IBitcoinDepositProcessingCallback {
    struct Transaction {
        bytes32 txHash;
        uint256 txOutIndex;
        BitcoinUtils.BitcoinTransactionOutput transaction;
        BitcoinUtils.BitcoinBlockHeaders blockHeaders;
    }

    function processDeposit(
        Transaction memory _tx,
        bytes memory _data
    ) external;
}

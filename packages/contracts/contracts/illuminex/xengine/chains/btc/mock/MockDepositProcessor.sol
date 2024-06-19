// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import "../interfaces/IBitcoinDepositProcessingCallback.sol";

contract MockBitcoinDepositProcessor is IBitcoinDepositProcessingCallback {
    address public immutable prover;

    event TxProofReceived(bytes32 txHash, uint256 txOutIndex);

    constructor(address _prover) {
        prover = _prover;
    }

    function processDeposit(
        Transaction memory _tx,
        bytes memory
    ) public override {
        require(msg.sender == prover);
        emit TxProofReceived(_tx.txHash, _tx.txOutIndex);
    }
}

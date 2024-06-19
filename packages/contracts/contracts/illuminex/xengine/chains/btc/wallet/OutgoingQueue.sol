// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

contract OutgoingQueue {
    struct OutgoingTransfer {
        bytes lockScript;
        uint64 value;
    }

    event OutgoingTransferCommitted(bytes lockingScript, uint64 value);

    address public vaultWallet;
    address public immutable initializer;

    uint256 public bufferedTransfersCheckpoint;
    OutgoingTransfer[] public bufferedTransfers;

    uint256 public maxTransfersPerBatch = 5;
    uint256 public batchingInterval = 15 minutes;
    uint256 public nextBatchTime;

    constructor() {
        initializer = msg.sender;
    }

    function init(address _vaultWallet) public {
        require(vaultWallet == address(0) && msg.sender == initializer);
        vaultWallet = _vaultWallet;
    }

    function push(OutgoingTransfer memory _transfer) public {
        require(msg.sender == vaultWallet);

        bufferedTransfers.push(_transfer);
        emit OutgoingTransferCommitted(_transfer.lockScript, _transfer.value);
    }

    function popBufferedTransfersToBatch() public returns (
        OutgoingTransfer[] memory transfers,
        uint256 sliceIndex
    ) {
        require(msg.sender == vaultWallet);

        (OutgoingQueue.OutgoingTransfer[] memory _transfers, uint256 _sliceIndex) = getBufferedTransfersToBatch();
        require(_transfers.length > 0, "Not enough transfers");

        nextBatchTime = block.timestamp + batchingInterval;
        bufferedTransfersCheckpoint += _sliceIndex;

        return (_transfers, _sliceIndex);
    }

    function getBufferedTransfersToBatch() public view returns (
        OutgoingTransfer[] memory _transfers,
        uint256 _sliceIndex
    ) {
        if (nextBatchTime > block.timestamp) {
            return (_transfers, 0);
        }

        uint _size = bufferedTransfers.length - bufferedTransfersCheckpoint;
        uint _take = _size > maxTransfersPerBatch ? maxTransfersPerBatch : _size;

        OutgoingTransfer[] memory _slice = new OutgoingTransfer[](_take);

        for (uint i = bufferedTransfersCheckpoint; i < bufferedTransfersCheckpoint + _take; i++) {
            _slice[i - bufferedTransfersCheckpoint] = bufferedTransfers[i];
        }

        _transfers = _slice;
        _sliceIndex = _take;
    }
}

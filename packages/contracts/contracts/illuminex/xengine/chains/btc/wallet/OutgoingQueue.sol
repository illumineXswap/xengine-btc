// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

contract OutgoingQueue {
    struct OutgoingTransfer {
        bytes lockScript;
        uint64 value;
        bytes32 id;
    }

    struct TransfersSlice {
        uint256 start;
        uint256 end;
    }

    event OutgoingTransferCommitted(bytes32 indexed id, bytes lockingScript, uint64 value);
    event OutgoingTransferPopped(bytes32 indexed id);

    address public vaultWallet;
    address public immutable initializer;

    uint256 public bufferedTransfersCheckpoint;
    OutgoingTransfer[] public bufferedTransfers;

    mapping(bytes32 => bool) public sliceExists;
    mapping(bytes32 => TransfersSlice) public slices;
    mapping(address => bool) public walkers;

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
        emit OutgoingTransferCommitted(_transfer.id, _transfer.lockScript, _transfer.value);
    }

    function registerWalker(address _walker) public {
        require(msg.sender == vaultWallet);
        walkers[_walker] = true;
    }

    function walk(bytes32 sliceIndex, uint256 _from, uint256 _to) public returns (OutgoingTransfer[] memory) {
        require(walkers[msg.sender], "NAW");
        require(sliceExists[sliceIndex], "SAE");

        TransfersSlice memory _slice = slices[sliceIndex];
        require(_to <= _slice.end, "INVS");

        OutgoingTransfer[] memory _transfers = new OutgoingTransfer[](_to - _from);

        for (uint i = _from; i < _to; i++) {
            _transfers[i - _from] = bufferedTransfers[_slice.start + i];
            emit OutgoingTransferPopped(_transfers[i - _from].id);
        }

        return _transfers;
    }

    function popBufferedTransfersToBatch() public returns (bytes32 sliceIndex) {
        require(msg.sender == vaultWallet);
        require(hasEnoughBufferedTransfersToBatch(), "NET");

        uint _size = bufferedTransfers.length - bufferedTransfersCheckpoint;
        uint _take = _size > maxTransfersPerBatch ? maxTransfersPerBatch : _size;

        uint _from = bufferedTransfersCheckpoint;
        uint _to = bufferedTransfersCheckpoint + _take;

        bytes32 _sliceIndex = keccak256(abi.encodePacked(_from, _to));

        slices[_sliceIndex] = TransfersSlice(_from, _to);
        sliceExists[_sliceIndex] = true;

        nextBatchTime = block.timestamp + batchingInterval;
        bufferedTransfersCheckpoint += _take;

        return _sliceIndex;
    }

    function hasEnoughBufferedTransfersToBatch() public view returns (bool) {
        if ((bufferedTransfers.length - bufferedTransfersCheckpoint) >= maxTransfersPerBatch) {
            return true;
        }

        if (nextBatchTime > block.timestamp) {
            return false;
        }

        return (bufferedTransfers.length - bufferedTransfersCheckpoint) > 0;
    }
}

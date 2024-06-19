// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/access/Ownable.sol";

import "../../../TEERollup.sol";
import "./BitcoinUtils.sol";
import "./interfaces/IBitcoinTransactionsVerifier.sol";
import "./interfaces/IBitcoinDepositProcessingCallback.sol";
import "./interfaces/IBitcoinNetwork.sol";

contract BitcoinProver is Ownable, TEERollup, IBitcoinNetwork {
    using Buffer for Buffer.BufferIO;

    enum ProvingAction {
        BlockChunk,
        Transaction,
        AnchorBlock,
        BlockChunkRollup
    }

    struct AnchorBlock {
        uint256 currentDifficultyTarget;
        uint256 previousDifficultyTarget;
        uint256 anchorBlockNumber;
        bytes32 anchorBlockHash;
        uint256 anchorBlockTimestamp;
    }

    struct BlockChunk {
        bytes32 prevChunkProofHash;
        int16 startBlockNumberDelta;
        bytes32 startBlockHash;
        uint8 chunkSize;
        bytes32 endBlockHash;
        uint256 endChunkTarget;
        uint256 virtualEpochIndex;
    }

    struct BlockChunkRollup {
        int16 startBlockNumberDelta;
        bytes32 startBlockHash;
        int16 endBlockNumberDelta;
        bytes32 endBlockHash;
    }

    event AnchorBlockUpdate(
        bytes32 indexed newBlockhash,
        bytes32 indexed prevBlockHash
    );

    event MinConfirmationsUpdate(uint8 newMinConfirmations, uint8 oldMinConfirmations);
    event WitnessPublicKeyToggle(bytes pubKey);

    AnchorBlock[] public anchorBlocks;

    uint8 public minConfirmations = 5;

    int16 public constant RETARGET_DELTA = 2016;

    mapping(uint256 => uint256) public anchorBlockNumberToIndex;
    mapping(bytes32 => uint256) public anchorBlockHashToIndex;

    mapping(bytes32 => bool) public anchorBlockExists;

    IBitcoinTransactionsVerifier public immutable txVerifier;
    ChainParams private _chainParams;

    constructor(AnchorBlock memory seedAnchorBlock, address _verifier, ChainParams memory _params) {
        txVerifier = IBitcoinTransactionsVerifier(_verifier);
        _insertAnchorBlock(seedAnchorBlock);
        _chainParams = _params;
    }

    function chainParams() public override view returns (ChainParams memory) {
        return _chainParams;
    }

    function setMinConfirmations(uint8 _newConfirmations) public onlyOwner {
        emit MinConfirmationsUpdate(_newConfirmations, minConfirmations);
        minConfirmations = _newConfirmations;
    }

    function toggleWitnessPublicKey(bytes memory pubKey) public onlyOwner {
        emit WitnessPublicKeyToggle(pubKey);
        witnessPublicKeysSet[pubKey] = !witnessPublicKeysSet[pubKey];
    }

    function setMinWitnessConfirmations(uint8 _min) public onlyOwner {
        _setMinWitnessSignatures(_min);
    }

    function _insertAnchorBlock(AnchorBlock memory anchorBlock) private {
        require(!anchorBlockExists[anchorBlock.anchorBlockHash], "Anchor block already exists");

        if (anchorBlocks.length > 0) {
            emit AnchorBlockUpdate(anchorBlock.anchorBlockHash, anchorBlocks[anchorBlocks.length - 1].anchorBlockHash);
        }

        uint256 index = anchorBlocks.length;
        anchorBlocks.push(anchorBlock);

        anchorBlockHashToIndex[anchorBlock.anchorBlockHash] = index;
        anchorBlockNumberToIndex[anchorBlock.anchorBlockNumber] = index;
        anchorBlockExists[anchorBlock.anchorBlockHash] = true;
    }

    function deserializeBlockHeaders(bytes memory blockHeaders) public pure returns (BitcoinUtils.BitcoinBlockHeaders[] memory) {
        require(blockHeaders.length % 80 == 0, "Invalid blockheaders size");

        uint blocksCount = blockHeaders.length / 80;

        Buffer.BufferIO memory _blockHeadersBuffer = Buffer.BufferIO(blockHeaders, 0);
        BitcoinUtils.BitcoinBlockHeaders[] memory _result = new BitcoinUtils.BitcoinBlockHeaders[](blocksCount);

        for (uint i = 0; i < blocksCount; i++) {
            bytes memory headersSerialized = _blockHeadersBuffer.read(80);

            Buffer.BufferIO memory _buffer = Buffer.BufferIO(headersSerialized, 0);
            _result[i] = BitcoinUtils.deserializeBlockHeaders(_buffer);
        }

        return _result;
    }

    function getBlockChunkProof(TEERollup.FullComputationsProof memory proof) public view returns (BlockChunk memory) {
        require(verifyComputations(proof), "Invalid proof");

        (uint8 actionCode, BlockChunk memory chunk) = abi.decode(proof.partialProof.computationsResult, (uint8, BlockChunk));
        require(actionCode == uint8(ProvingAction.BlockChunk), "Invalid action code");

        return chunk;
    }

    function getBlockChunkRollupProof(TEERollup.FullComputationsProof memory proof) public view returns (BlockChunkRollup memory) {
        require(verifyComputations(proof), "Invalid proof");

        (uint8 actionCode, BlockChunkRollup memory chunk) = abi.decode(proof.partialProof.computationsResult, (uint8, BlockChunkRollup));
        require(actionCode == uint8(ProvingAction.BlockChunkRollup), "Invalid action code");

        return chunk;
    }

    function proveBlockChunk(
        TEERollup.FullComputationsProof memory previousProof,
        bytes memory blockHeaders,
        uint256 epochIndex
    ) public view returns (BlockChunk memory) {
        BitcoinUtils.BitcoinBlockHeaders[] memory blocks = deserializeBlockHeaders(blockHeaders);
        AnchorBlock memory currentAnchorBlock = anchorBlocks[epochIndex];

        int16 deltaCursor = 1;

        bytes32 prevHash = currentAnchorBlock.anchorBlockHash;
        uint256 currentTarget = currentAnchorBlock.currentDifficultyTarget;
        bytes32 prevChunkHash = bytes32(0);

        if (previousProof.partialProof.contractSignature.length > 0) {
            BlockChunk memory prevChunk = getBlockChunkProof(previousProof);
            require(prevChunk.virtualEpochIndex == epochIndex, "Invalid epoch index");

            prevHash = prevChunk.endBlockHash;
            prevChunkHash = keccak256(abi.encode(prevChunk));
            deltaCursor = prevChunk.startBlockNumberDelta + int16(uint16(prevChunk.chunkSize));
            currentTarget = prevChunk.endChunkTarget;
        }

        require(blocks.length <= type(uint8).max && blocks.length > 0, "Blocks chunk size is out of bounds");

        for (uint i = 0; i < blocks.length; i++) {
            BitcoinUtils.BitcoinBlockHeaders memory _block = blocks[i];
            require(prevHash == _block.hashPrevBlock, "Invalid seq");
            prevHash = BitcoinUtils.hashBlock(_block);

            bool shouldRetarget = _chainParams.isTestnet
                ? (BitcoinUtils.getDifficultyTarget(_block.bits) != currentTarget)
                : ((deltaCursor + int16(uint16(i))) % RETARGET_DELTA == 0);

            if (shouldRetarget) {
                uint256 newTarget = BitcoinUtils.getDifficultyTarget(_block.bits);
                uint256 prevTarget = currentTarget;

                if (!_chainParams.isTestnet) {
                    require(newTarget > (prevTarget >> 2) && newTarget < (prevTarget << 2), "Invalid retarget");
                }

                currentTarget = newTarget;
            }

            require(BitcoinUtils.getDifficultyTarget(_block.bits) == currentTarget, "Invalid difficulty epoch");
            require(uint256(prevHash) < currentTarget, "Invalid block hash");
        }

        return BlockChunk({
            startBlockNumberDelta: deltaCursor,
            chunkSize: uint8(blocks.length),
            prevChunkProofHash: prevChunkHash,
            startBlockHash: BitcoinUtils.hashBlock(blocks[0]),
            endBlockHash: BitcoinUtils.hashBlock(blocks[blocks.length - 1]),
            endChunkTarget: currentTarget,
            virtualEpochIndex: epochIndex
        });
    }

    function rollupBlockChunkProofs(TEERollup.FullComputationsProof[] memory proofs) public view returns (BlockChunkRollup memory) {
        require(proofs.length > 0, "Too few proofs");

        bytes32 prevChunkHash = bytes32(0);

        BlockChunk[] memory chunks = new BlockChunk[](proofs.length);

        uint256 epochIndex = 0;
        for (uint i = 0; i < proofs.length; i++) {
            BlockChunk memory chunk = getBlockChunkProof(proofs[i]);
            if (i == 0) {
                epochIndex = chunk.virtualEpochIndex;
            }

            require(chunk.prevChunkProofHash == prevChunkHash, "Invalid block chunks seq");
            require(epochIndex == chunk.virtualEpochIndex, "Invalid chunk virtual epoch index");

            prevChunkHash = keccak256(abi.encode(chunk));

            chunks[i] = chunk;
        }

        BlockChunk memory lastBlockChunk = chunks[chunks.length - 1];

        return BlockChunkRollup(
            chunks[0].startBlockNumberDelta,
            chunks[0].startBlockHash,
            lastBlockChunk.startBlockNumberDelta + int16(uint16(lastBlockChunk.chunkSize)),
            lastBlockChunk.endBlockHash
        );
    }

    function proveTransaction(
        bytes memory _transaction,
        BitcoinMerkleTree.ProofNode[] memory _transactionMerklePath,
        uint256 _txOutIndex,
        bytes memory _blockHeader,
        TEERollup.FullComputationsProof memory confirmationsChunkProof
    ) public view returns (IBitcoinDepositProcessingCallback.Transaction memory) {
        BitcoinUtils.BitcoinTransaction memory _tx = BitcoinUtils.deserializeTransaction(Buffer.BufferIO(_transaction, 0));
        BitcoinUtils.BitcoinBlockHeaders memory _block = BitcoinUtils.deserializeBlockHeaders(Buffer.BufferIO(_blockHeader, 0));

        BlockChunk memory confirmations = getBlockChunkProof(confirmationsChunkProof);
        require(confirmations.virtualEpochIndex <= getLastAcknowledgedAnchorBlockIndex(), "Invalid epoch");
        require(confirmations.chunkSize >= minConfirmations + 1, "Too few confirmations blocks");
        require(confirmations.startBlockHash == BitcoinUtils.hashBlock(_block), "Invalid confirmations sub-chain");

        require(txVerifier.verifyTransaction(_tx, _block, _transactionMerklePath), "Tx is not included");
        require(_tx.outputs.length - 1 >= _txOutIndex, "Invalid txOutIndex");

        return IBitcoinDepositProcessingCallback.Transaction(_tx.hash, _txOutIndex, _tx.outputs[_txOutIndex], _block);
    }

    function ackTransaction(
        TEERollup.FullComputationsProof memory txProof,
        IBitcoinDepositProcessingCallback callback,
        bytes memory _data
    ) public {
        require(verifyComputations(txProof), "Invalid proof");

        (uint8 actionCode, IBitcoinDepositProcessingCallback.Transaction memory _tx) = abi.decode(
            txProof.partialProof.computationsResult,
            (uint8, IBitcoinDepositProcessingCallback.Transaction)
        );

        require(actionCode == uint8(ProvingAction.Transaction), "Invalid action code");
        callback.processDeposit(_tx, _data);
    }

    function getLastAcknowledgedAnchorBlock() public view returns (AnchorBlock memory) {
        return anchorBlocks[anchorBlocks.length - 1];
    }

    function getLastAcknowledgedAnchorBlockIndex() public view returns (uint256) {
        return anchorBlocks.length - 1;
    }

    function proveAnchorBlock(
        TEERollup.FullComputationsProof memory epochProof,
        TEERollup.FullComputationsProof memory confirmationsChunkProof,
        bytes memory firstEpochBlockHeaders,
        bytes memory newAnchorBlockHeaders
    ) public view returns (AnchorBlock memory) {
        AnchorBlock memory currentAnchorBlock = getLastAcknowledgedAnchorBlock();

        BlockChunkRollup memory epoch = getBlockChunkRollupProof(epochProof);
        BlockChunk memory confirmations = getBlockChunkProof(confirmationsChunkProof);

        BitcoinUtils.BitcoinBlockHeaders memory firstBlockInEpoch = BitcoinUtils.deserializeBlockHeaders(
            Buffer.BufferIO(firstEpochBlockHeaders, 0)
        );
        BitcoinUtils.BitcoinBlockHeaders memory newAnchorBlock = BitcoinUtils.deserializeBlockHeaders(
            Buffer.BufferIO(newAnchorBlockHeaders, 0)
        );

        bytes32 newAnchorBlockHash = BitcoinUtils.hashBlock(newAnchorBlock);

        require(epoch.startBlockNumberDelta == 1 && epoch.endBlockNumberDelta == RETARGET_DELTA, "Invalid epoch range");
        require(
            epoch.startBlockHash == BitcoinUtils.hashBlock(firstBlockInEpoch)
            &&
            firstBlockInEpoch.hashPrevBlock == currentAnchorBlock.anchorBlockHash,
            "Invalid epoch first block")
        ;
        require(epoch.endBlockHash == newAnchorBlock.hashPrevBlock, "Invalid epoch last block");

        require(confirmations.chunkSize >= minConfirmations + 1, "Too few confirmations blocks");
        require(confirmations.startBlockHash == newAnchorBlockHash, "Invalid confirmations sub-chain");

        return AnchorBlock(
            BitcoinUtils.getDifficultyTarget(newAnchorBlock.bits),
            currentAnchorBlock.currentDifficultyTarget,
            currentAnchorBlock.anchorBlockNumber + uint256(int256(RETARGET_DELTA)),
            newAnchorBlockHash,
            newAnchorBlock.time
        );
    }

    function ackAnchorBlock(TEERollup.FullComputationsProof calldata newAnchorProof) public {
        require(verifyComputations(newAnchorProof), "Invalid proof");

        (uint8 actionCode, AnchorBlock memory newAnchorBlock) = abi.decode(
            newAnchorProof.partialProof.computationsResult,
            (uint8, AnchorBlock)
        );
        require(actionCode == uint8(ProvingAction.AnchorBlock), "Invalid action code");

        AnchorBlock memory currentAnchorBlock = getLastAcknowledgedAnchorBlock();
        require(
            newAnchorBlock.anchorBlockNumber - currentAnchorBlock.anchorBlockNumber == uint256(int256(RETARGET_DELTA)),
            "Invalid anchor block"
        );

        _insertAnchorBlock(newAnchorBlock);
    }

    function _compute(bytes calldata input) internal virtual override view returns (bytes memory) {
        (uint8 actionCode, bytes memory actionData) = abi.decode(input, (uint8, bytes));
        ProvingAction action = ProvingAction(actionCode);

        if (action == ProvingAction.BlockChunk) {
            (TEERollup.FullComputationsProof memory _previousProof, bytes memory _headers, uint256 _epochIndex) = abi.decode(
                actionData,
                (TEERollup.FullComputationsProof, bytes, uint256)
            );

            BlockChunk memory chunk = proveBlockChunk(_previousProof, _headers, _epochIndex);
            return abi.encode(uint8(ProvingAction.BlockChunk), chunk);
        } else if (action == ProvingAction.AnchorBlock) {
            (
                TEERollup.FullComputationsProof memory epochProof,
                TEERollup.FullComputationsProof memory confirmationsProof,
                bytes memory firstBlockInEpoch,
                bytes memory newAnchorBlockHeaders
            ) = abi.decode(
                actionData,
                (TEERollup.FullComputationsProof, TEERollup.FullComputationsProof, bytes, bytes)
            );

            AnchorBlock memory newAnchorBlock = proveAnchorBlock(
                epochProof,
                confirmationsProof,
                firstBlockInEpoch,
                newAnchorBlockHeaders
            );

            return abi.encode(uint8(ProvingAction.AnchorBlock), newAnchorBlock);
        } else if (action == ProvingAction.Transaction) {
            (
                bytes memory _transaction,
                BitcoinMerkleTree.ProofNode[] memory _transactionMerklePath,
                uint256 _txOutIndex,
                bytes memory _blockHeader,
                TEERollup.FullComputationsProof memory confirmationsChunkProof
            ) = abi.decode(
                actionData,
                (bytes, BitcoinMerkleTree.ProofNode[], uint256, bytes, TEERollup.FullComputationsProof)
            );

            IBitcoinDepositProcessingCallback.Transaction memory _tx = proveTransaction(
                _transaction,
                _transactionMerklePath,
                _txOutIndex,
                _blockHeader,
                confirmationsChunkProof
            );

            return abi.encode(uint8(ProvingAction.Transaction), _tx);
        } else if (action == ProvingAction.BlockChunkRollup) {
            (TEERollup.FullComputationsProof[] memory proofChain) = abi.decode(
                actionData,
                (TEERollup.FullComputationsProof[])
            );

            BlockChunkRollup memory rollup = rollupBlockChunkProofs(proofChain);
            return abi.encode(uint8(ProvingAction.BlockChunkRollup), rollup);
        }

        revert("Invalid proving action");
    }
}

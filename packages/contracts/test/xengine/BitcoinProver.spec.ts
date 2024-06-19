import { expect } from "chai";
import { ethers } from "hardhat";
import { BitcoinBlock, BitcoinClient } from "../../utils/bitcoin-rpc";
import { readFileSync } from "fs";
import { BitcoinProver } from "../../typechain-types";
import { MerkleTree } from "merkletreejs";
import { createHash } from "node:crypto";
// @ts-ignore
import BlockChunkRollupStruct = BitcoinProver.BlockChunkRollupStruct;

type BlockChunkProof = {
  readonly prevChunkProofHash: string;
  readonly startBlockNumberDelta: number;
  readonly startBlockHash: string;
  readonly chunkSize: number;
  readonly endBlockHash: string;
};

type FullComputationsProof = {
  partialProof: {
    computationsResult: string;
    contractSignature: string;
  };
  witnessSignatures: {
    publicKey: string;
    signature: string;
  }[];
};

const EMPTY_PAST_CHUNK_PROOF = {
  partialProof: {
    contractSignature: "0x",
    computationsResult: "0x",
  },
  witnessSignatures: [],
};

const BLOCK_CHUNK_ROLLUP_TYPE = {
  type: "tuple",
  name: "BlockChunkRollup",
  baseType: "tuple",
  components: [
    {
      type: "int16",
      baseType: "int16",
      name: "startBlockNumberDelta",
    },
    {
      type: "bytes32",
      baseType: "bytes32",
      name: "startBlockHash",
    },
    {
      type: "int16",
      baseType: "int16",
      name: "endBlockNumberDelta",
    },
    {
      type: "bytes32",
      baseType: "bytes32",
      name: "endBlockHash",
    },
  ],
};

const MERKLE_PROOFS_NODES_TYPE = {
  type: "tuple[]",
  name: "ProofNode",
  baseType: "tuple[]",
  components: [
    {
      type: "bool",
      baseType: "bool",
      name: "isLeft",
    },
    {
      type: "bytes32",
      baseType: "bytes32",
      name: "data",
    },
  ],
};

const ANCHOR_BLOCK_TYPE = {
  type: "tuple",
  name: "AnchorBlock",
  baseType: "tuple",
  components: [
    {
      type: "uint256",
      baseType: "uint256",
      name: "currentDifficultyTarget",
    },
    {
      type: "uint256",
      baseType: "uint256",
      name: "previousDifficultyTarget",
    },
    {
      type: "uint256",
      baseType: "uint256",
      name: "anchorBlockNumber",
    },
    {
      type: "bytes32",
      baseType: "bytes32",
      name: "anchorBlockHash",
    },
    {
      type: "uint256",
      baseType: "uint256",
      name: "anchorBlockTimestamp",
    },
  ],
};

const BLOCK_CHUNK_TYPE = {
  type: "tuple",
  name: "BlockChunk",
  baseType: "tuple",
  components: [
    {
      type: "bytes32",
      baseType: "bytes32",
      name: "prevChunkProofHash",
    },
    {
      type: "int16",
      baseType: "int16",
      name: "startBlockNumberDelta",
    },
    {
      type: "bytes32",
      baseType: "bytes32",
      name: "startBlockHash",
    },
    {
      type: "uint8",
      baseType: "uint8",
      name: "chunkSize",
    },
    {
      type: "bytes32",
      baseType: "bytes32",
      name: "endBlockHash",
    },
    {
      type: "uint256",
      baseType: "uint256",
      name: "endChunkTarget",
    },
    {
      type: "uint256",
      baseType: "uint256",
      name: "virtualEpochIndex",
    },
  ],
};

const PARTIAL_COMPUTATIONS_PROOF_TYPE = {
  type: "tuple",
  name: "partialProof",
  baseType: "tuple",
  components: [
    {
      type: "bytes",
      baseType: "bytes",
      name: "computationsResult",
    },
    {
      type: "bytes",
      baseType: "bytes",
      name: "contractSignature",
    },
  ],
};

const FULL_COMPUTATIONS_PROOF_TYPE = {
  type: "tuple",
  baseType: "tuple",
  name: "FullComputationsProof",
  components: [
    PARTIAL_COMPUTATIONS_PROOF_TYPE,
    {
      type: "tuple[]",
      name: "witnessSignatures",
      baseType: "tuple",
      components: [
        {
          type: "bytes",
          baseType: "bytes",
          name: "publicKey",
        },
        {
          type: "bytes",
          baseType: "bytes",
          name: "signature",
        },
      ],
    },
  ],
};

enum BitcoinNetworkId {
  Mainnet = "0x00",
  Testnet = "0x6f",
}

describe("xEngine: Bitcoin Prover", () => {
  const bitcoinClient = new BitcoinClient(
    process.env.BITCOIN_MAINNET_RPC_CLIENT!,
  );

  const loadBlockRange = async (
    blockFrom: number,
    blockTo: number,
  ): Promise<string[]> => {
    const chunks: Promise<string>[] = [];
    for (let i = blockFrom; i < blockTo; i++) {
      chunks.push(
        new Promise(async (resolve) => {
          resolve(
            await bitcoinClient.getRawBlockHeader(
              (await bitcoinClient.getBlockByNumber(i)).hash,
            ),
          );
        }),
      );
    }

    return Promise.all(chunks);
  };

  const loadProverFixture = async (networkId = BitcoinNetworkId.Mainnet) => {
    const SEED_ANCHOR_BLOCK_HASH =
      "00000000000000000001aa9cefb939e2932546e5dd378cb0d07a77ec60a3d06f";

    const anchorBlock = await bitcoinClient.getBlock(SEED_ANCHOR_BLOCK_HASH);
    const previousAnchorBlockHash = await bitcoinClient.getBlockHash(
      anchorBlock.height - 2016,
    );
    const previousAnchorBlock = await bitcoinClient.getBlock(
      previousAnchorBlockHash,
    );

    const BitcoinUtils = await ethers.getContractFactory("BitcoinUtils");
    const bitcoinUtils = await BitcoinUtils.deploy();
    await bitcoinUtils.waitForDeployment();

    const BitcoinTransactionsVerifierFactory = await ethers.getContractFactory(
      "BitcoinTransactionsVerifier",
      {
        libraries: {
          BitcoinUtils: await bitcoinUtils.getAddress(),
        },
      },
    );

    const bitcoinTransactionsVerifier =
      await BitcoinTransactionsVerifierFactory.deploy();

    const BitcoinProverFactory = await ethers.getContractFactory(
      "BitcoinProver",
      {
        libraries: {
          BitcoinUtils: await bitcoinUtils.getAddress(),
        },
      },
    );

    const bitcoinProver = await BitcoinProverFactory.deploy(
      {
        currentDifficultyTarget: bitcoinClient.getDifficultyTarget(
          anchorBlock.bits,
        ),
        previousDifficultyTarget: bitcoinClient.getDifficultyTarget(
          previousAnchorBlock.bits,
        ),
        anchorBlockHash: `0x${anchorBlock.hash}`,
        anchorBlockNumber: anchorBlock.height,
        anchorBlockTimestamp: anchorBlock.time,
      },
      await bitcoinTransactionsVerifier.getAddress(),
      {
        networkID: networkId,
        isTestnet: networkId === BitcoinNetworkId.Testnet,
      },
    );

    const computeBlockChunkProof = async (
      previousProof: FullComputationsProof,
      blockHeaders: string,
    ): Promise<{
      partialSignature: string;
      rawResult: string;
      blockChunkProof: BlockChunkProof;
    }> => {
      const coder = ethers.AbiCoder.defaultAbiCoder();

      const rollup0Partialproof = await bitcoinProver.compute(
        coder.encode(
          ["uint8", "bytes"],
          [
            0, // ProvingAction.BlockChunk,
            coder.encode(
              // @ts-ignore
              [FULL_COMPUTATIONS_PROOF_TYPE, "bytes", "uint256"],
              [previousProof, blockHeaders, 0n],
            ),
          ],
        ),
      );

      const [rollup0SerializedEnvelope, rollup0PartialSignature] =
        rollup0Partialproof;

      const [, rollup0Result] = coder.decode(
        // @ts-ignore
        ["uint8", BLOCK_CHUNK_TYPE],
        rollup0SerializedEnvelope,
      );

      return {
        partialSignature: rollup0PartialSignature,
        rawResult: rollup0SerializedEnvelope,
        blockChunkProof: rollup0Result,
      };
    };

    return {
      bitcoinProver,
      computeBlockChunkProof,
      bitcoinTransactionsVerifier,
      bitcoinUtils,
    };
  };

  const loadChunksFixture = async (
    blocksToProve: number,
    chunkSize: number,
    blocksHeadersSerialized?: string,
  ) => {
    const fixture = await loadProverFixture();

    const anchorBlock =
      await fixture.bitcoinProver.getLastAcknowledgedAnchorBlock();
    const chunksToProve: string[][] = [];

    const chunksAmount = Math.floor(blocksToProve / chunkSize);
    const leftOver = blocksToProve % chunkSize;

    const resolveBlockHeaders = async (height: number): Promise<string> => {
      if (blocksHeadersSerialized) {
        const dataCursor = height - Number(anchorBlock.anchorBlockNumber) - 1;
        const blocksBuffer = Buffer.from(blocksHeadersSerialized, "hex");

        return blocksBuffer
          .subarray(dataCursor * 80, dataCursor * 80 + 80)
          .toString("hex");
      }

      return new Promise(async (resolve) => {
        resolve(
          await bitcoinClient.getRawBlockHeader(
            (await bitcoinClient.getBlockByNumber(height)).hash,
          ),
        );
      });
    };

    for (let c = 0; c < chunksAmount; c++) {
      const chunk: Promise<string>[] = [];
      for (
        let i = Number(anchorBlock.anchorBlockNumber) + c * chunkSize + 1;
        i <
        Number(anchorBlock.anchorBlockNumber) + c * chunkSize + chunkSize + 1;
        i++
      ) {
        chunk.push(resolveBlockHeaders(i));
      }

      chunksToProve.push(await Promise.all(chunk));
    }

    const leftoverChunk: Promise<string>[] = [];
    const lastC = chunksAmount - 1;

    const lastCheckpoint =
      Number(anchorBlock.anchorBlockNumber) + lastC * chunkSize + chunkSize + 1;

    for (let i = lastCheckpoint; i < lastCheckpoint + leftOver; i++) {
      leftoverChunk.push(resolveBlockHeaders(i));
    }

    chunksToProve.push(await Promise.all(leftoverChunk));

    return { ...fixture, chunksToProve };
  };

  const loadDifficultyEpochFixture = async (blocksToProve = 2015) => {
    const coder = ethers.AbiCoder.defaultAbiCoder();
    const blocksFile = readFileSync(`./BTC-blocks-828576-830593.txt`, "utf-8");
    const bitcoinFixture = await loadChunksFixture(
      blocksToProve,
      200,
      blocksFile,
    );

    let prevRollup = EMPTY_PAST_CHUNK_PROOF;

    const chunksRollups: (typeof EMPTY_PAST_CHUNK_PROOF)[] = [];
    for (const chunk of bitcoinFixture.chunksToProve) {
      const chunkRollup = await bitcoinFixture.computeBlockChunkProof(
        prevRollup,
        `0x${chunk.join("")}`,
      );

      prevRollup = {
        partialProof: {
          contractSignature: chunkRollup.partialSignature,
          computationsResult: chunkRollup.rawResult,
        },
        witnessSignatures: [],
      };

      chunksRollups.push(prevRollup);
    }

    const rollupFinalPartialproof = await bitcoinFixture.bitcoinProver.compute(
      coder.encode(
        ["uint8", "bytes"],
        [
          3, // ProvingAction.BlockChunkRollup,
          coder.encode(
            // @ts-ignore
            [{ ...FULL_COMPUTATIONS_PROOF_TYPE, type: "tuple[]" }],
            [chunksRollups],
          ),
        ],
      ),
    );

    const [rollupFinalSerializedEnvelope, rollup0PartialSignature] =
      rollupFinalPartialproof;

    const [, fullRollup] = coder.decode(
      // @ts-ignore
      ["uint8", BLOCK_CHUNK_ROLLUP_TYPE],
      rollupFinalSerializedEnvelope,
    );

    return {
      ...bitcoinFixture,
      partialSignature: rollup0PartialSignature,
      rawResult: rollupFinalSerializedEnvelope,
      fullRollup,
    };
  };

  const loadAnchorBlockConfirmations = async (confirmationsNo: number) => {
    const {
      bitcoinProver,
      fullRollup,
      partialSignature,
      rawResult,
      computeBlockChunkProof,
      chunksToProve,
    } = await loadDifficultyEpochFixture();
    const typedRollup = fullRollup as unknown as BlockChunkRollupStruct;

    let prevRollup = EMPTY_PAST_CHUNK_PROOF;

    const previousAnchorBlock =
      await bitcoinProver.getLastAcknowledgedAnchorBlock();

    const confirmations = await loadBlockRange(
      Number(
        previousAnchorBlock.anchorBlockNumber +
          BigInt(typedRollup.endBlockNumberDelta),
      ),
      Number(
        previousAnchorBlock.anchorBlockNumber +
          BigInt(typedRollup.endBlockNumberDelta) +
          BigInt(confirmationsNo),
      ),
    );

    chunksToProve.push(confirmations);

    const chunksRollups: (typeof EMPTY_PAST_CHUNK_PROOF)[] = [];
    for (const chunk of chunksToProve) {
      const chunkRollup = await computeBlockChunkProof(
        prevRollup,
        `0x${chunk.join("")}`,
      );

      prevRollup = {
        partialProof: {
          contractSignature: chunkRollup.partialSignature,
          computationsResult: chunkRollup.rawResult,
        },
        witnessSignatures: [],
      };

      chunksRollups.push(prevRollup);
    }

    const confirmationsProof = chunksRollups[chunksRollups.length - 1];

    return {
      chunksToProve,
      bitcoinProver,
      confirmationsProof,
      typedRollup,
      epochPartialSignature: partialSignature,
      epochRaw: rawResult,
    };
  };

  it("invalid block headers size", async () => {
    const { bitcoinProver } = await loadProverFixture();

    await expect(
      bitcoinProver.deserializeBlockHeaders(ethers.randomBytes(10)),
    ).to.revertedWith("Invalid blockheaders size");
  });

  it("successful blockheader deserialization", async () => {
    const { bitcoinProver } = await loadProverFixture();

    const TEST_BLOCK_NUMBER = 800_000;
    const TEST_BLOCKS_TO_PICK = 1;

    const blocksSerialized: string[] = [];
    for (
      let i = TEST_BLOCK_NUMBER;
      i < TEST_BLOCK_NUMBER + TEST_BLOCKS_TO_PICK;
      i++
    ) {
      blocksSerialized.push(
        await bitcoinClient.getRawBlockHeader(
          await bitcoinClient.getBlockHash(i),
        ),
      );
    }

    const deserializedBlocks = await bitcoinProver.deserializeBlockHeaders(
      `0x${blocksSerialized.join("")}`,
    );

    const blocksDatas: BitcoinBlock[] = [];
    for (
      let i = TEST_BLOCK_NUMBER;
      i < TEST_BLOCK_NUMBER + TEST_BLOCKS_TO_PICK;
      i++
    ) {
      blocksDatas.push(
        await bitcoinClient.getBlock(await bitcoinClient.getBlockHash(i)),
      );
    }

    expect(
      deserializedBlocks.map((block) => ({
        version: block.version,
        prevHash: block.hashPrevBlock,
        merkleRoot: block.hashMerkleRoot,
        timestamp: Number(block.time),
        bits: block.bits,
        nonce: Number(block.nonce),
      })),
    ).deep.equal(
      blocksDatas.map((block) => ({
        version: `0x${Number(block.version).toString(16)}`,
        prevHash: `0x${block.previousblockhash}`,
        merkleRoot: `0x${block.merkleroot}`,
        timestamp: Number(block.time),
        bits: `0x${block.bits}`,
        nonce: block.nonce,
      })),
    );
  });

  it("invalid sequence (anchor -> block)", async () => {
    const { bitcoinProver } = await loadProverFixture();

    const anchorBlock = await bitcoinProver.getLastAcknowledgedAnchorBlock();
    const _2blocksAfterAnchor = await bitcoinClient.getBlockByNumber(
      Number(anchorBlock.anchorBlockNumber + 2n),
    );

    await expect(
      bitcoinProver.proveBlockChunk(
        EMPTY_PAST_CHUNK_PROOF,
        `0x${await bitcoinClient.getRawBlockHeader(_2blocksAfterAnchor.hash)}`,
        0n,
      ),
    ).to.revertedWith("Invalid seq");
  });

  it("successfully proved (anchor -> block)", async () => {
    const { bitcoinProver } = await loadProverFixture();

    const anchorBlock = await bitcoinProver.getLastAcknowledgedAnchorBlock();
    const _2blocksAfterAnchor = await bitcoinClient.getBlockByNumber(
      Number(anchorBlock.anchorBlockNumber + 1n),
    );

    await expect(
      bitcoinProver.proveBlockChunk(
        {
          partialProof: {
            contractSignature: "0x",
            computationsResult: "0x",
          },
          witnessSignatures: [],
        },
        `0x${await bitcoinClient.getRawBlockHeader(_2blocksAfterAnchor.hash)}`,
        0n,
      ),
    ).to.not.reverted;
  });

  it("invalid sequence (anchor -> block -> block)", async () => {
    const { bitcoinProver } = await loadProverFixture();

    const anchorBlock = await bitcoinProver.getLastAcknowledgedAnchorBlock();
    const _blockAfterAnchor = await bitcoinClient.getBlockByNumber(
      Number(anchorBlock.anchorBlockNumber + 1n),
    );

    const _3blocksAfterAnchor = await bitcoinClient.getBlockByNumber(
      Number(anchorBlock.anchorBlockNumber + 3n),
    );

    await expect(
      bitcoinProver.proveBlockChunk(
        EMPTY_PAST_CHUNK_PROOF,
        `0x${await bitcoinClient.getRawBlockHeader(_blockAfterAnchor.hash)}${await bitcoinClient.getRawBlockHeader(_3blocksAfterAnchor.hash)}`,
        0n,
      ),
    ).to.revertedWith("Invalid seq");
  });

  it("successfully proved (anchor -> block -> block)", async () => {
    const { bitcoinProver } = await loadProverFixture();

    const anchorBlock = await bitcoinProver.getLastAcknowledgedAnchorBlock();
    const _blockAfterAnchor = await bitcoinClient.getBlockByNumber(
      Number(anchorBlock.anchorBlockNumber + 1n),
    );

    const _2blocksAfterAnchor = await bitcoinClient.getBlockByNumber(
      Number(anchorBlock.anchorBlockNumber + 2n),
    );

    await expect(
      bitcoinProver.proveBlockChunk(
        EMPTY_PAST_CHUNK_PROOF,
        `0x${await bitcoinClient.getRawBlockHeader(_blockAfterAnchor.hash)}${await bitcoinClient.getRawBlockHeader(_2blocksAfterAnchor.hash)}`,
        0n,
      ),
    ).to.not.reverted;
  });

  it("successfully proved 10 blocks on top of seed anchor", async () => {
    const { bitcoinProver } = await loadProverFixture();

    const anchorBlock = await bitcoinProver.getLastAcknowledgedAnchorBlock();

    const _blocksAfterAnchor: Promise<string>[] = [];
    for (
      let i = Number(anchorBlock.anchorBlockNumber) + 1;
      i < Number(anchorBlock.anchorBlockNumber) + 11;
      i++
    ) {
      _blocksAfterAnchor.push(
        new Promise(async (resolve) => {
          resolve(
            await bitcoinClient.getRawBlockHeader(
              (await bitcoinClient.getBlockByNumber(i)).hash,
            ),
          );
        }),
      );
    }

    const blocksAfterAnchor = await Promise.all(_blocksAfterAnchor);

    await expect(
      bitcoinProver.proveBlockChunk(
        EMPTY_PAST_CHUNK_PROOF,
        `0x${blocksAfterAnchor.join("")}`,
        0n,
      ),
    ).to.not.reverted;
  });

  it("prove block with wrong difficulty", async () => {
    const { bitcoinProver } = await loadProverFixture();

    const anchorBlock = await bitcoinProver.getLastAcknowledgedAnchorBlock();
    const _blockAfterAnchor = await bitcoinClient.getBlockByNumber(
      Number(anchorBlock.anchorBlockNumber + 1n),
    );

    const _rawBlockAfterAnchor = await bitcoinClient.getRawBlockHeader(
      _blockAfterAnchor.hash,
    );

    const buffer = Buffer.from(_rawBlockAfterAnchor, "hex");
    buffer.writeUInt32LE(386108434, 72); // maliciously alter difficulty bits

    await expect(
      bitcoinProver.proveBlockChunk(
        EMPTY_PAST_CHUNK_PROOF,
        `0x${buffer.toString("hex")}`,
        0n,
      ),
    ).to.revertedWith("Invalid difficulty epoch");
  });

  it("prove block with wrong hash", async () => {
    const { bitcoinProver } = await loadProverFixture();

    const anchorBlock = await bitcoinProver.getLastAcknowledgedAnchorBlock();
    const _blockAfterAnchor = await bitcoinClient.getBlockByNumber(
      Number(anchorBlock.anchorBlockNumber + 1n),
    );

    const _rawBlockAfterAnchor = await bitcoinClient.getRawBlockHeader(
      _blockAfterAnchor.hash,
    );

    const buffer = Buffer.from(_rawBlockAfterAnchor, "hex");
    buffer.writeUInt32LE(123, 76); // maliciously simplify nonce

    await expect(
      bitcoinProver.proveBlockChunk(
        EMPTY_PAST_CHUNK_PROOF,
        `0x${buffer.toString("hex")}`,
        0n,
      ),
    ).to.revertedWith("Invalid block hash");
  });

  it("prove 10 blocks from anchor using rollup", async () => {
    const { bitcoinProver } = await loadProverFixture();

    const anchorBlock = await bitcoinProver.getLastAcknowledgedAnchorBlock();
    const _blocksAfterAnchor: Promise<string>[] = [];
    for (
      let i = Number(anchorBlock.anchorBlockNumber) + 1;
      i < Number(anchorBlock.anchorBlockNumber) + 11;
      i++
    ) {
      _blocksAfterAnchor.push(
        new Promise(async (resolve) => {
          resolve(
            await bitcoinClient.getRawBlockHeader(
              (await bitcoinClient.getBlockByNumber(i)).hash,
            ),
          );
        }),
      );
    }

    const blocksAfterAnchor = await Promise.all(_blocksAfterAnchor);

    const _firstBlockInChunk = await bitcoinClient.getBlockByNumber(
      Number(anchorBlock.anchorBlockNumber) + 1,
    );

    const _finalBlockInChunk = await bitcoinClient.getBlockByNumber(
      Number(anchorBlock.anchorBlockNumber) + 10,
    );

    const provedChunk = await bitcoinProver.proveBlockChunk(
      EMPTY_PAST_CHUNK_PROOF,
      `0x${blocksAfterAnchor.join("")}`,
      0n,
    );

    expect({
      prevChunkProofHash: provedChunk.prevChunkProofHash,
      startBlockNumberDelta: provedChunk.startBlockNumberDelta,
      startBlockHash: provedChunk.startBlockHash,
      chunkSize: provedChunk.chunkSize,
      endBlockHash: provedChunk.endBlockHash,
    }).to.deep.equal({
      prevChunkProofHash: ethers.ZeroHash,
      startBlockNumberDelta: 1n,
      startBlockHash: `0x${_firstBlockInChunk.hash}`,
      chunkSize: 10n,
      endBlockHash: `0x${_finalBlockInChunk.hash}`,
    });
  });

  it("chain rollup proofs to prove 20 blocks", async () => {
    const { bitcoinProver, computeBlockChunkProof, chunksToProve } =
      await loadChunksFixture(20, 10);
    const coder = ethers.AbiCoder.defaultAbiCoder();

    const rollup0 = await computeBlockChunkProof(
      EMPTY_PAST_CHUNK_PROOF,
      `0x${chunksToProve[0].join("")}`,
    );

    const rollup1 = await computeBlockChunkProof(
      {
        partialProof: {
          contractSignature: rollup0.partialSignature,
          computationsResult: rollup0.rawResult,
        },
        witnessSignatures: [],
      },
      `0x${chunksToProve[1].join("")}`,
    );

    expect(
      ethers.keccak256(
        coder.encode(
          // @ts-ignore
          [BLOCK_CHUNK_TYPE],
          [rollup0.blockChunkProof],
        ),
      ),
    ).to.eqls(rollup1.blockChunkProof.prevChunkProofHash);

    const rollupFinalPartialproof = await bitcoinProver.compute(
      coder.encode(
        ["uint8", "bytes"],
        [
          3, // ProvingAction.BlockChunkRollup,
          coder.encode(
            // @ts-ignore
            [{ ...FULL_COMPUTATIONS_PROOF_TYPE, type: "tuple[]" }],
            [
              [
                {
                  partialProof: {
                    contractSignature: rollup0.partialSignature,
                    computationsResult: rollup0.rawResult,
                  },
                  witnessSignatures: [],
                },
                {
                  partialProof: {
                    contractSignature: rollup1.partialSignature,
                    computationsResult: rollup1.rawResult,
                  },
                  witnessSignatures: [],
                },
              ],
            ],
          ),
        ],
      ),
    );

    const [rollupFinalSerializedEnvelope] = rollupFinalPartialproof;

    const [, fullRollup] = coder.decode(
      // @ts-ignore
      ["uint8", BLOCK_CHUNK_ROLLUP_TYPE],
      rollupFinalSerializedEnvelope,
    );

    expect({
      startBlockNumberDelta: fullRollup.startBlockNumberDelta,
      startBlockHash: fullRollup.startBlockHash,
      endBlockNumberDelta: fullRollup.endBlockNumberDelta,
      endBlockHash: fullRollup.endBlockHash,
    }).to.deep.equal({
      startBlockNumberDelta: rollup0.blockChunkProof.startBlockNumberDelta,
      startBlockHash: rollup0.blockChunkProof.startBlockHash,
      endBlockNumberDelta:
        rollup1.blockChunkProof.startBlockNumberDelta +
        rollup1.blockChunkProof.chunkSize,
      endBlockHash: rollup1.blockChunkProof.endBlockHash,
    });
  });

  it("chain-rollup many proofs to prove entire 2016 blocks epoch", async () => {
    const { fullRollup } = await loadDifficultyEpochFixture();

    expect({
      startBlockNumberDelta: fullRollup.startBlockNumberDelta,
      startBlockHash: fullRollup.startBlockHash,
      endBlockNumberDelta: fullRollup.endBlockNumberDelta,
      endBlockHash: fullRollup.endBlockHash,
    }).to.deep.equal({
      startBlockNumberDelta: 1n,
      startBlockHash:
        "0x00000000000000000001cfac9ad7ec72677564d657004c6f5f812480614b594a",
      endBlockNumberDelta: 2016n,
      endBlockHash:
        "0x000000000000000000005b3388af9acbfd8c00b5b3ec888a75085011cc69cbb2",
    });
  });

  it("not enough confirmations", async () => {
    const {
      bitcoinProver,
      chunksToProve,
      confirmationsProof,
      epochPartialSignature,
      epochRaw,
    } = await loadAnchorBlockConfirmations(2);

    await expect(
      bitcoinProver.proveAnchorBlock(
        {
          partialProof: {
            contractSignature: epochPartialSignature,
            computationsResult: epochRaw,
          },
          witnessSignatures: [],
        },
        confirmationsProof,
        `0x${chunksToProve[0][0]}`,
        `0x${chunksToProve[chunksToProve.length - 1][0]}`,
      ),
    ).to.revertedWith("Too few confirmations blocks");
  });

  it("ack anchor block", async () => {
    const {
      bitcoinProver,
      chunksToProve,
      confirmationsProof,
      epochPartialSignature,
      epochRaw,
    } = await loadAnchorBlockConfirmations(7);

    const coder = ethers.AbiCoder.defaultAbiCoder();

    const anchorBlockPartialProof = await bitcoinProver.compute(
      coder.encode(
        ["uint8", "bytes"],
        [
          2, // ProvingAction.AnchorBlock,
          coder.encode(
            [
              // @ts-ignore
              FULL_COMPUTATIONS_PROOF_TYPE,
              // @ts-ignore
              FULL_COMPUTATIONS_PROOF_TYPE,
              "bytes",
              "bytes",
            ],
            [
              {
                partialProof: {
                  contractSignature: epochPartialSignature,
                  computationsResult: epochRaw,
                },
                witnessSignatures: [],
              },
              confirmationsProof,
              `0x${chunksToProve[0][0]}`,
              `0x${chunksToProve[chunksToProve.length - 1][0]}`,
            ],
          ),
        ],
      ),
    );

    const [serializedEnvelope] = anchorBlockPartialProof;

    const [, newAnchorBlock] = coder.decode(
      // @ts-ignore
      ["uint8", ANCHOR_BLOCK_TYPE],
      serializedEnvelope,
    );

    const prevAnchorBlock =
      await bitcoinProver.getLastAcknowledgedAnchorBlock();

    await expect(
      bitcoinProver.ackAnchorBlock({
        partialProof: {
          computationsResult: anchorBlockPartialProof.computationsResult,
          contractSignature: anchorBlockPartialProof.contractSignature,
        },
        witnessSignatures: [],
      }),
    )
      .to.emit(bitcoinProver, "AnchorBlockUpdate")
      .withArgs(
        newAnchorBlock.anchorBlockHash,
        prevAnchorBlock.anchorBlockHash,
      );

    const newResolvedAnchorBlock =
      await bitcoinProver.getLastAcknowledgedAnchorBlock();
    expect(newResolvedAnchorBlock.anchorBlockHash).to.eq(
      newAnchorBlock.anchorBlockHash,
    );
  });

  const loadTxFixture = async (txHash: string) => {
    const fixture = await loadProverFixture();

    const rawTx = await bitcoinClient.getRawTx(txHash);
    const verboseTx = await bitcoinClient.getVerboseTx(txHash);

    return { ...fixture, rawTx, verboseTx };
  };

  it("tx deserialization", async () => {
    const TEST_TX_HASH =
      "15e102fab8286f94ca32b4e95fddb5502625925b5323966245a0529c82a2bc4e";
    const { bitcoinTransactionsVerifier, rawTx, verboseTx } =
      await loadTxFixture(TEST_TX_HASH);

    const tx = await bitcoinTransactionsVerifier.deserializeTransaction(
      `0x${rawTx}`,
    );

    expect(tx.hash).eq(`0x${TEST_TX_HASH}`);

    expect(tx.version).eq("0x00000001");
    expect(tx.lockTime).eq(0n);

    expect(tx.inputs.length).eq(verboseTx.vin.length);

    // Validate inputs
    for (let i = 0; i < tx.inputs.length; i++) {
      const input = tx.inputs[i];
      expect(input.importTxHash).eq(`0x${verboseTx.vin[i].txid}`);
      expect(input.scriptSig).eq(`0x${verboseTx.vin[i].scriptSig.hex}`);
    }

    expect(tx.outputs.length).eq(verboseTx.vout.length);

    // Validate outputs
    for (let i = 0; i < tx.outputs.length; i++) {
      const output = tx.outputs[i];
      expect(output.value).eq(verboseTx.vout[i].value * 1e8);
      expect(output.script).eq(`0x${verboseTx.vout[i].scriptPubKey.hex}`);
    }
  });

  it("successful tx validation", async () => {
    const TEST_TX_HASH =
      "15e102fab8286f94ca32b4e95fddb5502625925b5323966245a0529c82a2bc4e";
    const { bitcoinTransactionsVerifier, bitcoinProver, rawTx, verboseTx } =
      await loadTxFixture(TEST_TX_HASH);

    const TEST_BLOCK_HASH =
      "000000000000000000035e1c030fc5fce54e13c56f4f5dbcee77fee760c71ad0";

    const block = await bitcoinClient.getBlock(TEST_BLOCK_HASH, 2);

    const randomBlock = await bitcoinClient.getRawBlockHeader(TEST_BLOCK_HASH);

    function sha256(data: Buffer) {
      return createHash("sha256").update(data).digest();
    }

    const tree = new MerkleTree(
      block.tx!.map((tx) => Buffer.from(tx.txid, "hex")),
      sha256,
      {
        isBitcoinTree: true,
      },
    );

    expect(
      await bitcoinTransactionsVerifier.verifyTransactionRaw(
        `0x${rawTx}`,
        `0x${randomBlock}`,
        tree.getProof(Buffer.from(verboseTx.txid, "hex")).map((proof) => ({
          isLeft: proof.position === "left",
          data: `0x${proof.data.toString("hex")}`,
        })),
      ),
    ).to.true;
  });

  it("invalid tx merkle proof", async () => {
    const TEST_TX_HASH =
      "15e102fab8286f94ca32b4e95fddb5502625925b5323966245a0529c82a2bc4e";
    const { bitcoinTransactionsVerifier, bitcoinProver, rawTx, verboseTx } =
      await loadTxFixture(TEST_TX_HASH);

    const TEST_BLOCK_HASH =
      "00000000000000000002d92bcd23f00c341d3e39fc727c844530a218b62eaa42"; // wrong block, tx isn't included

    const block = await bitcoinClient.getBlock(TEST_BLOCK_HASH, 2);

    const randomBlock = await bitcoinClient.getRawBlockHeader(TEST_BLOCK_HASH);

    function sha256(data: Buffer) {
      return createHash("sha256").update(data).digest();
    }

    const tree = new MerkleTree(
      block.tx!.map((tx) => Buffer.from(tx.txid, "hex")),
      sha256,
      {
        isBitcoinTree: true,
      },
    );

    expect(
      await bitcoinTransactionsVerifier.verifyTransactionRaw(
        `0x${rawTx}`,
        `0x${randomBlock}`,
        tree.getProof(Buffer.from(verboseTx.txid, "hex")).map((proof) => ({
          isLeft: proof.position === "left",
          data: `0x${proof.data.toString("hex")}`,
        })),
      ),
    ).to.false;
  });

  const loadTxProvingFixture = async (txHash: string) => {
    const fixture = await loadTxFixture(txHash);

    const MockProcessorFactory = await ethers.getContractFactory(
      "MockBitcoinDepositProcessor",
    );
    const mockProcessor = await MockProcessorFactory.deploy(
      await fixture.bitcoinProver.getAddress(),
    );

    return { mockProcessor, ...fixture };
  };

  it("ack tx", async () => {
    const TEST_TX_HASH =
      "d9036b871601676afb0cbaa64b72f42061416f32ee6c0ad75b13c3a685f1971f";
    const {
      mockProcessor,
      computeBlockChunkProof,
      bitcoinProver,
      rawTx,
      verboseTx,
    } = await loadTxProvingFixture(TEST_TX_HASH);

    const TEST_BLOCK_HASH = verboseTx.blockhash;
    const block = await bitcoinClient.getBlock(TEST_BLOCK_HASH, 2);

    function sha256(data: Buffer) {
      return createHash("sha256").update(data).digest();
    }

    const tree = new MerkleTree(
      block.tx!.map((tx) => Buffer.from(tx.txid, "hex")),
      sha256,
      {
        isBitcoinTree: true,
      },
    );

    const blocksHeadersProm: Promise<string>[] = [];
    for (let i = block.height; i < block.height + 10; i++) {
      blocksHeadersProm.push(
        new Promise(async (resolve) => {
          resolve(
            await bitcoinClient.getRawBlockHeader(
              (await bitcoinClient.getBlockByNumber(i)).hash,
            ),
          );
        }),
      );
    }

    const blockHeaders = await Promise.all(blocksHeadersProm);

    const blockChunkProof = await computeBlockChunkProof(
      EMPTY_PAST_CHUNK_PROOF,
      `0x${blockHeaders.join("")}`,
    );

    const coder = ethers.AbiCoder.defaultAbiCoder();

    const txPartialProof = await bitcoinProver.compute(
      coder.encode(
        ["uint8", "bytes"],
        [
          1, // ProvingAction.Transaction,
          coder.encode(
            [
              "bytes",
              // @ts-ignore
              MERKLE_PROOFS_NODES_TYPE,
              "uint256",
              "bytes",
              // @ts-ignore
              FULL_COMPUTATIONS_PROOF_TYPE,
            ],
            [
              `0x${rawTx}`,
              tree
                .getProof(Buffer.from(verboseTx.txid, "hex"))
                .map((proof) => ({
                  isLeft: proof.position === "left",
                  data: `0x${proof.data.toString("hex")}`,
                })),
              0n,
              `0x${blockHeaders[0]}`,
              {
                partialProof: {
                  contractSignature: blockChunkProof.partialSignature,
                  computationsResult: blockChunkProof.rawResult,
                },
                witnessSignatures: [],
              },
            ],
          ),
        ],
      ),
    );

    const [txSerializedEnvelope, txPartialSignature] = txPartialProof;

    await expect(
      bitcoinProver.ackTransaction(
        {
          partialProof: {
            contractSignature: txPartialSignature,
            computationsResult: txSerializedEnvelope,
          },
          witnessSignatures: [],
        },
        await mockProcessor.getAddress(),
        "0x",
      ),
    )
      .to.emit(mockProcessor, "TxProofReceived")
      .withArgs(`0x${verboseTx.txid}`, 0n);
  });

  it("wallet address deposit proof (p2pkh)", async () => {
    let {
      bitcoinProver,
      verboseTx,
      rawTx,
      computeBlockChunkProof,
      bitcoinUtils,
    } = await loadTxFixture(
      "dbc87973ca2dafcfcdd076f5e47f65a022f7b17f3c8ae27d2da13c5f7b48e15a",
    );

    const DummyWalletFactory =
      await ethers.getContractFactory("DummyBitcoinWallet");

    const dummyWallet = await DummyWalletFactory.deploy(
      await bitcoinProver.getAddress(),
    );

    // Remove SegWit data
    rawTx =
      "0100000001828f2ecde0dea4c69d96f59b55ea913949c71af98647891d422ab9be647e137701000000171600145ed73734385ea5ff06de5bc1e1d2163d3bddcd72ffffffff02b25e0200000000001976a9140ab90e7b0d67600985c763e83015acdee110119488acd2d568010000000017a914b428d731c7a73a9644600dfc1947d43c79c145118700000000";

    const TEST_BLOCK_HASH = verboseTx.blockhash;
    const block = await bitcoinClient.getBlock(TEST_BLOCK_HASH, 2);

    function sha256(data: Buffer) {
      return createHash("sha256").update(data).digest();
    }

    const tree = new MerkleTree(
      block.tx!.map((tx) => Buffer.from(tx.txid, "hex")),
      sha256,
      {
        isBitcoinTree: true,
      },
    );

    const blocksHeadersProm: Promise<string>[] = [];
    for (let i = block.height; i < block.height + 10; i++) {
      blocksHeadersProm.push(
        new Promise(async (resolve) => {
          resolve(
            await bitcoinClient.getRawBlockHeader(
              (await bitcoinClient.getBlockByNumber(i)).hash,
            ),
          );
        }),
      );
    }

    const blockHeaders = await Promise.all(blocksHeadersProm);

    const blockChunkProof = await computeBlockChunkProof(
      EMPTY_PAST_CHUNK_PROOF,
      `0x${blockHeaders.join("")}`,
    );

    const coder = ethers.AbiCoder.defaultAbiCoder();

    const txPartialProof = await bitcoinProver.compute(
      coder.encode(
        ["uint8", "bytes"],
        [
          1, // ProvingAction.Transaction,
          coder.encode(
            [
              "bytes",
              // @ts-ignore
              MERKLE_PROOFS_NODES_TYPE,
              "uint256",
              "bytes",
              // @ts-ignore
              FULL_COMPUTATIONS_PROOF_TYPE,
            ],
            [
              `0x${rawTx}`,
              tree
                .getProof(Buffer.from(verboseTx.txid, "hex"))
                .map((proof) => ({
                  isLeft: proof.position === "left",
                  data: `0x${proof.data.toString("hex")}`,
                })),
              0n,
              `0x${blockHeaders[0]}`,
              {
                partialProof: {
                  contractSignature: blockChunkProof.partialSignature,
                  computationsResult: blockChunkProof.rawResult,
                },
                witnessSignatures: [],
              },
            ],
          ),
        ],
      ),
    );

    await expect(
      bitcoinProver.ackTransaction(
        {
          partialProof: {
            contractSignature: txPartialProof.contractSignature,
            computationsResult: txPartialProof.computationsResult,
          },
          witnessSignatures: [],
        },
        await dummyWallet.getAddress(),
        "0x",
      ),
    )
      .to.emit(dummyWallet, "DummyDeposit")
      .withArgs(155314n, "0x0ab90e7b0d67600985c763e83015acdee1101194");
  });
});

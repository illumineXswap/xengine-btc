import { deployments, ethers } from "hardhat";
import { BitcoinClient } from "../../../utils/bitcoin-rpc";

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

const main = async () => {
  const deployment = await deployments.get("BitcoinProver");
  const prover = await ethers.getContractAt(
    "BitcoinProver",
    deployment.address,
  );

  const client = new BitcoinClient(process.env.BITCOIN_RPC_CLIENT!);

  const try_fetch_range = async (
    _from: number,
    _to: number,
  ): Promise<string[]> => {
    const chunk: Promise<string>[] = [];
    for (let i = _from; i < _to; i++) {
      chunk.push(
        new Promise(async (resolve, reject) => {
          try {
            resolve(
              await client.getRawBlockHeader(
                (await client.getBlockByNumber(i)).hash,
              ),
            );
          } catch (err) {
            reject(err);
          }
        }),
      );
    }

    return Promise.all(chunk);
  };

  const splitIntoChunks = (blocksToProve: string[], chunkSize: number) => {
    const chunksToProve: string[][] = [];

    const chunksAmount = Math.floor(blocksToProve.length / chunkSize);
    const leftOver = blocksToProve.length % chunkSize;

    for (let c = 0; c < chunksAmount; c++) {
      const chunk: string[] = [];
      for (let i = c * chunkSize + 1; i < c * chunkSize + chunkSize + 1; i++) {
        chunk.push(blocksToProve[i]);
      }

      chunksToProve.push(chunk);
    }

    const leftoverChunk: string[] = [];
    const lastC = chunksAmount - 1;

    const lastCheckpoint = lastC * chunkSize + chunkSize + 1;

    for (let i = lastCheckpoint; i < lastCheckpoint + leftOver; i++) {
      leftoverChunk.push(blocksToProve[i]);
    }

    chunksToProve.push(leftoverChunk);

    return chunksToProve;
  };

  const computeBlockChunkProof = async (
    previousProof: FullComputationsProof,
    blockHeaders: string,
  ): Promise<{
    partialSignature: string;
    rawResult: string;
    blockChunkProof: BlockChunkProof;
  }> => {
    const coder = ethers.AbiCoder.defaultAbiCoder();
    const latestAnchor = await prover.getLastAcknowledgedAnchorBlock();
    const latestAnchorIndex = await prover.anchorBlockHashToIndex(
      latestAnchor.anchorBlockHash,
    );

    const rollup0Partialproof = await prover.compute(
      coder.encode(
        ["uint8", "bytes"],
        [
          0, // ProvingAction.BlockChunk,
          coder.encode(
            // @ts-ignore
            [FULL_COMPUTATIONS_PROOF_TYPE, "bytes", "uint256"],
            [previousProof, blockHeaders, latestAnchorIndex],
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

  const computeEpochProof = async (chunksToProve: string[][]) => {
    const coder = ethers.AbiCoder.defaultAbiCoder();
    let prevRollup = EMPTY_PAST_CHUNK_PROOF;

    const chunksRollups: (typeof EMPTY_PAST_CHUNK_PROOF)[] = [];
    let i = 0;
    for (const chunk of chunksToProve) {
      const chunkRollup = await computeBlockChunkProof(
        prevRollup,
        `0x${chunk.join("")}`,
      );

      console.log(
        `Proved ${chunk.length} blocks: ${i++} / ${chunksToProve.length}`,
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

    const rollupFinalPartialproof = await prover.compute(
      coder.encode(
        ["uint8", "bytes"],
        [
          3, // ProvingAction.BlockChunkRollup,
          coder.encode(
            // @ts-ignore
            [{ ...FULL_COMPUTATIONS_PROOF_TYPE, type: "tuple[]" }],
            [chunksRollups.slice(0, chunksRollups.length - 1)],
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
      fullRollup,
      rawResult: rollupFinalSerializedEnvelope,
      signature: rollup0PartialSignature,
      chunksRollups,
    };
  };

  const initialAnchorBlock = await prover.getLastAcknowledgedAnchorBlock();

  let fromBlockHeight = Number(initialAnchorBlock.anchorBlockNumber);

  const STEP = 50;

  let currentEpoch: string[] = [];
  let epochConfirmations: string[] = [];

  const MIN_CONFIRMATIONS = Number(await prover.minConfirmations()) + 1;
  const RETARGET_PERIOD = Number(await prover.RETARGET_DELTA());

  let isRetargeting = false;
  let isFinishing = false;

  while (true) {
    const latestBlock = await client.getLatestBlock();
    const diff = latestBlock.height - fromBlockHeight;

    const shift = diff > STEP ? STEP : diff;
    const toBlockHeight = fromBlockHeight + shift;

    let blocks: string[] = [];
    while (blocks.length === 0) {
      try {
        blocks = await try_fetch_range(fromBlockHeight, toBlockHeight);
      } catch (err) {
        console.log(err);
      }
    }

    for (let i = 0; i < blocks.length; i++) {
      if (!isRetargeting) {
        currentEpoch.push(blocks[i]);

        if (currentEpoch.length === RETARGET_PERIOD) {
          console.log(`Time to retarget. Fetching confirmations...`);
          isRetargeting = true;
        }
      } else {
        epochConfirmations.push(blocks[i]);

        console.log(
          `Epoch confirmations: ${epochConfirmations.length} / ${MIN_CONFIRMATIONS}`,
        );

        if (epochConfirmations.length >= MIN_CONFIRMATIONS) {
          console.log(`Building proofs for epoch and confirmations...`);

          const chunksToProve = splitIntoChunks(currentEpoch, 100);
          chunksToProve.push(epochConfirmations);

          const rollup = await computeEpochProof(chunksToProve);

          const coder = ethers.AbiCoder.defaultAbiCoder();

          const anchorBlockPartialProof = await prover.compute(
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
                        contractSignature: rollup.signature,
                        computationsResult: rollup.rawResult,
                      },
                      witnessSignatures: [],
                    },
                    rollup.chunksRollups[rollup.chunksRollups.length - 1],
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

          console.log(`Submitting new anchor block...`);
          console.log(newAnchorBlock);

          const tx = await prover.ackAnchorBlock({
            partialProof: {
              computationsResult: anchorBlockPartialProof.computationsResult,
              contractSignature: anchorBlockPartialProof.contractSignature,
            },
            witnessSignatures: [],
          });

          console.log(`Tx sent: ${tx.hash}`);
          const txResult = await tx.wait();

          if (!txResult || txResult.status !== 1) {
            console.log("Error!");
          }

          isFinishing = true;
          isRetargeting = false;
          epochConfirmations = [];
          currentEpoch = [];

          break;
        }
      }
    }

    if (!isFinishing) {
      console.log(
        `Saved [${currentEpoch.length} / ${RETARGET_PERIOD}] blocks into epoch cache => ${(currentEpoch.length / RETARGET_PERIOD) * 100}%`,
      );

      fromBlockHeight = toBlockHeight;
    } else {
      const latestAnchor = await prover.getLastAcknowledgedAnchorBlock();

      isFinishing = false;
      fromBlockHeight = Number(latestAnchor.anchorBlockNumber);
    }
  }
};

main();

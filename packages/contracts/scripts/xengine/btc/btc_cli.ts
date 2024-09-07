import { deployments, ethers, getChainId } from "hardhat";
import b58 from "bs58";
import base58 from "bs58";
import Vorpal from "vorpal";
import { BitcoinClient } from "../../../utils/bitcoin-rpc";
import { createHash } from "node:crypto";
import { MerkleTree } from "merkletreejs";
import { bech32 } from "bech32";
import * as crypto from "crypto";
import * as secp256k1 from "secp256k1";

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
  const client = new BitcoinClient(process.env.BITCOIN_RPC_CLIENT!);

  const _vault = await deployments.get("VaultBitcoinWallet");
  const wallet = await ethers.getContractAt(
      "VaultBitcoinWallet",
      _vault.address,
  );

  const dummyPure = await ethers.getContractAt(
      "BtcDummyPure",
      (await deployments.get("BtcDummyPure")).address,
  );

  const prover = await ethers.getContractAt(
      "BitcoinProver",
      await wallet.prover(),
  );

  const computeBlockChunkProof = async (
      previousProof: FullComputationsProof,
      blockHeaders: string,
      anchorIndex: bigint,
  ): Promise<{
    partialSignature: string;
    rawResult: string;
    blockChunkProof: BlockChunkProof;
  }> => {
    const coder = ethers.AbiCoder.defaultAbiCoder();

    const rollup0Partialproof = await prover.compute(
        coder.encode(
            ["uint8", "bytes"],
            [
              0, // ProvingAction.BlockChunk,
              coder.encode(
                  // @ts-ignore
                  [FULL_COMPUTATIONS_PROOF_TYPE, "bytes", "uint256"],
                  [previousProof, blockHeaders, anchorIndex],
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

  const computeChunksForTxProof = async (
      previousBlocks: string[],
      confirmationsSubChain: string[],
      anchor: bigint,
  ) => {
    let prevRollup = EMPTY_PAST_CHUNK_PROOF;

    const chunksToProve = splitIntoChunks(previousBlocks, 100);

    const chunksRollups: (typeof EMPTY_PAST_CHUNK_PROOF)[] = [];
    let i = 0;
    for (const chunk of chunksToProve) {
      const chunkRollup = await computeBlockChunkProof(
          prevRollup,
          `0x${chunk.join("")}`,
          anchor,
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

    return computeBlockChunkProof(
        prevRollup,
        `0x${confirmationsSubChain.join("")}`,
        anchor,
    );
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
      if (blocksToProve[i]) {
        leftoverChunk.push(blocksToProve[i]);
      }
    }

    if (leftoverChunk.length > 0) {
      chunksToProve.push(leftoverChunk);
    }

    return chunksToProve;
  };

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

  const encodeBtcAddress = async (str: string): Buffer => {
    let dst: Buffer;
    if (
        str.startsWith("bc") ||
        str.startsWith("tb")
    ) {
      dst = Buffer.from(
          bech32.fromWords(bech32.decode(str).words.slice(1)),
      );

      const chainId = await getChainId();
      const isTestnet = chainId === "23295" || chainId === "23293";

      const prefix = isTestnet ? 0xf1 : 0xf3;

      const hash0 = crypto.createHash("sha256");
      hash0.update(Buffer.concat([Buffer.from([prefix]), dst]));

      const hash1 = crypto.createHash("sha256");
      hash1.update(hash0.digest());

      const hashDigest = hash1.digest();

      // Here we support only P2WPKH
      dst = Buffer.concat([
        Buffer.from([prefix]),
        dst,
        hashDigest.subarray(0, 4),
      ]);
    } else {
      dst = Buffer.from(base58.decode(str));
    }

    return dst;
  }

  const vorpal = new Vorpal();

  vorpal.command("prover:state", "Show prover state").action(async () => {
    const chainParams = await prover.chainParams();
    const minConfirmations = await prover.minConfirmations();

    const lastAnchorBlock = await prover.getLastAcknowledgedAnchorBlock();

    console.log(`${"=".repeat(10)} ChainParams:`);
    console.log(`ChainID: ${chainParams.networkID}`);
    console.log(`Is Testnet: ${chainParams.isTestnet}`);
    console.log(`Min confirmations: ${minConfirmations}`);
    console.log(`${"=".repeat(10)} Anchor block:`);
    console.log(`Number: ${lastAnchorBlock.anchorBlockNumber}`);
    console.log(`Hash: ${lastAnchorBlock.anchorBlockHash}`);
    console.log(`${"=".repeat(10)} Meta:`);
    console.log(`BTC Token address: ${await wallet.btcToken()}`);
  });

  vorpal
      .command("prover:admin:set_min", "Set min confirmations")
      .option("--min <min>", "Min confirmations)")
      .action(async (args) => {
        await prover.setMinConfirmations(Number(args.options.min));
      });

  vorpal
      .command("vault:admin:set_satoshi_per_byte", "Set SPB")
      .option("--value <value>", "SPB value)")
      .action(async (args) => {
        await wallet.setFee(Number(args.options.value));
      });

  vorpal
      .command("vault:admin:update_pubkey", "Set offchain pubkey")
      .option("--pubkey <pubkey>", "Offchain public key")
      .types({ string: ["pubkey"] })
      .action(async (args) => {
        await wallet.updateOffchainSignerPubKey(args.options.pubkey);
      });

  vorpal
      .command("prover:admin:set_witness", "Set witness pubkey")
      .option("--pubkey <pubkey>", "Witness pubkey")
      .types({ string: ["pubkey"] })
      .action(async (args) => {
        await prover.toggleWitnessPublicKey(args.options.pubkey);
      });

  vorpal
      .command("prover:admin:set_min_witness", "Set witness pubkey")
      .option("--min <min>", "Min")
      .action(async (args) => {
        await prover.setMinWitnessConfirmations(args.options.min);
      });

  vorpal
      .command("vault:withdraw", "Withdraw")
      .option("--to <to>", "BTC destination address")
      .option("--amount <amount>", "Sat amount")
      .action(async (args) => {
        const dst = await encodeBtcAddress(args.options.to);

        const idSeed = ethers.randomBytes(32);

        await wallet.withdraw(dst, args.options.amount, 0, idSeed);
      });

  vorpal.command("vault:admin:set_relayer")
      .option("--address <address>", "Relayer address")
      .types({ string: ["address"] })
      .action(async (args) => {
        await wallet.toggleRelayer(args.options.address);
      });

  vorpal.command("vault:admin:set_aml_fee")
      .option("--fee <fee>", "AML fee (sats)")
      .action(async (args) => {
        const Factory = await ethers.getContractAt("RefundTxSerializerFactory", await wallet.refundSerializerFactory());
        await Factory.setAmlFees(args.options.fee);
      });

  vorpal.command("vault:admin:set_aml_locking_script")
      .option("--script <script>", "AML locking script")
      .types({ string: ["script"] })
      .action(async (args) => {
        const Factory = await ethers.getContractAt("RefundTxSerializerFactory", await wallet.refundSerializerFactory());
        await Factory.setAmlFeesCollector(args.options.script);
      });

  vorpal
      .command("vault:refund_start")
      .option("--input <input>", "Input id")
      .option("--to <to>", "BTC address to refund to")
      .types({ string: ["input", "to"] })
      .action(async (args) => {
        const input = (args.options.input as string).split(":");

        const inputId = ethers.solidityPackedKeccak256(
            ["bytes32", "uint256"],
            [`0x${input[0]}`, input[1]],
        );

        console.log(await wallet.startRefundTxSerializing.staticCall(inputId, await encodeBtcAddress(args.options.to), 10n));
        const tx = await wallet.startRefundTxSerializing(inputId, await encodeBtcAddress(args.options.to), 10n);
        const receipt = await tx.wait();

        const _log = receipt.logs.find((x) => x.topics[0].slice(0, 10) === '0x3e1edff3');
        console.log(_log);

        const iface = new ethers.Interface([
          {
            "anonymous": false,
            "inputs": [
              {
                "indexed": false,
                "internalType": "bytes32",
                "name": "sigHash",
                "type": "bytes32"
              }
            ],
            "name": "SigHashFormed",
            "type": "event"
          },
        ]);

        const sigHash = iface.parseLog(_log).args[0];
        console.log(sigHash);
      })

  vorpal
      .command("vault:refund_finish")
      .option("--input <input>", "Input id")
      .option("--index <index>", "Refund index")
      .option("--sighash <sighash>", "Refund sighash")
      .option("--privkey <privkey>", "Private key")
      .types({ string: ["input", "sighash", "privkey"] })
      .action(async (args) => {
        const input = (args.options.input as string).split(":");

        const inputId = ethers.solidityPackedKeccak256(
            ["bytes32", "uint256"],
            [`0x${input[0]}`, input[1]],
        );

        const key = Buffer.from(args.options.privkey.slice(2), "hex");

        const { signature } = secp256k1.ecdsaSign(
            Buffer.from(args.options.sighash.slice(2), "hex"),
            key,
        );

        const sighex = `0x${Buffer.from(secp256k1.signatureExport(signature)).toString(
            "hex",
        )}`;

        const tx = await wallet.finaliseRefundTxSerializing(inputId, args.options.index, sighex);
        const receipt = await tx.wait();

        console.log(receipt.logs);
      })

  vorpal
      .command("vault:push")
      .option("--inputs <inputs>", "Inputs (tx1:out1,tx2:out2)")
      .option("--privkey <privkey>", "Signer private key")
      .types({ string: ["inputs", "privkey"] })
      .action(async (args) => {
        const inputs = (args.options.inputs as string)
            .split(",")
            .map((input) => input.split(":"));

        const queue = await ethers.getContractAt(
            "OutgoingQueue",
            await wallet.queue(),
        );
        console.log(await queue.nextBatchTime());

        let tx = await wallet.startOutgoingTxSerializing({
          gasLimit: 10_000_000,
        });
        const r0 = await tx.wait();

        if (!r0) {
          throw new Error("Invalid receipt");
        }

        const iface = new ethers.Interface([
          {
            anonymous: false,
            inputs: [
              {
                indexed: false,
                internalType: "address",
                name: "serializer",
                type: "address",
              },
            ],
            name: "TransactionSerializerCreated",
            type: "event",
          },
        ]);

        const _log = r0.logs.find((x) => x.topics[0].slice(0, 10) === '0x86861bd8');

        const serializer = await ethers.getContractAt(
            "TxSerializer",
            iface.parseLog(_log).args[0],
        );

        while (true) {
          try {
            await serializer.copyOutputs.staticCall(1);
            tx = await serializer.copyOutputs(1);
            await tx.wait();
          } catch (err) {
            console.log(err);
            break;
          }
        }

        await serializer.enrichOutgoingTransaction.staticCallResult(
            inputs.map((input) => {
              return ethers.solidityPackedKeccak256(
                  ["bytes32", "uint256"],
                  [`0x${input[0]}`, input[1]],
              );
            }),
        );

        tx = await serializer.enrichOutgoingTransaction(
            inputs.map((input) => {
              return ethers.solidityPackedKeccak256(
                  ["bytes32", "uint256"],
                  [`0x${input[0]}`, input[1]],
              );
            }),
        );
        console.log(await tx.wait());

          for (let i = 0; i < inputs.length; i++) {
            while (true) {
              try {
                await serializer.enrichSigHash.staticCall(i, 1);

                tx = await serializer.enrichSigHash(i, 1);
                console.log(await tx.wait());
              } catch (err) {
                console.log(err);
                break;
              }
            }
          }

        console.log(await serializer.partiallySignOutgoingTransaction.staticCallResult(inputs.length));
        tx = await serializer.partiallySignOutgoingTransaction(inputs.length);

        const receiptPartialSignature = await tx.wait();
        if (!receiptPartialSignature) {
          throw new Error("Invalid receipt");
        }

        console.log(receiptPartialSignature.logs);

        const sigHashes = receiptPartialSignature.logs.map((log) => log.data);
        if (sigHashes.length === 0) {
          throw new Error("Invalid sighash array length");
        }

        console.log(sigHashes);

        const key = Buffer.from(args.options.privkey.slice(2), "hex");
        const signatures = sigHashes.map((s) => {
          const { signature } = secp256k1.ecdsaSign(
              Buffer.from(s.slice(2), "hex"),
              key,
          );
          return `0x${Buffer.from(secp256k1.signatureExport(signature)).toString(
              "hex",
          )}`;
        });

        let c = 0;
        while (true) {
          const signaturesSlice = signatures.slice(c, c + 1);

            try {
                await serializer.serializeOutgoingTransaction.staticCall(
                    1,
                    ethers.AbiCoder.defaultAbiCoder().encode(["bytes[]"], [signaturesSlice]),
                    {
                        gasLimit: 10_000_000,
                    },
                );
            } catch (err) {
              console.log(err);
              break;
            }

            tx = await serializer.serializeOutgoingTransaction(
                1,
                ethers.AbiCoder.defaultAbiCoder().encode(["bytes[]"], [signaturesSlice]),
                {
                    gasLimit: 10_000_000,
                },
            );
            await tx.wait();

            c++;
        }

        console.log(await wallet.finaliseOutgoingTxSerializing.staticCall());
        tx = await wallet.finaliseOutgoingTxSerializing();
        const receipt = await tx.wait();
        console.log(receipt.logs);
      });

  vorpal
      .command("vault:refuel")
      .option("--inputs <inputs>", "Inputs (tx1:out1,tx2:out2)")
      .option("--privkey <privkey>", "Signer private key")
      .option("--txid <txid>", "Tx hash")
      .types({ string: ["inputs", "privkey", "txid"] })
      .action(async (args) => {
        const inputs = (args.options.inputs as string)
            .split(",")
            .map((input) => input.split(":"));

        let tx = await wallet.startRefuelTxSerializing(args.options.txid, {
          gasLimit: 10_000_000,
        });
        const r0 = await tx.wait();

        if (!r0) {
          throw new Error("Invalid receipt");
        }

        const iface = new ethers.Interface([
          {
            anonymous: false,
            inputs: [
              {
                indexed: false,
                internalType: "address",
                name: "serializer",
                type: "address",
              },
            ],
            name: "TransactionSerializerCreated",
            type: "event",
          },
        ]);

        const _log = r0.logs.find((x) => x.topics[0].slice(0, 10) === '0x86861bd8');

        const serializer = await ethers.getContractAt(
            "RefuelTxSerializer",
            // iface.parseLog(_log).args[0],
            "0x45a4FFA521A65e9705aA65E072Dc91A6e2293E34"
        );

        const parentSerializer = await ethers.getContractAt(
            "TxSerializer",
            await serializer.derivedFrom(),
        );

        tx = await serializer.copyParentOutputs(6);
        await tx.wait();

        const parentInputsCount = await parentSerializer.getInputsCount();

        tx = await serializer.copyParentInputs(parentInputsCount);
        await tx.wait();

        tx = await serializer.enrichOutgoingTransaction(
            inputs.map((input) => {
              return ethers.solidityPackedKeccak256(
                  ["bytes32", "uint256"],
                  [`0x${input[0]}`, input[1]],
              );
            }),
         );
         console.log(await tx.wait());

        for (let i = 0; i < BigInt(inputs.length) + parentInputsCount; i++) {
          while (true) {
            try {
              await serializer.enrichSigHash.staticCall(
                  i,
                  1,
              );

              tx = await serializer.enrichSigHash(
                  i,
                  1,
              );
              console.log(await tx.wait());
            } catch (err) {
              console.log(err);
              break;
            }
          }
        }

        await serializer.partiallySignOutgoingTransaction.staticCallResult(
            BigInt(inputs.length) + parentInputsCount,
        );
        tx = await serializer.partiallySignOutgoingTransaction(
            BigInt(inputs.length) + parentInputsCount,
        );

        const receiptPartialSignature = await tx.wait();
        if (!receiptPartialSignature) {
          throw new Error("Invalid receipt");
        }

        console.log(receiptPartialSignature);

        const sigHashes = receiptPartialSignature.logs.map((log) => log.data);
        if (sigHashes.length === 0) {
          throw new Error("Invalid sighash array length");
        }

        console.log(sigHashes);

        const key = Buffer.from(args.options.privkey.slice(2), "hex");
        const signatures = sigHashes.map((s) => {
          const { signature } = secp256k1.ecdsaSign(
              Buffer.from(s.slice(2), "hex"),
              key,
          );
          return `0x${Buffer.from(secp256k1.signatureExport(signature)).toString(
              "hex",
          )}`;
        });

        let c = 0;
        while (true) {
          const signaturesSlice = signatures.slice(c, c + 1);

          try {
            await serializer.serializeOutgoingTransaction.staticCall(
                1,
                ethers.AbiCoder.defaultAbiCoder().encode(["bytes[]"], [signaturesSlice]),
                {
                  gasLimit: 10_000_000,
                },
            );
          } catch (err) {
            console.log(err);
            break;
          }

          tx = await serializer.serializeOutgoingTransaction(
              1,
              ethers.AbiCoder.defaultAbiCoder().encode(["bytes[]"], [signaturesSlice]),
              {
                gasLimit: 10_000_000,
              },
          );
          await tx.wait();

          c++;
        }

        tx = await wallet.finaliseRefuelTxSerializing(args.options.txid, 1);
        const receipt = await tx.wait();
        console.log(receipt.logs);

        // const testResult = await client.testTxInclusion(rawTx.slice(2));
        // console.log(testResult, rawTx.slice(2));
      });

  vorpal
      .command("prover:submit_tx", "Submit tx to wallet")
      .option("--txid <txid>", "Transaction ID (hash)")
      .option("--vout <vout>", "Tx out index")
      .option("--data <data>", "Encrypted order data")
      .option("--mode <mode>", "Settlement mode")
      .types({ string: ["txid", "data", "mode"] })
      .action(async (args) => {
        const modesMap: Record<string, number> = {
          "deposit": 0,
          "self": 1,
          "refund": 2,
        }

        const modeNum = modesMap[args.options.mode as string];
        if (modeNum === undefined) {
          throw new Error("Invalid mode");
        }

        const txInfo = await client.getVerboseTx(args.options.txid);
        let rawTx = await client.getRawTx(args.options.txid);

        if (txInfo.txid !== txInfo.hash) {
          // Remove segwit data and flag
          rawTx = rawTx.slice(0, 8).concat(rawTx.slice(12, rawTx.length));

          const lastVout = txInfo.vout[txInfo.vout.length - 1];
          const ind =
              rawTx.indexOf(lastVout.scriptPubKey.hex) +
              lastVout.scriptPubKey.hex.length;
          rawTx = rawTx.slice(0, ind).concat(rawTx.slice(rawTx.length - 8));
        }

        const blockFullInfo = await client.getBlock(txInfo.blockhash, 2);
        const rawBlock = await client.getRawBlockHeader(blockFullInfo.hash);

        const seedAnchorBlockInfo = await client.getBlock(
            process.env.DEPLOY_BTC_PROVER_SEED_ANCHOR_BLOCK!,
            2,
        );

        const relativeAnchorIndex = Math.floor(
            (blockFullInfo.height - seedAnchorBlockInfo.height) / 2016,
        );

        const anchorBlockToStartFrom =
            await prover.anchorBlocks(relativeAnchorIndex);

        const min = await prover.minConfirmations();

        function sha256(data: Buffer) {
          return createHash("sha256").update(data).digest();
        }

        const tree = new MerkleTree(
            blockFullInfo.tx!.map((tx) => Buffer.from(tx.txid, "hex")),
            sha256,
            {
              isBitcoinTree: true,
            },
        );

        let fromBlockHeight = Number(anchorBlockToStartFrom.anchorBlockNumber);

        const STEP = 50;

        const finalHeadersList: string[] = [];

        while (true) {
          const latestBlock = await client.getLatestBlock();
          const diff = latestBlock.height - fromBlockHeight;

          const shift = diff > STEP ? STEP : diff;
          const toBlockHeight = fromBlockHeight + shift;

          console.log(
              `Downloading blocks: ${fromBlockHeight} / ${blockFullInfo.height + Number(min) + 1}`,
          );

          let blocks: string[] = [];
          while (blocks.length === 0) {
            try {
              blocks = await try_fetch_range(fromBlockHeight, toBlockHeight);
            } catch (err) {
              console.log(err);
            }
          }

          finalHeadersList.push(...blocks);
          if (toBlockHeight >= blockFullInfo.height + Number(min) + 1) {
            break;
          }

          fromBlockHeight = toBlockHeight;
        }

        const startBlockIndex = finalHeadersList.indexOf(rawBlock);
        const confirmationsSubchain = finalHeadersList.slice(
            startBlockIndex,
            startBlockIndex + Number(min) + 1,
        );

        const blockChunkProof = await computeChunksForTxProof(
            finalHeadersList.slice(0, startBlockIndex),
            confirmationsSubchain,
            BigInt(relativeAnchorIndex),
        );

        const coder = ethers.AbiCoder.defaultAbiCoder();

        const txPartialProof = await prover.compute(
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
                        tree.getProof(Buffer.from(txInfo.txid, "hex")).map((proof) => ({
                          isLeft: proof.position === "left",
                          data: `0x${proof.data.toString("hex")}`,
                        })),
                        args.options.vout,
                        `0x${rawBlock}`,
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

        const tx = await prover.ackTransaction(
            {
              partialProof: {
                contractSignature: txPartialProof.contractSignature,
                computationsResult: txPartialProof.computationsResult,
              },
              witnessSignatures: [],
            },
            _vault.address,
            coder.encode(
                ["uint8", "bytes"],
                [modeNum, args.options.data],
            ),
        );

        console.log(`Ack tx hash: ${tx.hash}`);
        const receipt = await tx.wait();

        if (!receipt || receipt.status !== 1) {
          console.error("Tx failed");
          return;
        }

        console.log(`Tx ack successful`);
      });

  vorpal
      .command(
          "vault:order_recover",
          "Recover BTC deposit address by order recovery data",
      )
      .option("--data <data>", "Recovery data")
      .types({ string: ["data"] })
      .action(async (args) => {
        const addressData = await wallet.getAddressByOrderRecoveryData(
            args.options.data,
        );

        console.log(b58.encode(Buffer.from(addressData.slice(2), "hex")));
      });

  vorpal
      .command("vault:gen_order", "Generate order")
      .option("--address <address>", "Destination address (EVM)")
      .types({ string: ["address"] })
      .action(async (args) => {
        const addressTo = args.options.address;
        if (!ethers.isAddress(addressTo)) {
          console.error(
              "Invalid address provided. Use as ./btc_cli.ts <address>",
          );

          return;
        }

        const orderData = await wallet.generateOrder(
            addressTo,
            ethers.ZeroHash,
            ethers.randomBytes(32),
            {
              gasLimit: 50_000_000,
            },
        );

        console.log(
            `Deposit to: ${b58.encode(Buffer.from(orderData.btcAddr.slice(2), "hex"))}`,
        );

        console.log(`Encrypted order data: ${orderData.orderData}`);
      });

  vorpal.delimiter(`Bitcoin CLI> `).show();
};

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
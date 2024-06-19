import { expect } from "chai";
import { ethers } from "hardhat";
import { rsToDer } from "../utils/crypto-utils";
import * as secp256k1 from "secp256k1";

const getRandomArbitrary = (min: number, max: number): number => {
  min = Math.ceil(min);
  max = Math.floor(max);
  return Math.floor(Math.random() * (max - min + 1)) + min;
};

describe("TEE Rollup", () => {
  const loadMockFixture = async () => {
    const MockRollupFactory = await ethers.getContractFactory("MockTEERollup");
    const mockRollup = await MockRollupFactory.deploy();

    return { mockRollup };
  };

  const loadMockComputation = async () => {
    const { mockRollup } = await loadMockFixture();

    const coder = ethers.AbiCoder.defaultAbiCoder();

    const a = getRandomArbitrary(0, 1_000_000);
    const b = getRandomArbitrary(0, 1_000_000);

    const compInput = coder.encode(["uint256", "uint256"], [a, b]);
    const proof = await mockRollup.compute(compInput);

    return { mockRollup, a, b, compInput, proof };
  };

  const loadComputationWithWitnesses = async (n: number) => {
    const { mockRollup } = await loadMockFixture();

    const witnesses = [];
    for (let i = 0; i < n; i++) {
      witnesses.push(ethers.Wallet.createRandom());
    }

    await mockRollup.setMinWitness(Math.ceil(n / 2));
    await mockRollup.setWitness(
      witnesses.map((w) => w.signingKey.compressedPublicKey),
    );

    const coder = ethers.AbiCoder.defaultAbiCoder();

    const a = getRandomArbitrary(0, 1_000_000);
    const b = getRandomArbitrary(0, 1_000_000);

    const compInput = coder.encode(["uint256", "uint256"], [a, b]);
    const proof = await mockRollup.compute(compInput);

    return { mockRollup, a, b, compInput, proof, witnesses };
  };

  const loadBogusSigner = async (input: [number, number], output: number) => {
    const { mockRollup } = await loadMockFixture();

    const [offender] = await ethers.getSigners();

    const coder = ethers.AbiCoder.defaultAbiCoder();

    const bogusResult = coder.encode(["uint256"], [output]);
    const compInput = coder.encode(["uint256", "uint256"], input);

    const bogusProof = await offender.signMessage(bogusResult);

    return { mockRollup, bogusProof, bogusResult, compInput };
  };

  it("bogus signature passed", async () => {
    const { mockRollup, bogusResult, bogusProof } = await loadBogusSigner(
      [1, 2],
      4,
    );

    expect(
      await mockRollup.verifyComputations({
        partialProof: {
          computationsResult: bogusResult,
          contractSignature: bogusProof,
        },
        witnessSignatures: [],
      }),
    ).to.false;
  });

  it("no witnesses successful", async () => {
    const coder = ethers.AbiCoder.defaultAbiCoder();
    const { a, b, mockRollup, proof } = await loadMockComputation();

    expect(
      await mockRollup.verifyComputations({
        partialProof: {
          computationsResult: proof.computationsResult,
          contractSignature: proof.contractSignature,
        },
        witnessSignatures: [],
      }),
    ).to.true;

    const [sumResult] = coder.decode(["uint256"], proof.computationsResult);
    expect(sumResult).eq(a + b);
  });

  it("witness consensus requirement violation", async () => {
    const { mockRollup, proof } = await loadComputationWithWitnesses(3);

    expect(
      await mockRollup.verifyComputations({
        partialProof: {
          computationsResult: proof.computationsResult,
          contractSignature: proof.contractSignature,
        },
        witnessSignatures: [],
      }),
    ).to.false;
  });

  it("wrong witness", async () => {
    const { mockRollup, proof, witnesses } =
      await loadComputationWithWitnesses(3);

    const witnessSignatures = witnesses.map((w) => {
      const signature = w.signingKey.sign(
        ethers.solidityPackedKeccak256(["bytes"], [proof.computationsResult]),
      );

      return [
        rsToDer(signature.r, signature.s),
        w.signingKey.compressedPublicKey,
      ];
    });

    const randomSigner = ethers.Wallet.createRandom();
    witnessSignatures[0] = (() => {
      const signature = randomSigner.signingKey.sign(
        ethers.solidityPackedKeccak256(["bytes"], [proof.computationsResult]),
      );

      return [
        rsToDer(signature.r, signature.s),
        randomSigner.signingKey.compressedPublicKey,
      ];
    })();

    expect(
      await mockRollup.verifyComputations({
        partialProof: {
          computationsResult: proof.computationsResult,
          contractSignature: proof.contractSignature,
        },
        witnessSignatures: witnessSignatures.map((w) => ({
          publicKey: w[1],
          signature: w[0],
        })),
      }),
    ).to.false;
  });

  it("successful with witness", async () => {
    const { mockRollup, proof, witnesses } =
      await loadComputationWithWitnesses(3);

    const witnessSignatures = witnesses.map((w) => {
      const { signature } = secp256k1.ecdsaSign(
        Buffer.from(
          ethers
            .solidityPackedKeccak256(["bytes"], [proof.computationsResult])
            .slice(2),
          "hex",
        ),
        Buffer.from(w.privateKey.slice(2), "hex"),
      );
      const signatureHex = `0x${Buffer.from(
        secp256k1.signatureExport(signature),
      ).toString("hex")}`;

      return [signatureHex, w.signingKey.compressedPublicKey];
    });

    expect(
      await mockRollup.verifyComputations({
        partialProof: {
          computationsResult: proof.computationsResult,
          contractSignature: proof.contractSignature,
        },
        witnessSignatures: witnessSignatures.map((w) => ({
          publicKey: w[1],
          signature: w[0],
        })),
      }),
    ).to.true;
  });
});

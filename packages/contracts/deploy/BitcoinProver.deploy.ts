import "hardhat-deploy";
import { HardhatRuntimeEnvironment } from "hardhat/types";
import { DeployFunction } from "hardhat-deploy/types";
import { BitcoinClient } from "../utils/bitcoin-rpc";

const func: DeployFunction = async function (hre: HardhatRuntimeEnvironment) {
  const bitcoinClient = new BitcoinClient(process.env.BITCOIN_RPC_CLIENT!);

  const { deployments, getNamedAccounts, getChainId } = hre;
  const { deploy } = deployments;

  const chainId = await getChainId();

  const btcTxVerifier = await deployments.get("BitcoinTransactionsVerifier");

  const { deployer } = await getNamedAccounts();

  const SEED_ANCHOR_BLOCK_HASH =
    process.env.DEPLOY_BTC_PROVER_SEED_ANCHOR_BLOCK!;

  const anchorBlock = await bitcoinClient.getBlock(SEED_ANCHOR_BLOCK_HASH);
  const previousAnchorBlockHash = await bitcoinClient.getBlockHash(
    anchorBlock.height - 2016,
  );
  const previousAnchorBlock = await bitcoinClient.getBlock(
    previousAnchorBlockHash,
  );

  await deploy("BitcoinProver", {
    libraries: {
      BitcoinUtils: (await deployments.get("BitcoinUtils")).address,
    },
    from: deployer,
    log: true,
    args: [
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
      btcTxVerifier.address,
      chainId === "23295" || chainId === "23293" // Sapphire testnet or Sapphire local
        ? {
            networkID: "0x6f",
            isTestnet: true,
          }
        : {
            networkID: "0x00",
            isTestnet: false,
          },
    ],
  });
};

func.tags = ["BitcoinProver"];
func.dependencies = ["BitcoinTransactionsVerifier", "BitcoinUtils"];

export default func;

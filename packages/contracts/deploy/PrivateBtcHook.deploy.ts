import "hardhat-deploy";
import { HardhatRuntimeEnvironment } from "hardhat/types";
import { DeployFunction } from "hardhat-deploy/types";
import { getChainId } from "hardhat";

const func: DeployFunction = async function (hre: HardhatRuntimeEnvironment) {
  const { deployments, getNamedAccounts } = hre;
  const { deploy } = deployments;

  const PRIVATE_FACTORIES: Record<string, string> = {
    ["23295"]: hre.ethers.ZeroAddress,
    ["23293"]: hre.ethers.ZeroAddress,
    ["23294"]: "0xb539f1D01A437C7f30cAfC994e918F952dDc0bA2",
  };

  const { deployer } = await getNamedAccounts();

  const chainId = await getChainId();
  const factoryAddress = PRIVATE_FACTORIES[chainId];
  if (!factoryAddress) {
    throw new Error("Invalid chain id");
  }

  const bitcoinWalletDep = await deployments.get("VaultBitcoinWallet");
  const bitcoinWallet = await hre.ethers.getContractAt(
    "VaultBitcoinWallet",
    bitcoinWalletDep.address,
  );

  const createdContract = await deploy("BtcToPrivateBtcHook", {
    from: deployer,
    log: true,
    args: [await bitcoinWallet.btcToken(), factoryAddress],
  });

  await bitcoinWallet.enableHooks([createdContract.address]);
};

func.tags = ["BtcToPrivateBtcHook"];
func.dependencies = ["BitcoinVaultWallet"];

export default func;

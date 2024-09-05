import "hardhat-deploy";
import { HardhatRuntimeEnvironment } from "hardhat/types";
import { DeployFunction } from "hardhat-deploy/types";

const func: DeployFunction = async function (hre: HardhatRuntimeEnvironment) {
  const { deployments, getNamedAccounts } = hre;
  const { deploy } = deployments;

  const { deployer } = await getNamedAccounts();

  const scripts = {
    p2shScript: (await deployments.get("ScriptP2SH")).address,
    p2pkhScript: (await deployments.get("ScriptP2PKH")).address,
    vaultScript: (await deployments.get("ScriptVault")).address,
    p2wpkhScript: (await deployments.get("ScriptP2WPKH")).address,
    p2wshScript: (await deployments.get("ScriptP2WSH")).address,
  };

  await deploy("RefundTxSerializerFactory", {
    from: deployer,
    log: true,
    args: [scripts],
    libraries: {
      TxSerializerLib: (await deployments.get("TxSerializerLib")).address,
      BitcoinUtils: (await deployments.get("BitcoinUtils")).address,
    },
  });
};

func.tags = ["RefundTxSerializerFactory"];
func.dependencies = [
  "BitcoinUtils",
  "TxSerializerLib",
  "ScriptVault",
  "ScriptP2SH",
  "ScriptP2PKH",
  "ScriptP2WPKH",
  "ScriptP2WSH",
];

export default func;

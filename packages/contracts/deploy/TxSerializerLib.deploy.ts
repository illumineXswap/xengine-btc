import "hardhat-deploy";
import { HardhatRuntimeEnvironment } from "hardhat/types";
import { DeployFunction } from "hardhat-deploy/types";

const func: DeployFunction = async function (hre: HardhatRuntimeEnvironment) {
  const { deployments, getNamedAccounts } = hre;
  const { deploy } = deployments;

  const { deployer } = await getNamedAccounts();

  await deploy("TxSerializerLib", {
    from: deployer,
    log: true,
    args: [],
    libraries: {
      BitcoinUtils: (await deployments.get("BitcoinUtils")).address,
    },
  });
};

func.tags = ["TxSerializerLib"];
func.dependencies = ["BitcoinUtils"];

export default func;

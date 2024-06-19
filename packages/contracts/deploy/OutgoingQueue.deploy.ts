import "hardhat-deploy";
import { HardhatRuntimeEnvironment } from "hardhat/types";
import { DeployFunction } from "hardhat-deploy/types";

const func: DeployFunction = async function (hre: HardhatRuntimeEnvironment) {
  const { deployments, getNamedAccounts } = hre;
  const { deploy } = deployments;

  const { deployer } = await getNamedAccounts();

  await deploy("OutgoingQueue", {
    from: deployer,
    log: true,
    args: [],
  });
};

func.tags = ["OutgoingQueue"];
func.dependencies = [];

export default func;

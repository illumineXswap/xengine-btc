import "hardhat-deploy";
import { HardhatRuntimeEnvironment } from "hardhat/types";
import { DeployFunction } from "hardhat-deploy/types";

const func: DeployFunction = async function (hre: HardhatRuntimeEnvironment) {
  const { deployments, getNamedAccounts } = hre;
  const { deploy } = deployments;

  const bitcoinProver = await deployments.get("BitcoinProver");
  const outgoingQueue = await deployments.get("OutgoingQueue");

  const { deployer } = await getNamedAccounts();

  const keyPair = hre.ethers.Wallet.createRandom();

  console.log("*".repeat(40));
  console.log(`PRIVATE KEY: ${keyPair.signingKey.privateKey}`);
  console.log(`PUBLIC KEY: ${keyPair.signingKey.compressedPublicKey}`);
  console.log("*".repeat(40));

  const OutgoingQueue = await hre.ethers.getContractAt(
    "OutgoingQueue",
    outgoingQueue.address,
  );

  const txSerializerFactory = await deployments.get("TxSerializerFactory");
  const TxSerialierFactory = await hre.ethers.getContractAt(
    "TxSerializerFactory",
    txSerializerFactory.address,
  );

  const refuelTxSerializerFactory = await deployments.get(
    "RefuelTxSerializerFactory",
  );
  const RefuelTxSerialierFactory = await hre.ethers.getContractAt(
    "RefuelTxSerializerFactory",
    refuelTxSerializerFactory.address,
  );

  const scripts = {
    p2shScript: (await deployments.get("ScriptP2SH")).address,
    p2pkhScript: (await deployments.get("ScriptP2PKH")).address,
    vaultScript: (await deployments.get("ScriptVault")).address,
    p2wpkhScript: (await deployments.get("ScriptP2WPKH")).address,
    p2wshScript: (await deployments.get("ScriptP2WSH")).address,
  };

  const vaultWallet = await deploy("VaultBitcoinWallet", {
    from: deployer,
    log: true,
    libraries: {
      BitcoinUtils: (await deployments.get("BitcoinUtils")).address,
      TxSerializerLib: (await deployments.get("TxSerializerLib")).address,
    },
    args: [
      bitcoinProver.address,
      keyPair.signingKey.compressedPublicKey,
      scripts,
      outgoingQueue.address,
      txSerializerFactory.address,
      refuelTxSerializerFactory.address,
    ],
  });

  await OutgoingQueue.init(vaultWallet.address);

  await TxSerialierFactory.init(vaultWallet.address);
  await RefuelTxSerialierFactory.init(vaultWallet.address);
};

func.tags = ["BitcoinVaultWallet"];
func.dependencies = [
  "BitcoinProver",
  "ScriptVault",
  "ScriptP2SH",
  "ScriptP2PKH",
  "ScriptP2WPKH",
  "ScriptP2WSH",
  "OutgoingQueue",
  "BitcoinUtils",
  "TxSerializerLib",
  "TxSerializerFactory",
  "RefuelTxSerializerFactory",
];

export default func;

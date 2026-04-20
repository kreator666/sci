import { ethers, network } from "hardhat";
import * as fs from "fs";
import * as path from "path";

interface DeploymentConfig {
  minStakeAmount: bigint;
  unbondingPeriod: number;
  jailPeriod: number;
}

interface DeploymentResult {
  implementation: string;
  factory: string;
  proxy: string;
  blockNumber: number;
  timestamp: string;
  network: string;
}

const CONFIG: DeploymentConfig = {
  minStakeAmount: ethers.parseEther("32"),
  unbondingPeriod: 14 * 24 * 60 * 60,
  jailPeriod: 7 * 24 * 60 * 60,
};

const DEPLOYMENTS_DIR = path.join(__dirname, "../deployments");

function ensureDeploymentsDir(): void {
  if (!fs.existsSync(DEPLOYMENTS_DIR)) {
    fs.mkdirSync(DEPLOYMENTS_DIR, { recursive: true });
  }
}

function saveDeployment(result: DeploymentResult): void {
  ensureDeploymentsDir();
  const filename = `${result.network}-${Date.now()}.json`;
  const filepath = path.join(DEPLOYMENTS_DIR, filename);
  fs.writeFileSync(filepath, JSON.stringify(result, null, 2));
  console.log(`\nDeployment info saved to: ${filepath}`);

  const latestPath = path.join(DEPLOYMENTS_DIR, `${result.network}-latest.json`);
  fs.writeFileSync(latestPath, JSON.stringify(result, null, 2));
  console.log(`Latest deployment info saved to: ${latestPath}`);
}

async function main(): Promise<void> {
  console.log("=========================================");
  console.log("Starting deployment to", network.name);
  console.log("=========================================\n");

  const [deployer] = await ethers.getSigners();
  const deployerAddress = await deployer.getAddress();
  const balance = await ethers.provider.getBalance(deployerAddress);

  console.log("Deployer address:", deployerAddress);
  console.log("Deployer balance:", ethers.formatEther(balance), "ETH");
  console.log();

  if (balance < ethers.parseEther("0.5")) {
    console.warn("Warning: Deployer balance is low. Consider adding more ETH for gas.");
    console.log();
  }

  console.log("Step 1: Deploying PoSRStake implementation contract...");
  const PoSRStake = await ethers.getContractFactory("PoSRStake");
  const implementation = await PoSRStake.deploy();
  await implementation.waitForDeployment();
  const implementationAddress = await implementation.getAddress();
  console.log("  PoSRStake implementation deployed at:", implementationAddress);
  console.log("  Transaction hash:", implementation.deploymentTransaction()?.hash);
  console.log();

  console.log("Step 2: Deploying PoSRStakeFactory contract...");
  const PoSRStakeFactory = await ethers.getContractFactory("PoSRStakeFactory");
  const factory = await PoSRStakeFactory.deploy(implementationAddress);
  await factory.waitForDeployment();
  const factoryAddress = await factory.getAddress();
  console.log("  PoSRStakeFactory deployed at:", factoryAddress);
  console.log("  Transaction hash:", factory.deploymentTransaction()?.hash);
  console.log();

  console.log("Step 3: Deploying PoSRStake proxy via factory...");
  console.log("  Parameters:");
  console.log("    minStakeAmount:", ethers.formatEther(CONFIG.minStakeAmount), "ETH");
  console.log("    unbondingPeriod:", CONFIG.unbondingPeriod / (24 * 60 * 60), "days");
  console.log("    jailPeriod:", CONFIG.jailPeriod / (24 * 60 * 60), "days");
  console.log("    admin:", deployerAddress);

  const deployTx = await factory.deployPoSRStake(
    CONFIG.minStakeAmount,
    CONFIG.unbondingPeriod,
    CONFIG.jailPeriod,
    deployerAddress
  );
  const receipt = await deployTx.wait();
  console.log("  Transaction hash:", receipt?.hash);
  console.log("  Gas used:", receipt?.gasUsed.toString());
  console.log();

  const deployedCount = await factory.getDeployedCount();
  const proxyAddress = await factory.deployedContracts(deployedCount - 1n);
  console.log("  PoSRStake proxy deployed at:", proxyAddress);
  console.log();

  const blockNumber = await ethers.provider.getBlockNumber();
  const result: DeploymentResult = {
    implementation: implementationAddress,
    factory: factoryAddress,
    proxy: proxyAddress,
    blockNumber: blockNumber,
    timestamp: new Date().toISOString(),
    network: network.name,
  };

  console.log("=========================================");
  console.log("Deployment Summary");
  console.log("=========================================");
  console.log("Network:", network.name);
  console.log("Block Number:", blockNumber);
  console.log();
  console.log("Contracts:");
  console.log("  Implementation (PoSRStake):", implementationAddress);
  console.log("  Factory (PoSRStakeFactory):", factoryAddress);
  console.log("  Proxy (PoSRStake):", proxyAddress);
  console.log();

  if (network.name !== "hardhat" && network.name !== "localhost") {
    console.log("Verification commands:");
    console.log("  npx hardhat verify --network", network.name, implementationAddress);
    console.log("  npx hardhat verify --network", network.name, factoryAddress, implementationAddress);
    console.log();
    console.log("Note: The proxy contract cannot be verified directly.");
    console.log("      Verify the implementation contract instead.");
  }

  saveDeployment(result);
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });

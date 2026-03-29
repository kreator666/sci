import { ethers, upgrades } from "hardhat";
import { HardhatEthersSigner } from "@nomicfoundation/hardhat-ethers/signers";

async function main() {
  const [deployer]: HardhatEthersSigner[] = await ethers.getSigners();
  
  console.log("Deploying PoSR Staking Protocol with account:", deployer.address);
  console.log("Account balance:", (await deployer.provider.getBalance(deployer.address)).toString());

  // 部署参数
  const minStakeAmount = ethers.parseEther("32");      // 最小质押 32 ETH
  const unbondingPeriod = 14 * 24 * 60 * 60;           // 解质押锁定期 14天
  const jailPeriod = 7 * 24 * 60 * 60;                 // 监禁期 7天

  // 1. 部署 PoSRStake 实现合约
  console.log("\n1. Deploying PoSRStake implementation...");
  const PoSRStake = await ethers.getContractFactory("PoSRStake");
  const posrStakeImpl = await PoSRStake.deploy();
  await posrStakeImpl.waitForDeployment();
  const posrStakeImplAddress = await posrStakeImpl.getAddress();
  console.log("PoSRStake implementation deployed to:", posrStakeImplAddress);

  // 2. 部署 PoSRStakeFactory
  console.log("\n2. Deploying PoSRStakeFactory...");
  const PoSRStakeFactory = await ethers.getContractFactory("PoSRStakeFactory");
  const factory = await PoSRStakeFactory.deploy(posrStakeImplAddress);
  await factory.waitForDeployment();
  const factoryAddress = await factory.getAddress();
  console.log("PoSRStakeFactory deployed to:", factoryAddress);

  // 3. 通过工厂部署代理合约
  console.log("\n3. Deploying PoSRStake proxy through factory...");
  const tx = await factory.deployPoSRStake(
    minStakeAmount,
    unbondingPeriod,
    jailPeriod,
    deployer.address
  );
  const receipt = await tx.wait();
  
  // 从事件中获取代理地址
  const event = receipt?.logs.find(
    (log: any) => log.fragment?.name === "ContractDeployed"
  );
  const proxyAddress = event?.args?.proxy;
  console.log("PoSRStake proxy deployed to:", proxyAddress);

  // 4. 验证部署
  console.log("\n4. Verifying deployment...");
  const posrStake = await ethers.getContractAt("PoSRStake", proxyAddress);
  
  console.log("  - Min stake amount:", ethers.formatEther(await posrStake.minStakeAmount()), "ETH");
  console.log("  - Unbonding period:", Number(await posrStake.unbondingPeriod()) / 86400, "days");
  console.log("  - Jail period:", Number(await posrStake.jailPeriod()) / 86400, "days");
  console.log("  - Admin:", await posrStake.hasRole(await posrStake.ADMIN_ROLE(), deployer.address));

  console.log("\n=== Deployment Complete ===");
  console.log("PoSRStake Implementation:", posrStakeImplAddress);
  console.log("PoSRStake Factory:", factoryAddress);
  console.log("PoSRStake Proxy:", proxyAddress);

  // 保存部署信息
  const deploymentInfo = {
    network: (await ethers.provider.getNetwork()).name,
    chainId: Number((await ethers.provider.getNetwork()).chainId),
    posrStakeImplementation: posrStakeImplAddress,
    posrStakeFactory: factoryAddress,
    posrStakeProxy: proxyAddress,
    deployer: deployer.address,
    timestamp: new Date().toISOString(),
    parameters: {
      minStakeAmount: minStakeAmount.toString(),
      unbondingPeriod: unbondingPeriod,
      jailPeriod: jailPeriod,
    },
  };

  console.log("\nDeployment Info:", JSON.stringify(deploymentInfo, null, 2));
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });

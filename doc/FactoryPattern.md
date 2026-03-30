# PoSR 质押合约工厂模式架构

## 概述

PoSR Staking Protocol 采用 **UUPS 代理模式 + 工厂模式** 的架构设计，实现业务逻辑与状态存储的分离，达到 Gas 优化和可升级的目标。

---

## 核心概念

### 实现地址 (Implementation)

`PoSRStakeFactory` 合约中的 `implementation` 地址指向 **PoSRStake 逻辑合约**。

```solidity
address public implementation;  // PoSRStake 实现合约地址
```

**设计思想**：
- 业务逻辑（代码）只部署 **一次**
- 每个代理合约存储自己的 **状态数据**
- 代理通过 `delegatecall` 调用实现合约的代码

---

## 架构图解

```
┌─────────────────────────────────────────────────────────────────┐
│                        工厂合约 (Factory)                         │
│                   (部署一次，用于创建多个实例)                      │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│   实现合约地址: PoSRStake Implementation                          │
│   (包含所有业务逻辑: createValidator, stake, claimRewards...)      │
│                                                                 │
│   ┌─────────────────────────────────────────────────────────┐   │
│   │  deployPoSRStake()                                      │   │
│   │       │                                                 │   │
│   │       ▼                                                 │   │
│   │   ┌─────────────┐     delegatecall     ┌─────────────┐ │   │
│   │   │  ERC1967Proxy│ ───────────────────► │ PoSRStake   │ │   │
│   │   │   (代理 #1)  │     (执行代码)        │ (实现合约)   │ │   │
│   │   └─────────────┘                      └─────────────┘ │   │
│   │   ┌─────────────────────────────────────────────────┐   │   │
│   │   │  状态存储 (每个代理独立)                          │   │   │
│   │   │  • validators (验证者映射)                        │   │   │
│   │   │  • delegations (委托映射)                         │   │   │
│   │   │  • totalStaked (总质押量)                         │   │   │
│   │   │  • minStakeAmount (最小质押)                      │   │   │
│   │   └─────────────────────────────────────────────────┘   │   │
│   └─────────────────────────────────────────────────────────┘   │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

---

## 部署流程

```javascript
// ========== 第1步：部署实现合约 ==========
// 只需部署一次，所有代理共享同一份代码
const PoSRStake = await ethers.getContractFactory("PoSRStake");
const impl = await PoSRStake.deploy();
console.log("Implementation:", impl.address);  // 0xImpl...

// ========== 第2步：部署工厂合约 ==========
// 传入实现合约地址
const PoSRStakeFactory = await ethers.getContractFactory("PoSRStakeFactory");
const factory = await PoSRStakeFactory.deploy(impl.address);

// ========== 第3步：创建代理实例 ==========
// 可多次调用，每次创建独立的代理合约
const tx = await factory.deployPoSRStake(
    ethers.parseEther("32"),     // minStakeAmount: 32 ETH
    14 * 24 * 60 * 60,            // unbondingPeriod: 14天
    7 * 24 * 60 * 60,             // jailPeriod: 7天
    adminAddress                  // 管理员地址
);
const proxyAddress = await factory.deployedContracts(0);
```

---

## 优势分析

| 优势 | 说明 | 数据对比 |
|-----|------|---------|
| **Gas 节省** | 业务逻辑只部署一次，代理仅存储状态 | 节省 ~80% 部署成本 |
| **可升级** | 更新工厂中的 `implementation` 地址，新代理自动使用新版本 | 无需重新部署逻辑 |
| **数据隔离** | 每个代理完全独立，一个合约的问题不影响其他 | 故障隔离 |
| **统一入口** | 通过工厂管理和追踪所有部署的合约实例 | 便于管理 |
| **版本控制** | 可部署新的实现合约，逐步迁移到新版本 | 平滑升级 |

---

## 实际应用场景

```
以太坊主网部署示例：
│
├── Layer 1: Ethereum Mainnet
│   └── PoSRStake Implementation (1个)
│       └── 包含所有业务逻辑代码 (约 500 行 Solidity)
│
├── Layer 2 / 应用链 (多个独立实例)
│   ├── PoSRStake Proxy #1 → Arbitrum One
│   │   └── 独立的验证者集合、质押状态
│   │
│   ├── PoSRStake Proxy #2 → Optimism
│   │   └── 独立的验证者集合、质押状态
│   │
│   ├── PoSRStake Proxy #3 → Base
│   │   └── 独立的验证者集合、质押状态
│   │
│   └── PoSRStake Proxy #4 → Linea
│       └── 独立的验证者集合、质押状态
│
└── 所有代理共享同一个 Implementation 的逻辑代码
```

---

## 升级策略

```javascript
// 1. 部署新版本的实现合约
const PoSRStakeV2 = await ethers.getContractFactory("PoSRStakeV2");
const implV2 = await PoSRStakeV2.deploy();

// 2. 更新工厂的实现地址
await factory.updateImplementation(implV2.address);

// 3. 新创建的代理自动使用 V2 逻辑
// (旧代理保持不变，可选择性迁移)
```

---

## 代码参考

### 工厂合约关键代码

```solidity
contract PoSRStakeFactory {
    address public implementation;
    address[] public deployedContracts;
    
    function deployPoSRStake(
        uint256 _minStakeAmount,
        uint256 _unbondingPeriod,
        uint256 _jailPeriod,
        address _admin
    ) external returns (address proxy) {
        // 准备初始化数据
        bytes memory initData = abi.encodeWithSelector(
            PoSRStake.initialize.selector,
            _minStakeAmount,
            _unbondingPeriod,
            _jailPeriod
        );
        
        // 部署代理合约，指向实现地址
        ERC1967Proxy proxyContract = new ERC1967Proxy(
            implementation,  // ← 业务逻辑合约地址
            initData
        );
        
        proxy = address(proxyContract);
        deployedContracts.push(proxy);
        
        // 转移管理员权限...
    }
}
```

### 代理调用流程

```solidity
// 用户调用代理合约
PoSRStake(proxy).stake(validatorAddress, {value: 1 ether});

// 代理合约内部 (ERC1967Proxy):
// 1. 读取 implementation 地址
// 2. 使用 delegatecall 转发调用到实现合约
// 3. 实现合约的代码在代理的上下文中执行
// 4. 状态变更保存在代理合约的存储中
```

---

## 总结

| 概念 | 说明 |
|-----|------|
| **Implementation** | PoSRStake 逻辑合约，包含业务代码 |
| **Proxy** | ERC1967Proxy，存储状态数据，通过 delegatecall 调用逻辑 |
| **Factory** | 用于批量创建代理实例，统一管理实现地址 |

**核心结论**：
> 工厂合约的 `implementation` 就是 **PoSRStake 逻辑合约的地址**。所有代理共享同一份代码执行逻辑，但各自独立存储数据，实现高效、可升级、可扩展的合约架构。

---

*文档生成时间: 2026-03-30*
*对应合约版本: PoSR Staking Protocol v1.0.0*

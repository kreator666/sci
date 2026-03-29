# PoSR Staking Protocol

PoSR (Proof of Stake Rotation) 质押协议 - EVM智能合约实现

## 项目概述

PoSR是一种权益证明质押协议，实现了验证者的质押、解质押、奖励分发和罚没机制。该协议适用于需要验证者轮换的区块链网络。

## 核心功能

### 1. 验证者管理
- **创建验证者**: 验证者需要质押最低金额（默认32 ETH）来注册
- **验证者信息**: 支持设置名称、身份标识、网站和描述
- **佣金设置**: 验证者可设置委托奖励的佣金比例（最高20%）

### 2. 质押机制
- **质押**: 用户可以向验证者委托代币
- **解质押**: 支持部分或全部解质押，需要等待锁定期（默认14天）
- **提取**: 锁定期结束后可提取质押的代币

### 3. 奖励系统
- **奖励池**: 管理员可向奖励池添加奖励
- **自动分配**: 基于质押金额和时间自动计算奖励
- **即时领取**: 用户可随时领取累积的奖励

### 4. 惩罚机制
- **监禁 (Jail)**: 违规验证者将被监禁（默认7天）
- **罚没 (Slash)**: 严重违规将罚没部分质押（默认5%）
- **自动恢复**: 监禁期结束后验证者可主动解除监禁

### 5. 安全特性
- **可升级合约**: 使用UUPS代理模式支持合约升级
- **访问控制**: 基于角色的权限管理
- **紧急暂停**: 支持合约暂停机制
- **重入保护**: 防止重入攻击

## 合约架构

```
contracts/
├── PoSRStake.sol          # 主质押合约
└── PoSRStakeFactory.sol   # 合约工厂，用于部署新实例
```

### PoSRStake 合约

核心合约，实现了完整的质押协议逻辑：

| 功能模块 | 说明 |
|---------|------|
| Validator | 验证者注册、信息管理、状态跟踪 |
| Staking | 质押、解质押、委托管理 |
| Rewards | 奖励计算、分配、领取 |
| Slashing | 罚没、监禁、恢复机制 |
| Access Control | 管理员、验证者、罚没者角色管理 |

### PoSRStakeFactory 合约

工厂合约，用于部署可升级的PoSRStake代理合约实例。

## 快速开始

### 1. 安装依赖

```bash
npm install
```

### 2. 配置环境变量

```bash
cp .env.example .env
# 编辑 .env 文件，填入你的配置
```

### 3. 编译合约

```bash
npm run compile
```

### 4. 运行测试

```bash
# 运行所有测试
npm test

# 运行测试并生成覆盖率报告
npm run test:coverage
```

### 5. 本地部署

```bash
# 启动本地节点
npm run node

# 在另一个终端部署
npm run deploy:localhost
```

## 合约交互示例

### 创建验证者

```javascript
await posrStake.createValidator(
  "MyValidator",           // moniker
  "keybase:myidentity",    // identity
  "https://example.com",   // website
  "A reliable validator",  // details
  1000,                    // commission rate (10%)
  { value: ethers.parseEther("32") }
);
```

### 委托质押

```javascript
await posrStake.stake(
  validatorAddress,
  { value: ethers.parseEther("10") }
);
```

### 开始解质押

```javascript
await posrStake.startUnbonding(
  validatorAddress,
  ethers.parseEther("5")
);
```

### 领取奖励

```javascript
await posrStake.claimRewards(validatorAddress);
```

## 核心参数

| 参数 | 默认值 | 说明 |
|-----|--------|------|
| minStakeAmount | 32 ETH | 成为验证者的最低质押金额 |
| unbondingPeriod | 14 天 | 解质押锁定期 |
| jailPeriod | 7 天 | 监禁期 |
| maxCommissionRate | 20% | 验证者最高佣金率 |
| slashPercentage | 5% | 罚没比例 |

## 角色权限

| 角色 | 权限 |
|-----|------|
| DEFAULT_ADMIN_ROLE | 所有权限 |
| ADMIN_ROLE | 参数修改、暂停、添加奖励 |
| VALIDATOR_ROLE | 验证者操作 |
| SLASHER_ROLE | 罚没验证者 |
| UPGRADER_ROLE | 合约升级 |

## 安全考虑

1. **重入保护**: 所有涉及ETH转账的函数都使用 `nonReentrant` 修饰符
2. **检查-生效-交互**: 遵循 Checks-Effects-Interactions 模式
3. **代理安全**: 使用OpenZeppelin的UUPS代理实现
4. **访问控制**: 基于角色的细粒度权限管理
5. **输入验证**: 全面的参数验证和边界检查

## 许可证

MIT License

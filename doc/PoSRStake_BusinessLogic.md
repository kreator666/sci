# PoSRStake 合约业务逻辑解析

## 一、合约概览

**PoSR (Proof of Stake Rotation)** 质押合约是一个功能完整的验证者质押协议，实现了：
- 验证者注册与管理
- 原生 ETH 质押与委托
- 时间锁定的解质押机制
- 自动奖励分发
- 违规惩罚（罚没 + 监禁）

---

## 二、核心数据结构

### 2.1 验证者状态枚举

```solidity
enum ValidatorStatus {
    Inactive,      // 未激活（已退出）
    Active,        // 活跃验证者（可接受委托）
    Jailed,        // 被监禁（违规，暂时不可操作）
    Exiting        // 退出中（解质押过程中）
}
```

### 2.2 验证者结构 (Validator)

```
┌─────────────────────────────────────────────────────────┐
│  Validator (验证者)                                      │
├─────────────────────────────────────────────────────────┤
│  validatorAddress    │  验证者钱包地址                   │
│  stakedAmount        │  自身质押金额                     │
│  rewardDebt          │  奖励债务（用于计算已结算奖励）    │
│  accumulatedRewards  │  累积的待领取奖励                 │
│  lastUpdateTime      │  最后更新时间                     │
│  unbondingStartTime  │  解质押开始时间                   │
│  jailEndTime         │  监禁结束时间                     │
│  status              │  状态 (Inactive/Active/Jailed/Exiting) │
│  moniker             │  验证者名称                       │
│  identity            │  身份标识 (如 Keybase)            │
│  website             │  网站链接                         │
│  details             │  详细描述                         │
│  commissionRate      │  佣金率 (基点, 1000 = 10%)        │
│  totalDelegations    │  总委托金额（来自其他用户）        │
└─────────────────────────────────────────────────────────┘
```

### 2.3 委托结构 (Delegation)

```
┌─────────────────────────────────────────────────────────┐
│  Delegation (委托关系)                                   │
├─────────────────────────────────────────────────────────┤
│  amount              │  当前质押金额                     │
│  rewardDebt          │  奖励债务                         │
│  accumulatedRewards  │  累积的待领取奖励                 │
│  unbondingAmount     │  正在解质押的金额（锁定期中）      │
│  unbondingCompleteTime │ 解质押完成时间（可提取）         │
└─────────────────────────────────────────────────────────┘
```

**映射关系**：`mapping(验证者 => mapping(委托人 => Delegation))`

---

## 三、业务模块详解

### 3.1 验证者生命周期

```
                    ┌─────────────────┐
                    │   非验证者      │
                    └────────┬────────┘
                             │ createValidator()
                             │ (质押 ≥ 32 ETH)
                             ▼
                    ┌─────────────────┐
    ┌───────────────│     Active      │◄────────────────┐
    │               │   (活跃状态)     │                 │
    │               └────────┬────────┘                 │
    │                        │                         │
    │ stake() / startUnbonding() / jailSelf()          │
    │                        │                         │
    ▼                        ▼                         │
┌─────────┐          ┌───────────────┐         ┌──────┴─────┐
│  Jailed │          │   Exiting     │         │  完成退出   │
│ (被监禁) │          │  (退出中)      │         │  complete  │
└────┬────┘          └───────┬───────┘         │ Unbonding()│
     │                        │                └──────┬─────┘
     │ unjail()               │ 锁定期结束             │
     │ (监禁期后)              ▼                       │
     └─────────────────► Active / Inactive ◄──────────┘
```

#### 创建验证者 (createValidator)

```solidity
function createValidator(
    string calldata _moniker,        // 名称（必填）
    string calldata _identity,       // 身份标识
    string calldata _website,        // 网站
    string calldata _details,        // 描述
    uint256 _commissionRate          // 佣金率 ≤ 20%
) external payable
```

**前置条件**：
- 尚未是验证者
- 质押金额 ≥ `minStakeAmount`（默认 32 ETH）
- 佣金率 ≤ `maxCommissionRate`（默认 20%）
- 必须提供 moniker（名称）

**执行逻辑**：
1. 更新全局奖励状态
2. 创建验证者记录，标记状态为 `Active`
3. 计算初始 `rewardDebt`（避免立即获得历史奖励）
4. 授予 `VALIDATOR_ROLE`

---

### 3.2 质押机制

#### 委托质押 (stake)

```solidity
function stake(address _validator) external payable
```

**流程**：
```
用户调用 stake(validatorAddress, {value: 10 ETH})
           │
           ▼
    ┌──────────────┐
    │ 1. 更新全局奖励 │ ◄── _updateRewards()
    │   状态        │
    └──────┬───────┘
           │
           ▼
    ┌──────────────┐
    │ 2. 结算已有奖励 │ ◄── 如果有之前的质押
    │   (accumulated │     pending → accumulatedRewards
    │    Rewards += pending)
    └──────┬───────┘
           │
           ▼
    ┌──────────────┐
    │ 3. 更新质押金额 │ ◄── delegation.amount += msg.value
    │   重置债务    │     rewardDebt = amount * accRewardPerShare / 1e12
    └──────┬───────┘
           │
           ▼
    ┌──────────────┐
    │ 4. 更新验证者  │ ◄── validator.totalDelegations += msg.value
    │   总委托      │     totalStaked += msg.value
    └──────────────┘
```

#### 解质押流程 (Unbonding)

```solidity
// 第一步：开始解质押（启动锁定期）
function startUnbonding(address _validator, uint256 _amount)

// 第二步：完成解质押（锁定期后提取）
function completeUnbonding(address _validator)
```

**两阶段解质押设计原因**：
- 安全性：防止闪电贷攻击
- 共识安全：给网络时间处理验证者退出
- 资金冷却期：减少市场冲击

```
用户调用 startUnbonding(validator, 5 ETH)
           │
           ▼
    ┌──────────────────────┐
    │ 1. 结算待领取奖励      │
    │ 2. amount -= 5 ETH     │
    │ 3. unbondingAmount += 5 ETH
    │ 4. unbondingCompleteTime = now + 14 days
    └──────────┬───────────┘
               │
               │ 等待 14 天
               ▼
    用户调用 completeUnbonding(validator)
               │
               ▼
    ┌──────────────────────┐
    │ 1. 检查时间是否到达    │
    │ 2. unbondingAmount = 0 │
    │ 3. 转账 5 ETH 给用户   │
    └──────────────────────┘
```

---

### 3.3 奖励系统

#### 奖励计算模型：债务机制 (Debt Pattern)

```
全局状态：
  - accRewardPerShare: 每份额累积奖励 (精度 1e12)
  - rewardPerSecond: 每秒奖励率
  - totalStaked: 总质押金额
  - totalRewardPool: 奖励池余额

用户债务机制：
  rewardDebt = amount * accRewardPerShare_at_stake_time / 1e12
  
  待领取奖励 = amount * current_accRewardPerShare / 1e12 - rewardDebt
```

**类比理解**：
> 想象一个不断增长的"奖励蛋糕"（accRewardPerShare），每个质押者在入场时记下蛋糕的高度（rewardDebt）。当要计算收益时，用当前蛋糕高度减去入场时的高度，就是应得的份额。

#### 奖励更新流程

```solidity
function _updateRewards() internal {
    // 时间差
    uint256 timeElapsed = block.timestamp - lastRewardUpdateTime;
    
    // 新产生的奖励
    uint256 reward = timeElapsed * rewardPerSecond;
    
    // 更新每份额累积奖励
    accRewardPerShare += (reward * 1e12) / totalStaked;
}
```

#### 奖励分发流程图

```
管理员调用 addRewards() {value: 100 ETH}
           │
           ▼
    ┌──────────────┐
    │ totalRewardPool += 100 ETH
    └──────┬───────┘
           │
           ▼
时间流逝 ──────────────────────────────►
           │
    用户A stake(10 ETH)       用户B stake(20 ETH)
           │                           │
           ▼                           ▼
    rewardDebt = 10 * acc      rewardDebt = 20 * acc
           │                           │
           ▼                           ▼
时间再流逝 ────────────────────────────►
           │
    accRewardPerShare 增长
           │
    用户A claimRewards()      用户B claimRewards()
           │                           │
           ▼                           ▼
    pending = 10 * new_acc    pending = 20 * new_acc
            - 10 * old_acc              - 20 * old_acc
           │                           │
           ▼                           ▼
    按质押比例分配奖励
```

---

### 3.4 惩罚机制 (Slashing)

#### 违规处理流程

```
检测到违规行为（如双重签名、离线过久）
           │
           ▼
    Slasher 调用 slashValidator(validator, "原因")
           │
           ├──────────────────────────────────────────┐
           ▼                                          ▼
    ┌──────────────┐                          ┌──────────────┐
    │  罚没资金     │                          │   监禁处理    │
    │              │                          │              │
    │ slashAmount =│                          │ status =     │
    │ stake * 5%   │                          │ Jailed       │
    │              │                          │              │
    │ 罚没金额进入 │                          │ jailEndTime =│
    │ 奖励池       │                          │ now + 7 days │
    └──────────────┘                          └──────────────┘
           │                                          │
           └──────────────────┬───────────────────────┘
                              ▼
                    emit ValidatorSlashed()
                    emit ValidatorJailed()
```

#### 监禁与恢复

```
验证者被监禁 (Jailed)
           │
           │ 等待 jailPeriod（默认 7 天）
           ▼
    验证者调用 unjail()
           │
           ▼
    检查：block.timestamp >= jailEndTime ?
           │
           ├─ Yes ─► status = Active（恢复活跃）
           │
           └─ No ──► Revert（仍需等待）
```

---

## 四、访问控制矩阵

| 功能 | ADMIN | VALIDATOR | SLASHER | 普通用户 |
|-----|-------|-----------|---------|----------|
| createValidator | ✓ | ✓ | ✓ | ✓ |
| stake | ✓ | ✓ | ✓ | ✓ |
| startUnbonding | ✓ | ✓ | ✓ | ✓ |
| completeUnbonding | ✓ | ✓ | ✓ | ✓ |
| claimRewards | ✓ | ✓ | ✓ | ✓ |
| updateValidatorInfo | - | ✓(自己) | - | - |
| jailSelf | - | ✓(自己) | - | - |
| unjail | - | ✓(自己) | - | - |
| addRewards | ✓ | - | - | - |
| slashValidator | - | - | ✓ | - |
| jailValidator | ✓ | - | - | - |
| updateParameters | ✓ | - | - | - |
| pause/unpause | ✓ | - | - | - |
| upgradeContract | - | - | - | UPGRADER |

---

## 五、关键参数默认值

| 参数 | 默认值 | 说明 | 可修改 |
|-----|--------|------|--------|
| minStakeAmount | 32 ETH | 成为验证者最低要求 | 管理员可修改 |
| unbondingPeriod | 14 天 | 解质押锁定期 | 管理员可修改 |
| jailPeriod | 7 天 | 监禁期 | 管理员可修改 |
| maxCommissionRate | 20% | 验证者最高佣金率 | 代码固定 |
| slashPercentage | 5% | 罚没比例 | 管理员可修改 |
| rewardPerSecond | 0 | 每秒奖励率 | 管理员可设置 |

---

## 六、安全机制

### 6.1 重入保护 (ReentrancyGuard)

```solidity
function claimRewards() external nonReentrant {
    // 所有涉及 ETH 转账的函数都使用 nonReentrant
}
```

### 6.2 检查-生效-交互 (Checks-Effects-Interactions)

```solidity
function completeUnbonding(address _validator) external nonReentrant {
    // 1. 检查 (Checks)
    require(d.unbondingAmount > 0, "...");
    require(block.timestamp >= d.unbondingCompleteTime, "...");
    
    // 2. 生效 (Effects) - 先修改状态
    uint256 amount = d.unbondingAmount;
    d.unbondingAmount = 0;
    d.unbondingCompleteTime = 0;
    
    // 3. 交互 (Interactions) - 最后转账
    (bool success, ) = payable(msg.sender).call{value: amount}("");
    require(success, "...");
}
```

### 6.3 紧急暂停 (Pausable)

```solidity
// 关键函数都有 whenNotPaused 修饰符
function stake() external whenNotPaused { ... }
function createValidator() external whenNotPaused { ... }

// 管理员可暂停
function pause() external onlyRole(ADMIN_ROLE)
function unpause() external onlyRole(ADMIN_ROLE)
```

---

## 七、业务流程完整示例

### 场景：Alice 成为验证者，Bob 委托给 Alice

```
时间线：
═══════════════════════════════════════════════════════════════

T0: 部署合约
    ├─ 管理员部署 PoSRStake 实现合约
    └─ 通过 Factory 创建代理合约
        minStakeAmount = 32 ETH
        unbondingPeriod = 14 days

───────────────────────────────────────────────────────────────

T1: Alice 创建验证者
    Alice 调用 createValidator("AliceNode", ..., 10%) {value: 32 ETH}
    ├─ 验证者状态: Active
    ├─ stakedAmount: 32 ETH
    └─ commissionRate: 10%

───────────────────────────────────────────────────────────────

T2: Bob 委托给 Alice
    Bob 调用 stake(Alice) {value: 100 ETH}
    ├─ delegations[Alice][Bob].amount = 100 ETH
    └─ validators[Alice].totalDelegations = 100 ETH

───────────────────────────────────────────────────────────────

T3: 管理员添加奖励
    Admin 调用 addRewards() {value: 1000 ETH}
    └─ totalRewardPool = 1000 ETH

    Admin 调用 setRewardPerSecond(0.001 ETH/秒)

───────────────────────────────────────────────────────────────

T4: 时间流逝（1小时后）
    总质押 = 132 ETH (Alice 32 + Bob 100)
    产生奖励 = 3600秒 × 0.001 = 3.6 ETH
    
    Alice 应得 = 3.6 × (32/132) = 0.87 ETH
    Bob 应得 = 3.6 × (100/132) = 2.73 ETH

───────────────────────────────────────────────────────────────

T5: Bob 领取奖励
    Bob 调用 claimRewards(Alice)
    └─ Bob 收到 2.73 ETH

───────────────────────────────────────────────────────────────

T6: Alice 违规被惩罚
    Slasher 调用 slashValidator(Alice, "Double signing")
    ├─ 罚没金额 = 32 × 5% = 1.6 ETH
    ├─ Alice.stakedAmount = 30.4 ETH
    ├─ totalRewardPool += 1.6 ETH
    └─ Alice 状态 = Jailed (监禁 7 天)

───────────────────────────────────────────────────────────────

T7: Bob 开始解质押
    Bob 调用 startUnbonding(Alice, 50 ETH)
    ├─ delegations[Alice][Bob].amount = 50 ETH
    ├─ delegations[Alice][Bob].unbondingAmount = 50 ETH
    └─ unbondingCompleteTime = T7 + 14 天

───────────────────────────────────────────────────────────────

T8: 7 天后，Alice 解除监禁
    Alice 调用 unjail()
    └─ Alice 状态 = Active

───────────────────────────────────────────────────────────────

T9: 14 天后，Bob 完成解质押
    Bob 调用 completeUnbonding(Alice)
    └─ Bob 收到 50 ETH

═══════════════════════════════════════════════════════════════
```

---

## 八、总结

PoSRStake 合约实现了完整的 PoS 质押协议，具有以下特点：

| 特性 | 实现方式 |
|-----|---------|
| **双角色模型** | 验证者 + 委托人的经典 PoS 结构 |
| **时间锁定** | 14 天解质押期保障网络安全 |
| **债务机制** | 高效的奖励计算，避免循环遍历 |
| **弹性惩罚** | 可配置的罚没比例和监禁期 |
| **可升级** | UUPS 代理模式支持合约迭代 |
| **多签安全** | 基于角色的权限管理 |

---

*文档生成时间: 2026-03-30*
*对应合约版本: PoSR Staking Protocol v1.0.0*

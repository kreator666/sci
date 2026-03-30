# Project Overview

## Status

This is a **Solidity smart contract project** implementing a PoSR (Proof of Stake Rotation) staking protocol.

- **Technology**: Solidity ^0.8.20, Hardhat, OpenZeppelin
- **Framework**: Hardhat with TypeScript
- **Proxy Pattern**: UUPS Upgradeable
- **License**: MIT

## Project Structure

```
contracts/
├── PoSRStake.sol          # Main staking contract
└── PoSRStakeFactory.sol   # Factory for deploying instances

scripts/
└── deploy.ts              # Deployment script

test/
└── PoSRStake.test.ts      # Test suite
```

## Core Features

1. **Validator Management**: Registration with metadata, commission rates
2. **Staking**: Native ETH staking with delegation support
3. **Unbonding**: Time-locked unstaking (default 14 days)
4. **Rewards**: Auto-calculated rewards based on stake and time
5. **Slashing**: Penalty system for misbehavior (5% slash + 7-day jail)

## Key Parameters

| Parameter | Default Value |
|-----------|---------------|
| minStakeAmount | 32 ETH |
| unbondingPeriod | 14 days |
| jailPeriod | 7 days |
| maxCommissionRate | 20% |
| slashPercentage | 5% |

## Build & Test

```bash
npm install
npm run compile
npm test
```

## Deployment

```bash
# Local
npm run node
npm run deploy:localhost

# Testnet (configure .env first)
npm run deploy:sepolia
```

## 注意事项
agent不许读取.env中的数据内容

## Last Updated

2026-03-29

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

/**
 * @title PoSRStake
 * @notice Proof of Stake Rotation 质押合约
 * @dev 实现验证者的质押、解质押、奖励分发和罚没机制
 */
contract PoSRStake is 
    Initializable,
    AccessControlUpgradeable,
    ReentrancyGuardUpgradeable,
    PausableUpgradeable,
    UUPSUpgradeable 
{
    // ============ 角色定义 ============
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 public constant VALIDATOR_ROLE = keccak256("VALIDATOR_ROLE");
    bytes32 public constant SLASHER_ROLE = keccak256("SLASHER_ROLE");
    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");

    // ============ 状态枚举 ============
    enum ValidatorStatus {
        Inactive,      // 未激活
        Active,        // 活跃验证者
        Jailed,        // 被监禁（违规）
        Exiting        // 退出中
    }

    // ============ 数据结构 ============
    struct Validator {
        address validatorAddress;     // 验证者地址
        uint256 stakedAmount;         // 质押金额
        uint256 rewardDebt;           // 奖励债务（用于计算）
        uint256 accumulatedRewards;   // 累积的奖励
        uint256 lastUpdateTime;       // 最后更新时间
        uint256 unbondingStartTime;   // 解质押开始时间
        uint256 jailEndTime;          // 监禁结束时间
        ValidatorStatus status;       // 验证者状态
        string moniker;               // 验证者名称
        string identity;              // 验证者身份（可选，如Keybase）
        string website;               // 验证者网站
        string details;               // 详细描述
        uint256 commissionRate;       // 佣金率（基点，如1000 = 10%）
        uint256 totalDelegations;     // 总委托金额
    }

    struct Delegation {
        uint256 amount;               // 委托金额
        uint256 rewardDebt;           // 奖励债务
        uint256 unbondingAmount;      // 正在解质押的金额
        uint256 unbondingCompleteTime; // 解质押完成时间
    }

    // ============ 状态变量 ============
    // 验证者映射
    mapping(address => Validator) public validators;
    address[] public validatorList;
    mapping(address => bool) public isValidator;

    // 委托映射: 验证者 => 委托人 => 委托信息
    mapping(address => mapping(address => Delegation)) public delegations;

    // 全局参数
    uint256 public minStakeAmount;           // 最小质押金额
    uint256 public unbondingPeriod;          // 解质押锁定期（秒）
    uint256 public jailPeriod;               // 监禁期（秒）
    uint256 public maxCommissionRate;        // 最大佣金率（基点）
    uint256 public slashPercentage;          // 罚没比例（基点）
    uint256 public rewardPerSecond;          // 每秒奖励率（每单位质押）
    uint256 public lastRewardUpdateTime;     // 最后奖励更新时间
    uint256 public accRewardPerShare;        // 每份额累积奖励（精度1e12）
    uint256 public totalStaked;              // 总质押金额
    uint256 public totalRewardPool;          // 奖励池总额
    uint256 public constant REWARD_PRECISION = 1e12;
    uint256 public constant BASIS_POINTS = 10000;

    // ============ 事件 ============
    event ValidatorCreated(
        address indexed validator,
        string moniker,
        uint256 commissionRate,
        uint256 amount
    );
    event ValidatorUpdated(
        address indexed validator,
        string moniker,
        string website,
        string details
    );
    event Staked(address indexed validator, address indexed delegator, uint256 amount);
    event UnbondingStarted(
        address indexed validator,
        address indexed delegator,
        uint256 amount,
        uint256 completeTime
    );
    event UnbondingCompleted(
        address indexed validator,
        address indexed delegator,
        uint256 amount
    );
    event RewardsClaimed(
        address indexed validator,
        address indexed delegator,
        uint256 amount
    );
    event ValidatorSlashed(
        address indexed validator,
        uint256 amount,
        string reason
    );
    event ValidatorJailed(address indexed validator, uint256 jailEndTime);
    event ValidatorUnjailed(address indexed validator);
    event ValidatorExited(address indexed validator);
    event RewardsDistributed(uint256 amount);
    event ParametersUpdated(
        uint256 minStakeAmount,
        uint256 unbondingPeriod,
        uint256 jailPeriod
    );

    // ============ 修饰符 ============
    modifier onlyValidator() {
        require(isValidator[msg.sender], "PoSR: not a validator");
        _;
    }

    modifier onlyActiveValidator(address _validator) {
        require(validators[_validator].status == ValidatorStatus.Active, "PoSR: validator not active");
        _;
    }

    modifier nonJailed(address _validator) {
        require(
            validators[_validator].status != ValidatorStatus.Jailed ||
            block.timestamp >= validators[_validator].jailEndTime,
            "PoSR: validator is jailed"
        );
        _;
    }

    // ============ 初始化函数 ============
    function initialize(
        uint256 _minStakeAmount,
        uint256 _unbondingPeriod,
        uint256 _jailPeriod
    ) public initializer {
        __AccessControl_init();
        __ReentrancyGuard_init();
        __Pausable_init();
        __UUPSUpgradeable_init();

        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(ADMIN_ROLE, msg.sender);
        _grantRole(UPGRADER_ROLE, msg.sender);

        minStakeAmount = _minStakeAmount;
        unbondingPeriod = _unbondingPeriod;
        jailPeriod = _jailPeriod;
        maxCommissionRate = 2000;  // 默认最大20%
        slashPercentage = 500;     // 默认罚没5%
        lastRewardUpdateTime = block.timestamp;
    }

    // ============ 外部函数 ============

    /**
     * @notice 创建验证者并质押
     * @param _moniker 验证者名称
     * @param _identity 验证者身份标识
     * @param _website 验证者网站
     * @param _details 详细描述
     * @param _commissionRate 佣金率（基点）
     */
    function createValidator(
        string calldata _moniker,
        string calldata _identity,
        string calldata _website,
        string calldata _details,
        uint256 _commissionRate
    ) external payable nonReentrant whenNotPaused {
        require(!isValidator[msg.sender], "PoSR: already a validator");
        require(msg.value >= minStakeAmount, "PoSR: insufficient stake amount");
        require(_commissionRate <= maxCommissionRate, "PoSR: commission rate too high");
        require(bytes(_moniker).length > 0, "PoSR: moniker required");

        // 更新奖励
        _updateRewards();

        // 创建验证者
        Validator storage v = validators[msg.sender];
        v.validatorAddress = msg.sender;
        v.stakedAmount = msg.value;
        v.lastUpdateTime = block.timestamp;
        v.status = ValidatorStatus.Active;
        v.moniker = _moniker;
        v.identity = _identity;
        v.website = _website;
        v.details = _details;
        v.commissionRate = _commissionRate;
        v.rewardDebt = (msg.value * accRewardPerShare) / REWARD_PRECISION;

        isValidator[msg.sender] = true;
        validatorList.push(msg.sender);
        totalStaked += msg.value;

        _grantRole(VALIDATOR_ROLE, msg.sender);

        emit ValidatorCreated(msg.sender, _moniker, _commissionRate, msg.value);
    }

    /**
     * @notice 更新验证者信息
     */
    function updateValidatorInfo(
        string calldata _moniker,
        string calldata _website,
        string calldata _details
    ) external onlyValidator {
        Validator storage v = validators[msg.sender];
        v.moniker = _moniker;
        v.website = _website;
        v.details = _details;

        emit ValidatorUpdated(msg.sender, _moniker, _website, _details);
    }

    /**
     * @notice 质押到验证者
     * @param _validator 验证者地址
     */
    function stake(address _validator) 
        external 
        payable 
        nonReentrant 
        whenNotPaused 
        onlyActiveValidator(_validator)
        nonJailed(_validator)
    {
        require(msg.value > 0, "PoSR: stake amount must be > 0");

        _updateRewards();

        Validator storage v = validators[_validator];
        Delegation storage d = delegations[_validator][msg.sender];

        // 先结算已有奖励
        if (d.amount > 0) {
            uint256 pending = _calculatePendingRewards(_validator, msg.sender);
            if (pending > 0) {
                d.accumulatedRewards += pending;
            }
        }

        // 更新质押金额
        d.amount += msg.value;
        d.rewardDebt = (d.amount * accRewardPerShare) / REWARD_PRECISION;
        
        v.totalDelegations += msg.value;
        totalStaked += msg.value;

        emit Staked(_validator, msg.sender, msg.value);
    }

    /**
     * @notice 开始解质押
     * @param _validator 验证者地址
     * @param _amount 解质押金额
     */
    function startUnbonding(
        address _validator, 
        uint256 _amount
    ) external nonReentrant onlyActiveValidator(_validator) {
        Delegation storage d = delegations[_validator][msg.sender];
        require(d.amount >= _amount, "PoSR: insufficient staked amount");
        require(_amount > 0, "PoSR: unbonding amount must be > 0");

        _updateRewards();

        // 结算待领取奖励
        uint256 pending = _calculatePendingRewards(_validator, msg.sender);
        if (pending > 0) {
            d.accumulatedRewards += pending;
        }

        // 更新质押和解质押金额
        d.amount -= _amount;
        d.unbondingAmount += _amount;
        d.unbondingCompleteTime = block.timestamp + unbondingPeriod;
        d.rewardDebt = (d.amount * accRewardPerShare) / REWARD_PRECISION;

        Validator storage v = validators[_validator];
        v.totalDelegations -= _amount;

        // 如果是验证者自己解质押且低于最小值，标记为退出
        if (msg.sender == _validator && d.amount < minStakeAmount) {
            v.status = ValidatorStatus.Exiting;
        }

        emit UnbondingStarted(_validator, msg.sender, _amount, d.unbondingCompleteTime);
    }

    /**
     * @notice 完成解质押并提取资金
     * @param _validator 验证者地址
     */
    function completeUnbonding(address _validator) external nonReentrant {
        Delegation storage d = delegations[_validator][msg.sender];
        require(d.unbondingAmount > 0, "PoSR: no unbonding amount");
        require(
            block.timestamp >= d.unbondingCompleteTime,
            "PoSR: unbonding period not complete"
        );

        uint256 amount = d.unbondingAmount;
        d.unbondingAmount = 0;
        d.unbondingCompleteTime = 0;

        // 检查是否是验证者完全退出
        Validator storage v = validators[_validator];
        if (msg.sender == _validator && v.status == ValidatorStatus.Exiting) {
            _exitValidator(_validator);
        }

        // 转账
        (bool success, ) = payable(msg.sender).call{value: amount}("");
        require(success, "PoSR: transfer failed");

        emit UnbondingCompleted(_validator, msg.sender, amount);
    }

    /**
     * @notice 领取奖励
     * @param _validator 验证者地址
     */
    function claimRewards(address _validator) external nonReentrant {
        _updateRewards();

        Delegation storage d = delegations[_validator][msg.sender];
        uint256 pending = _calculatePendingRewards(_validator, msg.sender);
        
        uint256 totalRewards = pending + d.accumulatedRewards;
        require(totalRewards > 0, "PoSR: no rewards to claim");
        require(totalRewards <= totalRewardPool, "PoSR: insufficient reward pool");

        // 重置奖励
        d.accumulatedRewards = 0;
        d.rewardDebt = (d.amount * accRewardPerShare) / REWARD_PRECISION;

        totalRewardPool -= totalRewards;

        // 转账
        (bool success, ) = payable(msg.sender).call{value: totalRewards}("");
        require(success, "PoSR: reward transfer failed");

        emit RewardsClaimed(_validator, msg.sender, totalRewards);
    }

    /**
     * @notice 验证者自监禁（主动退出）
     */
    function jailSelf() external onlyValidator {
        _jailValidator(msg.sender, "Self jailed");
    }

    /**
     * @notice 解除监禁（监禁期结束后）
     */
    function unjail() external onlyValidator {
        Validator storage v = validators[msg.sender];
        require(v.status == ValidatorStatus.Jailed, "PoSR: not jailed");
        require(block.timestamp >= v.jailEndTime, "PoSR: jail period not complete");
        
        v.status = ValidatorStatus.Active;
        v.jailEndTime = 0;

        emit ValidatorUnjailed(msg.sender);
    }

    /**
     * @notice 获取待领取奖励
     */
    function getPendingRewards(
        address _validator, 
        address _delegator
    ) external view returns (uint256) {
        uint256 pending = _calculatePendingRewards(_validator, _delegator);
        Delegation storage d = delegations[_validator][_delegator];
        return pending + d.accumulatedRewards;
    }

    // ============ 管理员函数 ============

    /**
     * @notice 添加奖励到奖励池
     */
    function addRewards() external payable onlyRole(ADMIN_ROLE) {
        require(msg.value > 0, "PoSR: reward must be > 0");
        totalRewardPool += msg.value;
        emit RewardsDistributed(msg.value);
    }

    /**
     * @notice 罚没验证者（由Slasher调用）
     */
    function slashValidator(
        address _validator,
        string calldata _reason
    ) external onlyRole(SLASHER_ROLE) onlyActiveValidator(_validator) {
        _updateRewards();

        Validator storage v = validators[_validator];
        uint256 slashAmount = (v.stakedAmount * slashPercentage) / BASIS_POINTS;
        
        v.stakedAmount -= slashAmount;
        totalStaked -= slashAmount;
        totalRewardPool += slashAmount; // 罚没的代币进入奖励池

        // 监禁验证者
        _jailValidator(_validator, _reason);

        emit ValidatorSlashed(_validator, slashAmount, _reason);
    }

    /**
     * @notice 监禁验证者
     */
    function jailValidator(address _validator) external onlyRole(ADMIN_ROLE) {
        _jailValidator(_validator, "Admin jailed");
    }

    /**
     * @notice 更新参数
     */
    function updateParameters(
        uint256 _minStakeAmount,
        uint256 _unbondingPeriod,
        uint256 _jailPeriod
    ) external onlyRole(ADMIN_ROLE) {
        minStakeAmount = _minStakeAmount;
        unbondingPeriod = _unbondingPeriod;
        jailPeriod = _jailPeriod;

        emit ParametersUpdated(_minStakeAmount, _unbondingPeriod, _jailPeriod);
    }

    /**
     * @notice 更新奖励率
     */
    function setRewardPerSecond(uint256 _rewardPerSecond) external onlyRole(ADMIN_ROLE) {
        _updateRewards();
        rewardPerSecond = _rewardPerSecond;
    }

    /**
     * @notice 更新罚没比例
     */
    function setSlashPercentage(uint256 _slashPercentage) external onlyRole(ADMIN_ROLE) {
        require(_slashPercentage <= BASIS_POINTS, "PoSR: invalid percentage");
        slashPercentage = _slashPercentage;
    }

    /**
     * @notice 暂停合约
     */
    function pause() external onlyRole(ADMIN_ROLE) {
        _pause();
    }

    /**
     * @notice 恢复合约
     */
    function unpause() external onlyRole(ADMIN_ROLE) {
        _unpause();
    }

    // ============ 内部函数 ============

    /**
     * @notice 更新奖励累积
     */
    function _updateRewards() internal {
        if (block.timestamp <= lastRewardUpdateTime || totalStaked == 0) {
            lastRewardUpdateTime = block.timestamp;
            return;
        }

        uint256 timeElapsed = block.timestamp - lastRewardUpdateTime;
        uint256 reward = timeElapsed * rewardPerSecond;

        if (reward > 0 && totalRewardPool >= reward) {
            accRewardPerShare += (reward * REWARD_PRECISION) / totalStaked;
        }

        lastRewardUpdateTime = block.timestamp;
    }

    /**
     * @notice 计算待领取奖励
     */
    function _calculatePendingRewards(
        address _validator,
        address _delegator
    ) internal view returns (uint256) {
        Delegation storage d = delegations[_validator][_delegator];
        if (d.amount == 0) return 0;

        uint256 currentAccReward = accRewardPerShare;
        
        // 如果有新的奖励未更新，计算最新的accRewardPerShare
        if (block.timestamp > lastRewardUpdateTime && totalStaked > 0) {
            uint256 timeElapsed = block.timestamp - lastRewardUpdateTime;
            uint256 reward = timeElapsed * rewardPerSecond;
            if (totalRewardPool >= reward) {
                currentAccReward += (reward * REWARD_PRECISION) / totalStaked;
            }
        }

        return (d.amount * currentAccReward) / REWARD_PRECISION - d.rewardDebt;
    }

    /**
     * @notice 监禁验证者
     */
    function _jailValidator(address _validator, string memory _reason) internal {
        Validator storage v = validators[_validator];
        v.status = ValidatorStatus.Jailed;
        v.jailEndTime = block.timestamp + jailPeriod;

        emit ValidatorJailed(_validator, v.jailEndTime);
    }

    /**
     * @notice 验证者完全退出
     */
    function _exitValidator(address _validator) internal {
        Validator storage v = validators[_validator];
        v.status = ValidatorStatus.Inactive;
        isValidator[_validator] = false;
        _revokeRole(VALIDATOR_ROLE, _validator);

        emit ValidatorExited(_validator);
    }

    /**
     * @notice 授权升级
     */
    function _authorizeUpgrade(address newImplementation) internal override onlyRole(UPGRADER_ROLE) {}

    // ============ 查询函数 ============

    /**
     * @notice 获取验证者数量
     */
    function getValidatorCount() external view returns (uint256) {
        return validatorList.length;
    }

    /**
     * @notice 获取验证者列表
     */
    function getValidators(uint256 _offset, uint256 _limit) 
        external 
        view 
        returns (address[] memory) 
    {
        uint256 end = _offset + _limit;
        if (end > validatorList.length) {
            end = validatorList.length;
        }
        require(_offset < end, "PoSR: invalid pagination");

        address[] memory result = new address[](end - _offset);
        for (uint256 i = _offset; i < end; i++) {
            result[i - _offset] = validatorList[i];
        }
        return result;
    }

    /**
     * @notice 获取活跃验证者数量
     */
    function getActiveValidatorCount() external view returns (uint256) {
        uint256 count = 0;
        for (uint256 i = 0; i < validatorList.length; i++) {
            if (validators[validatorList[i]].status == ValidatorStatus.Active) {
                count++;
            }
        }
        return count;
    }

    /**
     * @notice 获取委托信息
     */
    function getDelegation(
        address _validator, 
        address _delegator
    ) external view returns (Delegation memory) {
        return delegations[_validator][_delegator];
    }

    /**
     * @notice 获取合约ETH余额
     */
    function getContractBalance() external view returns (uint256) {
        return address(this).balance;
    }

    receive() external payable {
        totalRewardPool += msg.value;
    }
}

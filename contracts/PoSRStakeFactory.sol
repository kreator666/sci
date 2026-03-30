// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "./PoSRStake.sol";

/**
 * @title PoSRStakeFactory
 * @notice PoSR质押合约工厂，用于部署新的质押合约实例
 */
contract PoSRStakeFactory {
    
    // 角色定义
    bytes32 public constant DEFAULT_ADMIN_ROLE = 0x0000000000000000000000000000000000000000000000000000000000000000;
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");
    
    // 实现合约地址
    address public implementation;
    
    // 记录所有部署的合约
    address[] public deployedContracts;
    mapping(address => bool) public isDeployedContract;
    
    // 事件
    event ContractDeployed(
        address indexed proxy,
        address indexed implementation,
        uint256 minStakeAmount,
        uint256 unbondingPeriod,
        uint256 jailPeriod,
        address admin
    );
    
    constructor(address _implementation) {
        require(_implementation != address(0), "Factory: zero implementation");
        implementation = _implementation;
    }
    
    /**
     * @notice 部署新的PoSR质押合约
     */
    function deployPoSRStake(
        uint256 _minStakeAmount,
        uint256 _unbondingPeriod,
        uint256 _jailPeriod,
        address _admin
    ) external returns (address proxy) {
        require(_admin != address(0), "Factory: zero admin");
        
        // 准备初始化数据
        bytes memory initData = abi.encodeWithSelector(
            PoSRStake.initialize.selector,
            _minStakeAmount,
            _unbondingPeriod,
            _jailPeriod
        );
        
        // 部署代理合约
        ERC1967Proxy proxyContract = new ERC1967Proxy(
            implementation,
            initData
        );
        
        proxy = address(proxyContract);
        PoSRStake posrStake = PoSRStake(payable(proxy));
        
        // 转移管理员权限
        if (_admin != address(this)) {
            posrStake.grantRole(ADMIN_ROLE, _admin);
            posrStake.grantRole(UPGRADER_ROLE, _admin);
            posrStake.grantRole(DEFAULT_ADMIN_ROLE, _admin);
            
            // 撤销工厂的权限
            posrStake.renounceRole(DEFAULT_ADMIN_ROLE, address(this));
            posrStake.renounceRole(ADMIN_ROLE, address(this));
            posrStake.renounceRole(UPGRADER_ROLE, address(this));
        }
        
        deployedContracts.push(proxy);
        isDeployedContract[proxy] = true;
        
        emit ContractDeployed(
            proxy,
            implementation,
            _minStakeAmount,
            _unbondingPeriod,
            _jailPeriod,
            _admin
        );
        
        return proxy;
    }
    
    /**
     * @notice 更新实现合约地址
     */
    function updateImplementation(address _newImplementation) external {
        require(_newImplementation != address(0), "Factory: zero address");
        require(_newImplementation != implementation, "Factory: same implementation");
        implementation = _newImplementation;
    }
    
    /**
     * @notice 获取部署的合约数量
     */
    function getDeployedCount() external view returns (uint256) {
        return deployedContracts.length;
    }
    
    /**
     * @notice 获取部署的合约列表
     */
    function getDeployedContracts(uint256 _offset, uint256 _limit) 
        external 
        view 
        returns (address[] memory) 
    {
        uint256 end = _offset + _limit;
        if (end > deployedContracts.length) {
            end = deployedContracts.length;
        }
        require(_offset < end, "Factory: invalid pagination");
        
        address[] memory result = new address[](end - _offset);
        for (uint256 i = _offset; i < end; i++) {
            result[i - _offset] = deployedContracts[i];
        }
        return result;
    }
}

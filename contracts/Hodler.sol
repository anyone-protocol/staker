// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts/utils/structs/EnumerableMap.sol";

interface IHodler {
    function version() external pure returns (uint8);
}

/// @title Hodler - ANyONe Protocol
/// @notice Interfaces token: rewards, locking, staking, and governance
/// @dev UUPS upgradeable pattern with role-based access control

contract Hodler is
    Initializable,
    PausableUpgradeable,
    AccessControlUpgradeable,
    UUPSUpgradeable,
    ReentrancyGuardUpgradeable
{
    using SafeMath for uint256;
    using EnumerableMap for EnumerableMap.AddressToUintMap;
    
    uint8 public constant VERSION = 1;

    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");
    bytes32 public constant CONTROLLER_ROLE = keccak256("CONTROLLER_ROLE");

    IERC20 public tokenContract;
    address payable public controllerAddress;
    address public rewardsPoolAddress;

    uint256 public LOCK_SIZE;
    uint256 public LOCK_DURATION; 
    uint256 public STAKE_DURATION;
    uint256 public GOVERNANCE_DURATION;

    uint256 private constant MINUTE = 60;
    uint256 private constant HOUR = 60 * MINUTE;
    uint256 private constant DAY = 24 * HOUR;
    uint256 private constant WEEK = 7 * DAY;
    uint256 private constant MONTH = 30 * DAY;
    
    // Minimum buffer to prevent miner manipulation by ensuring that the timestamp
    // used in the contract is not too close to the current block time, which could
    // be influenced by miners to gain an advantage.
    uint256 private constant TIMESTAMP_BUFFER = 15 * MINUTE;

    struct Vault {
        uint256 amount;
        uint256 availableAt;
    }

    struct HodlerData {
        uint256 available;
        Vault[] vaults;
        
        mapping(string => uint256) locks; // relay fingerprint => amount
        mapping(address => uint256) stakes; // operator address => amount
        uint256 votes;
        uint256 gas;
    }
    
    mapping(address => HodlerData) public hodlers;
    
    event Locked(address indexed hodler, string fingerprint, uint256 amount);
    event Unlocked(address indexed hodler, string fingerprint, uint256 amount);

    event Staked(address indexed hodler, address indexed operator, uint256 amount);
    event Unstaked(address indexed hodler, address indexed operator, uint256 amount);

    event AddedVotes(address indexed hodler, uint256 amount);
    event RemovedVotes(address indexed hodler, uint256 amount);
    
    event Vaulted(address indexed hodler, uint256 amount, uint256 availableAt);
    
    event UpdateRewards(address indexed hodler, uint256 gasEstimate, bool redeem);
    event Rewarded(address indexed hodler, uint256 amount, bool redeemed);

    event Withdrawn(address indexed hodler, uint256 amount);
    
    event LockSizeUpdated(address indexed controller, uint256 oldValue, uint256 newValue);
    event LockDurationUpdated(address indexed controller, uint256 oldValue, uint256 newValue);
    event StakeDurationUpdated(address indexed controller, uint256 oldValue, uint256 newValue);
    event GovernanceDurationUpdated(address indexed controller, uint256 oldValue, uint256 newValue);

    event HodlerInitialized(
        address tokenAddress,
        address controller,
        uint256 lockSize,
        uint256 lockDuration,
        uint256 stakeDuration,
        uint256 governanceDuration
    );

    function lock(string calldata fingerprint) external whenNotPaused nonReentrant {
        uint256 fingerprintLength = bytes(fingerprint).length;
        require(fingerprintLength > 0, "Fingerprint must have non 0 characters");
        require(fingerprintLength <= 40, "Fingerprint must have 40 or less characters");
        
        if (hodlers[_msgSender()].available >= LOCK_SIZE) {
            hodlers[_msgSender()].available = hodlers[_msgSender()].available.sub(LOCK_SIZE);
        } else {
            require(tokenContract.transferFrom(_msgSender(), address(this), LOCK_SIZE), 
                    "Transfer of tokens for the lock failed");
        }

        hodlers[_msgSender()].locks[fingerprint] = hodlers[_msgSender()].locks[fingerprint].add(LOCK_SIZE);
        emit Locked(_msgSender(), fingerprint, LOCK_SIZE);
    }

    function unlock(string calldata fingerprint) external whenNotPaused nonReentrant {        
        uint256 fingerprintLength = bytes(fingerprint).length;
        require(fingerprintLength > 0, "Fingerprint must have non 0 characters");
        require(fingerprintLength <= 40, "Fingerprint must have 40 or less characters");

        uint256 lockAmount = hodlers[_msgSender()].locks[fingerprint];
        require(lockAmount > 0, "No lock found for the fingerprint");
        
        delete hodlers[_msgSender()].locks[fingerprint];
        emit Unlocked(_msgSender(), fingerprint, lockAmount);

        uint256 availableAt = block.timestamp + LOCK_DURATION;
        hodlers[_msgSender()].vaults.push(Vault(lockAmount, availableAt));
        emit Vaulted(_msgSender(), lockAmount, availableAt);
    }

    function stake(address _address, uint256 _amount) external whenNotPaused nonReentrant {
        require(_amount > 0, "Insuficient amount for staking");
        if (hodlers[_msgSender()].available >= _amount) {
            hodlers[_msgSender()].available = hodlers[_msgSender()].available.sub(_amount);
        } else {
            require(tokenContract.transferFrom(_msgSender(), address(this), _amount), 
                    "Transfer of tokens for staking failed");
        }
        hodlers[_msgSender()].stakes[_address] = hodlers[_msgSender()].stakes[_address].add(_amount);
        emit Staked(_msgSender(), _address, _amount);
    }

    function unstake(address _address, uint256 _amount) external whenNotPaused nonReentrant {
        require(_amount > 0, "Insufficient amount for unstaking");
        uint256 stakeAmount = hodlers[_msgSender()].stakes[_address];
        require(stakeAmount >= _amount, "Insufficient stake");

        if (stakeAmount == _amount) {
            delete hodlers[_msgSender()].stakes[_address];
        } else {
            hodlers[_msgSender()].stakes[_address] = hodlers[_msgSender()].stakes[_address].sub(_amount);
        }
        emit Unstaked(_msgSender(), _address, stakeAmount);

        uint256 availableAt = block.timestamp + STAKE_DURATION;
        hodlers[_msgSender()].vaults.push(Vault(stakeAmount, availableAt));
        emit Vaulted(_msgSender(), stakeAmount, availableAt);
    }

    function addVotes(uint256 _amount) external whenNotPaused nonReentrant {
        if (hodlers[_msgSender()].available >= _amount) {
            hodlers[_msgSender()].available = hodlers[_msgSender()].available.sub(_amount);
        } else {
            require(tokenContract.transferFrom(_msgSender(), address(this), _amount), 
                    "Transfer of tokens for voting failed");
        }
        hodlers[_msgSender()].votes = hodlers[_msgSender()].votes.add(_amount);
        emit AddedVotes(_msgSender(), _amount);
    }

    function removeVotes(uint256 _amount) external whenNotPaused nonReentrant {
        require(hodlers[_msgSender()].votes >= _amount, "Insufficient votes");
        hodlers[_msgSender()].votes = hodlers[_msgSender()].votes.sub(_amount);
        emit RemovedVotes(_msgSender(), _amount);

        uint256 availableAt = block.timestamp + GOVERNANCE_DURATION;
        hodlers[_msgSender()].vaults.push(Vault(_amount, availableAt));

        emit Vaulted(_msgSender(), _amount, availableAt);
    }

    receive() external payable whenNotPaused nonReentrant {
        hodlers[_msgSender()].gas = hodlers[_msgSender()].gas.add(msg.value);
        controllerAddress.transfer(msg.value);

        uint256 gasTest = gasleft();
        hodlers[_msgSender()].gas = hodlers[_msgSender()].gas.sub(0);
        hodlers[_msgSender()].available = hodlers[_msgSender()].available.add(0);
        require(hodlers[_msgSender()].gas >= 0, "Insufficient gas budget for hodler account");
        uint256 gasEstimate = gasTest - gasleft();

        require(
            hodlers[_msgSender()].gas > gasEstimate,
            "Not enough gas budget for updating the hodler account"
        );
        emit UpdateRewards(_msgSender(), gasEstimate, false);
    }

    function redeem() external whenNotPaused nonReentrant {
        uint256 gasTest = gasleft();
        hodlers[_msgSender()].gas = hodlers[_msgSender()].gas.sub(0);
        hodlers[_msgSender()].available = hodlers[_msgSender()].available.add(0);
        require(hodlers[_msgSender()].gas >= 0, "Insufficient gas budget for hodler account");
        uint256 gasEstimate = gasTest - gasleft();

        require(
            hodlers[_msgSender()].gas > gasEstimate,
            "Not enough gas budget for updating the hodler account"
        );
        emit UpdateRewards(_msgSender(), gasEstimate, true);
    }

    function openExpired() external whenNotPaused nonReentrant {
        uint256 bufferedTimestamp = block.timestamp.sub(TIMESTAMP_BUFFER);
        uint256 claimed = 0;
        for (uint256 i = 0; i < hodlers[_msgSender()].vaults.length; i++) {
            if (hodlers[_msgSender()].vaults[i].availableAt < bufferedTimestamp) {
                claimed = claimed.add(hodlers[_msgSender()].vaults[i].amount);
                delete hodlers[_msgSender()].vaults[i];
            }
        }
        hodlers[_msgSender()].available = hodlers[_msgSender()].available.add(claimed);
    }

    function withdraw(uint256 _amount) external whenNotPaused nonReentrant {
        require(_amount > 0, "Non-zero amount required");
        require(
            hodlers[_msgSender()].available >= _amount,
            "Insufficient available balance"
        );
        hodlers[_msgSender()].available = hodlers[_msgSender()].available.sub(_amount);
        tokenContract.transfer(_msgSender(), _amount);

        emit Withdrawn(_msgSender(), _amount);
    }

    function isValidDuration(uint256 _duration) internal pure returns (bool) {
        return _duration >= (TIMESTAMP_BUFFER + DAY);
    }
    
    function reward(
        address _address,
        uint256 _rewardAmount,
        uint256 _gasEstimate,
        bool _redeem
    ) external onlyRole(CONTROLLER_ROLE) whenNotPaused nonReentrant {
        require(hodlers[_address].gas >= _gasEstimate, "Insufficient gas budget for hodler account");
        hodlers[_address].gas = hodlers[_address].gas.sub(_gasEstimate);
        if (_redeem) {
            require(tokenContract.transferFrom(rewardsPoolAddress, _address, _rewardAmount), "Withdrawal of reward tokens failed");
        } else {
            require(tokenContract.transferFrom(rewardsPoolAddress, address(this), _rewardAmount), "Transfer of reward tokens failed");
            hodlers[_address].available = hodlers[_address].available.add(_rewardAmount);
        }
        emit Rewarded(_address, _rewardAmount, _redeem);
    }

    function getLock(string calldata _fingerprint) external view returns (uint256) {
        uint256 fingerprintLength = bytes(_fingerprint).length;
        require(fingerprintLength > 0, "Fingerprint must have non 0 characters");
        require(fingerprintLength <= 40, "Fingerprint must have 40 or less characters");

        return hodlers[_msgSender()].locks[_fingerprint];
    }

    function getStake(address _address) external view returns (uint256) {
        return hodlers[_msgSender()].stakes[_address];
    }

    function getVaults() external view returns (Vault[] memory) {
        return hodlers[_msgSender()].vaults;
    }

    function setLockSize(uint256 _size) external onlyRole(CONTROLLER_ROLE) nonReentrant {
        require(_size > 0, "Lock size must be greater than 0");
        uint256 oldValue = LOCK_SIZE;
        LOCK_SIZE = _size;
        emit LockSizeUpdated(controllerAddress, oldValue, _size);
    }

    function setLockDuration(uint256 _seconds) external onlyRole(CONTROLLER_ROLE) nonReentrant {
        require(isValidDuration(_seconds), "Invalid duration for locking");
        uint256 oldValue = LOCK_DURATION;
        LOCK_DURATION = _seconds;
        emit LockDurationUpdated(controllerAddress, oldValue, _seconds);
    }

    function setStakeDuration(uint256 _seconds) external onlyRole(CONTROLLER_ROLE) nonReentrant {
        require(isValidDuration(_seconds), "Invalid duration for staking");
        uint256 oldValue = STAKE_DURATION;
        STAKE_DURATION = _seconds;
        emit StakeDurationUpdated(controllerAddress, oldValue, _seconds);
    }

    function setGovernanceDuration(uint256 _seconds) external onlyRole(CONTROLLER_ROLE) nonReentrant {
        require(isValidDuration(_seconds), "Invalid duration for governance");
        uint256 oldValue = GOVERNANCE_DURATION;
        GOVERNANCE_DURATION = _seconds;
        emit GovernanceDurationUpdated(controllerAddress, oldValue, _seconds);
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        address _tokenAddress, 
        address payable _controller,
        uint256 _lockSize,
        uint256 _lockDuration,
        uint256 _stakeDuration,
        uint256 _governanceDuration,
        address _rewardsPoolAddress
    ) initializer public {        
        require(_lockSize > 0, "Lock size must be greater than 0");
        require(isValidDuration(_lockDuration), "Invalid duration for locking");
        require(isValidDuration(_stakeDuration), "Invalid duration for staking");
        require(isValidDuration(_governanceDuration), "Invalid duration for governance");

        __AccessControl_init();
        __Pausable_init();
        __UUPSUpgradeable_init();
        __ReentrancyGuard_init();

        tokenContract = IERC20(_tokenAddress);
        controllerAddress = _controller;

        LOCK_SIZE = _lockSize;
        LOCK_DURATION = _lockDuration;
        STAKE_DURATION = _stakeDuration;
        GOVERNANCE_DURATION = _governanceDuration;
        
        rewardsPoolAddress = _rewardsPoolAddress;

        _grantRole(DEFAULT_ADMIN_ROLE, _msgSender());
        _grantRole(PAUSER_ROLE, _msgSender());
        _grantRole(UPGRADER_ROLE, _msgSender());
        _grantRole(CONTROLLER_ROLE, _controller);
        emit HodlerInitialized(_tokenAddress, _controller, _lockSize, _lockDuration, _stakeDuration, _governanceDuration);
    }

    function pause() public onlyRole(PAUSER_ROLE) {
        _pause();
    }

    function unpause() public onlyRole(PAUSER_ROLE) {
        _unpause();
    }

    function _authorizeUpgrade(address newImplementation)
        internal
        view
        onlyRole(UPGRADER_ROLE)
        override
    {
        require(
            _compareVersions(IHodler(newImplementation).version(), VERSION) > 0,
            "New implementation version must be greater than current version"
        );
    }

    function _compareVersions(uint8 version1, uint8 version2) internal pure returns (int) {
        if (version1 > version2) return 1;
        if (version1 < version2) return -1;

        return 0;
    }

    function version() external pure returns (uint8) {
        return VERSION;
    }

    function hasRole(bytes32 role, address account) public view override returns (bool) {
        return super.hasRole(role, account);
    }

    function emergencyWithdraw() external onlyRole(DEFAULT_ADMIN_ROLE) nonReentrant {
        require(paused(), "Contract must be paused");
        uint256 balance = tokenContract.balanceOf(address(this));
        require(tokenContract.transfer(_msgSender(), balance), "Transfer failed");
    }
}
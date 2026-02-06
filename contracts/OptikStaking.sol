// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title OptikStaking
 * @notice Staking contract for OPTIK token with revenue sharing and lock multipliers
 * @dev Revenue comes from OPTIK agent trading fees - real yield, not inflation
 */
contract OptikStaking is ReentrancyGuard, Ownable {
    using SafeERC20 for IERC20;

    IERC20 public immutable optikToken;
    
    // Lock periods and their multipliers (in basis points, 10000 = 1x)
    uint256 public constant FLEXIBLE_MULTIPLIER = 10000;      // 1.0x
    uint256 public constant LOCK_30_MULTIPLIER = 12500;       // 1.25x
    uint256 public constant LOCK_90_MULTIPLIER = 15000;       // 1.5x
    uint256 public constant LOCK_180_MULTIPLIER = 20000;      // 2.0x
    uint256 public constant LOCK_365_MULTIPLIER = 30000;      // 3.0x
    
    uint256 public constant PREMIUM_THRESHOLD = 10_000 * 1e18; // 10,000 OPTIK for premium access
    uint256 public constant BURN_PERCENTAGE = 1000;            // 10% of deposits burned (basis points)
    
    address public constant BURN_ADDRESS = 0x000000000000000000000000000000000000dEaD;
    
    struct Stake {
        uint256 amount;
        uint256 weightedAmount;     // amount * multiplier for reward calculation
        uint256 lockEnd;            // 0 for flexible
        uint256 lockDuration;       // original lock duration
        uint256 rewardDebt;         // for reward calculation
        uint256 stakedAt;
    }
    
    struct AgentStake {
        address agentWallet;
        uint256 amount;
        string agentName;
        string tokenAddress;
    }
    
    // User stakes (can have multiple positions)
    mapping(address => Stake[]) public userStakes;
    
    // Agent priority pool
    AgentStake[] public agentPriorityPool;
    mapping(address => uint256) public agentStakeIndex; // agent wallet -> index + 1 (0 means not staked)
    
    // Reward tracking
    uint256 public totalWeightedStake;
    uint256 public accRewardPerShare;  // Accumulated rewards per weighted share (scaled by 1e12)
    uint256 public totalRewardsDistributed;
    uint256 public totalBurned;
    
    // Premium access tracking
    mapping(address => bool) public hasPremiumAccess;
    uint256 public premiumHolders;
    
    // Events
    event Staked(address indexed user, uint256 amount, uint256 lockDuration, uint256 stakeIndex);
    event Unstaked(address indexed user, uint256 amount, uint256 stakeIndex);
    event RewardsClaimed(address indexed user, uint256 amount);
    event RevenueDeposited(uint256 amount, uint256 burned);
    event AgentStaked(address indexed agentWallet, string agentName, uint256 amount);
    event AgentUnstaked(address indexed agentWallet, uint256 amount);
    event PremiumAccessGranted(address indexed user);
    event PremiumAccessRevoked(address indexed user);
    
    constructor(address _optikToken) Ownable(msg.sender) {
        optikToken = IERC20(_optikToken);
    }
    
    /**
     * @notice Stake OPTIK tokens with optional lock period
     * @param amount Amount of OPTIK to stake
     * @param lockDays Lock period in days (0 for flexible, 30, 90, 180, or 365)
     */
    function stake(uint256 amount, uint256 lockDays) external nonReentrant {
        require(amount > 0, "Cannot stake 0");
        require(
            lockDays == 0 || lockDays == 30 || lockDays == 90 || 
            lockDays == 180 || lockDays == 365,
            "Invalid lock period"
        );
        
        // Transfer tokens from user
        optikToken.safeTransferFrom(msg.sender, address(this), amount);
        
        // Calculate multiplier
        uint256 multiplier = _getMultiplier(lockDays);
        uint256 weightedAmount = (amount * multiplier) / 10000;
        
        // Calculate lock end
        uint256 lockEnd = lockDays > 0 ? block.timestamp + (lockDays * 1 days) : 0;
        
        // Create stake
        userStakes[msg.sender].push(Stake({
            amount: amount,
            weightedAmount: weightedAmount,
            lockEnd: lockEnd,
            lockDuration: lockDays,
            rewardDebt: (weightedAmount * accRewardPerShare) / 1e12,
            stakedAt: block.timestamp
        }));
        
        totalWeightedStake += weightedAmount;
        
        // Check premium access
        _updatePremiumAccess(msg.sender);
        
        emit Staked(msg.sender, amount, lockDays, userStakes[msg.sender].length - 1);
    }
    
    /**
     * @notice Unstake tokens from a specific position
     * @param stakeIndex Index of the stake position to unstake
     */
    function unstake(uint256 stakeIndex) external nonReentrant {
        require(stakeIndex < userStakes[msg.sender].length, "Invalid stake index");
        
        Stake storage userStake = userStakes[msg.sender][stakeIndex];
        require(userStake.amount > 0, "Already unstaked");
        require(
            userStake.lockEnd == 0 || block.timestamp >= userStake.lockEnd,
            "Still locked"
        );
        
        // Claim pending rewards first
        _claimRewards(msg.sender, stakeIndex);
        
        uint256 amount = userStake.amount;
        totalWeightedStake -= userStake.weightedAmount;
        
        // Clear stake (but keep struct for history)
        userStake.amount = 0;
        userStake.weightedAmount = 0;
        
        // Transfer tokens back
        optikToken.safeTransfer(msg.sender, amount);
        
        // Update premium access
        _updatePremiumAccess(msg.sender);
        
        emit Unstaked(msg.sender, amount, stakeIndex);
    }
    
    /**
     * @notice Claim rewards from all stake positions
     */
    function claimAllRewards() external nonReentrant {
        uint256 totalPending = 0;
        
        for (uint256 i = 0; i < userStakes[msg.sender].length; i++) {
            if (userStakes[msg.sender][i].amount > 0) {
                totalPending += _claimRewards(msg.sender, i);
            }
        }
        
        if (totalPending > 0) {
            optikToken.safeTransfer(msg.sender, totalPending);
            emit RewardsClaimed(msg.sender, totalPending);
        }
    }
    
    /**
     * @notice Deposit trading revenue for distribution to stakers
     * @dev 10% is burned, 90% distributed to stakers
     */
    function depositRevenue(uint256 amount) external nonReentrant {
        require(amount > 0, "Cannot deposit 0");
        
        optikToken.safeTransferFrom(msg.sender, address(this), amount);
        
        // Calculate burn amount (10%)
        uint256 burnAmount = (amount * BURN_PERCENTAGE) / 10000;
        uint256 distributeAmount = amount - burnAmount;
        
        // Burn tokens
        if (burnAmount > 0) {
            optikToken.safeTransfer(BURN_ADDRESS, burnAmount);
            totalBurned += burnAmount;
        }
        
        // Distribute to stakers
        if (totalWeightedStake > 0 && distributeAmount > 0) {
            accRewardPerShare += (distributeAmount * 1e12) / totalWeightedStake;
            totalRewardsDistributed += distributeAmount;
        }
        
        emit RevenueDeposited(amount, burnAmount);
    }
    
    /**
     * @notice Stake OPTIK as an AI agent for priority in reports
     * @param amount Amount to stake
     * @param agentName Name of the agent
     * @param tokenAddress Token address of the agent
     */
    function stakeAsAgent(
        uint256 amount, 
        string calldata agentName, 
        string calldata tokenAddress
    ) external nonReentrant {
        require(amount > 0, "Cannot stake 0");
        require(agentStakeIndex[msg.sender] == 0, "Already staked as agent");
        
        optikToken.safeTransferFrom(msg.sender, address(this), amount);
        
        agentPriorityPool.push(AgentStake({
            agentWallet: msg.sender,
            amount: amount,
            agentName: agentName,
            tokenAddress: tokenAddress
        }));
        
        agentStakeIndex[msg.sender] = agentPriorityPool.length; // index + 1
        
        emit AgentStaked(msg.sender, agentName, amount);
    }
    
    /**
     * @notice Increase agent stake for higher priority
     */
    function increaseAgentStake(uint256 additionalAmount) external nonReentrant {
        require(agentStakeIndex[msg.sender] > 0, "Not staked as agent");
        require(additionalAmount > 0, "Cannot add 0");
        
        optikToken.safeTransferFrom(msg.sender, address(this), additionalAmount);
        
        uint256 index = agentStakeIndex[msg.sender] - 1;
        agentPriorityPool[index].amount += additionalAmount;
        
        emit AgentStaked(
            msg.sender, 
            agentPriorityPool[index].agentName, 
            agentPriorityPool[index].amount
        );
    }
    
    /**
     * @notice Unstake from agent priority pool
     */
    function unstakeAsAgent() external nonReentrant {
        require(agentStakeIndex[msg.sender] > 0, "Not staked as agent");
        
        uint256 index = agentStakeIndex[msg.sender] - 1;
        uint256 amount = agentPriorityPool[index].amount;
        
        // Remove from array (swap with last and pop)
        uint256 lastIndex = agentPriorityPool.length - 1;
        if (index != lastIndex) {
            agentPriorityPool[index] = agentPriorityPool[lastIndex];
            agentStakeIndex[agentPriorityPool[index].agentWallet] = index + 1;
        }
        agentPriorityPool.pop();
        agentStakeIndex[msg.sender] = 0;
        
        optikToken.safeTransfer(msg.sender, amount);
        
        emit AgentUnstaked(msg.sender, amount);
    }
    
    // ============ View Functions ============
    
    function getUserStakes(address user) external view returns (Stake[] memory) {
        return userStakes[user];
    }
    
    function getUserTotalStaked(address user) external view returns (uint256 total) {
        for (uint256 i = 0; i < userStakes[user].length; i++) {
            total += userStakes[user][i].amount;
        }
    }
    
    function getPendingRewards(address user) external view returns (uint256 total) {
        for (uint256 i = 0; i < userStakes[user].length; i++) {
            Stake memory s = userStakes[user][i];
            if (s.amount > 0) {
                total += (s.weightedAmount * accRewardPerShare / 1e12) - s.rewardDebt;
            }
        }
    }
    
    function getAgentPriorityPool() external view returns (AgentStake[] memory) {
        return agentPriorityPool;
    }
    
    function getAgentRanking() external view returns (AgentStake[] memory) {
        // Return agents sorted by stake amount (descending)
        AgentStake[] memory sorted = new AgentStake[](agentPriorityPool.length);
        for (uint256 i = 0; i < agentPriorityPool.length; i++) {
            sorted[i] = agentPriorityPool[i];
        }
        
        // Simple bubble sort (fine for small arrays)
        for (uint256 i = 0; i < sorted.length; i++) {
            for (uint256 j = i + 1; j < sorted.length; j++) {
                if (sorted[j].amount > sorted[i].amount) {
                    AgentStake memory temp = sorted[i];
                    sorted[i] = sorted[j];
                    sorted[j] = temp;
                }
            }
        }
        
        return sorted;
    }
    
    function getStats() external view returns (
        uint256 _totalWeightedStake,
        uint256 _totalRewardsDistributed,
        uint256 _totalBurned,
        uint256 _premiumHolders,
        uint256 _agentCount
    ) {
        return (
            totalWeightedStake,
            totalRewardsDistributed,
            totalBurned,
            premiumHolders,
            agentPriorityPool.length
        );
    }
    
    // ============ Internal Functions ============
    
    function _getMultiplier(uint256 lockDays) internal pure returns (uint256) {
        if (lockDays == 0) return FLEXIBLE_MULTIPLIER;
        if (lockDays == 30) return LOCK_30_MULTIPLIER;
        if (lockDays == 90) return LOCK_90_MULTIPLIER;
        if (lockDays == 180) return LOCK_180_MULTIPLIER;
        if (lockDays == 365) return LOCK_365_MULTIPLIER;
        return FLEXIBLE_MULTIPLIER;
    }
    
    function _claimRewards(address user, uint256 stakeIndex) internal returns (uint256) {
        Stake storage s = userStakes[user][stakeIndex];
        if (s.amount == 0) return 0;
        
        uint256 pending = (s.weightedAmount * accRewardPerShare / 1e12) - s.rewardDebt;
        s.rewardDebt = (s.weightedAmount * accRewardPerShare) / 1e12;
        
        return pending;
    }
    
    function _updatePremiumAccess(address user) internal {
        uint256 totalStaked = 0;
        for (uint256 i = 0; i < userStakes[user].length; i++) {
            totalStaked += userStakes[user][i].amount;
        }
        
        bool hadAccess = hasPremiumAccess[user];
        bool hasAccess = totalStaked >= PREMIUM_THRESHOLD;
        
        if (hasAccess && !hadAccess) {
            hasPremiumAccess[user] = true;
            premiumHolders++;
            emit PremiumAccessGranted(user);
        } else if (!hasAccess && hadAccess) {
            hasPremiumAccess[user] = false;
            premiumHolders--;
            emit PremiumAccessRevoked(user);
        }
    }
}

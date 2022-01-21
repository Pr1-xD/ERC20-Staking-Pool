//SPDX-License-Identifier: Unlicense
pragma solidity >0.6.0;

import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";

contract DogexStake is Ownable, Pausable, ReentrancyGuard {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    struct UserInfo {
        uint256 amount;
        uint256 initAmount; // VIP pool
        uint256 rewardDebt;
        uint256 pendingRewards;
        uint256 depositedAt;
    }

    struct PoolInfo {
        uint256 allocPoint;
        uint256 lastRewardBlock;
        uint256 accPerShare;
        uint256 depositedAmount;
        uint256 maxCap;
        uint256 rewardsAmount;
        uint256 lockupDuration;
    }

    IERC20 public stakingToken;
    IERC20 public rewardToken;
    address public feeRecipient;
    uint256 public withdrawalFee;
    uint256 public penaltyFee;
    uint256 public constant MAX_FEE = 10000;
    uint256 public rewardPerBlock = uint256(0.001 ether);
    uint256 public minDepositAmount = uint256(1 ether);
    uint256 public maxDepositAmount = uint256(-1);

    bool public isVipPool;
    uint256 public vipLimit = 5000;
    address public vipAgent;

    PoolInfo[] public poolInfo;
    mapping(uint256 => mapping(address => UserInfo)) public userInfo;
    uint256 public totalAllocPoint = 10;

    event Deposit(address indexed user, uint256 indexed pid, uint256 amount);
    event Withdraw(address indexed user, uint256 indexed pid, uint256 amount);
    event Claim(address indexed user, uint256 indexed pid, uint256 amount);

    modifier updateReward(uint pid) {
        updatePool(pid);
        
        PoolInfo storage pool = poolInfo[pid];
        UserInfo storage user = userInfo[pid][msg.sender];
        uint amount = user.amount;
        if (isVipPool == true && user.amount < user.initAmount.mul(vipLimit).div(MAX_FEE)) {
            amount = 0;
        }
        if (amount > 0) {
            uint256 pending = amount.mul(pool.accPerShare).div(1e12).sub(user.rewardDebt);
            user.pendingRewards = user.pendingRewards.add(pending);
        }

        _;
        
        user.rewardDebt = user.amount.mul(pool.accPerShare).div(1e12);
        if (isVipPool == true && user.amount < user.initAmount.mul(vipLimit).div(MAX_FEE)) {
            user.rewardDebt = 0;
        }
    }

    constructor(address _stakingToken, address _rewardToken) {
        stakingToken = IERC20(_stakingToken);
        rewardToken = IERC20(_rewardToken);
        feeRecipient = msg.sender;
        vipAgent = msg.sender;
        
        addPool(10, 0);
    }

    function addPool(uint256 _allocPoint, uint256 _lockupDuration) public onlyOwner {
        poolInfo.push(
            PoolInfo({
                allocPoint: _allocPoint,
                lastRewardBlock: 0,
                accPerShare: 0,
                depositedAmount: 0,
                maxCap: uint256(-1),
                rewardsAmount: 0,
                lockupDuration: _lockupDuration
            })
        );
    }
    
    function startStaking(uint pid, uint256 startBlock) external onlyOwner {
        require(poolInfo[pid].lastRewardBlock == 0, 'Staking already started');
        poolInfo[pid].lastRewardBlock = startBlock;
    }

    function setLockupDuration(uint pid, uint256 _lockupDuration) external onlyOwner {
        PoolInfo storage pool = poolInfo[pid];
        pool.lockupDuration = _lockupDuration;
    }

    function setAllocation(uint pid, uint _allocation) external onlyOwner {
        require(_allocation <= 10, "invalid value");
        PoolInfo storage pool = poolInfo[pid];
        pool.allocPoint = _allocation;
    }

    function setMaxCap(uint256 pid, uint256 _cap) external onlyOwner {
        poolInfo[pid].maxCap = _cap;
    }

    function balance(uint pid) public view returns (uint256) {
        PoolInfo storage pool = poolInfo[pid];
        return pool.depositedAmount;
    }

    function balanceOf(uint pid, address _user) public view returns (uint256) {
        UserInfo storage user = userInfo[pid][_user];

        return user.amount;
    }

    function updatePool(uint256 pid) internal {
        require(poolInfo[pid].lastRewardBlock > 0 && block.number >= poolInfo[pid].lastRewardBlock, 'Staking not yet started');
        PoolInfo storage pool = poolInfo[pid];
        if (block.number <= pool.lastRewardBlock) {
            return;
        }
        uint256 depositedAmount = pool.depositedAmount;
        if (pool.depositedAmount == 0) {
            pool.lastRewardBlock = block.number;
            return;
        }
        uint256 multiplier = block.number.sub(pool.lastRewardBlock);
        uint256 reward = multiplier.mul(rewardPerBlock).mul(pool.allocPoint).div(totalAllocPoint);
        pool.rewardsAmount = pool.rewardsAmount.add(reward);
        pool.accPerShare = pool.accPerShare.add(reward.mul(1e12).div(depositedAmount));
        pool.lastRewardBlock = block.number;
    }

    function deposit(uint256 pid, uint256 amount) external nonReentrant whenNotPaused updateReward(pid) {
        require(isVipPool == false, 'disabled for VIP pool');
        require(amount >= minDepositAmount && amount < maxDepositAmount, "invalid deposit amount");

        PoolInfo storage pool = poolInfo[pid];
        UserInfo storage user = userInfo[pid][msg.sender];

        uint before = stakingToken.balanceOf(address(this));
        stakingToken.safeTransferFrom(msg.sender, address(this), amount);
        amount = stakingToken.balanceOf(address(this)).sub(before);

        require (pool.depositedAmount.add(amount) <= pool.maxCap, 'exceeded maximum cap');

        user.amount = user.amount.add(amount);
        user.depositedAt = block.timestamp;
        pool.depositedAmount = pool.depositedAmount.add(amount);

        emit Deposit(msg.sender, pid, amount);
    }

    function depositFromAgent(address _user, uint256 _amount) external {
        require (msg.sender == vipAgent, "!agent");
        require (isVipPool == true, '!VIP pool');
        require (_amount > 0, '!amount');
        
        PoolInfo storage pool = poolInfo[0];
        UserInfo storage user = userInfo[0][_user];

        uint256 originAmount = user.amount;
        user.amount = _amount;
        user.initAmount = _amount;
        user.depositedAt = block.timestamp;
        pool.depositedAmount = pool.depositedAmount.sub(originAmount).add(_amount);
    }

    function withdraw(uint256 pid, uint256 amount) public nonReentrant updateReward(pid) {
        PoolInfo storage pool = poolInfo[pid];
        UserInfo storage user = userInfo[pid][msg.sender];

        if (penaltyFee == 0) {
            require(block.timestamp >= user.depositedAt + pool.lockupDuration, "You cannot withdraw yet!");
        }
        require(amount > 0 && user.amount >= amount, "!amount");

        uint256 feeAmount = 0;
        if (penaltyFee > 0 && block.timestamp < user.depositedAt + pool.lockupDuration) {
            feeAmount = amount.mul(penaltyFee).div(MAX_FEE);
        } else if (withdrawalFee > 0) {
            feeAmount = amount.mul(withdrawalFee).div(MAX_FEE);
        }
        
        if (feeAmount > 0) stakingToken.safeTransfer(feeRecipient, feeAmount);
        stakingToken.safeTransfer(address(msg.sender), amount.sub(feeAmount));
        
        user.amount = user.amount.sub(amount);
        if (isVipPool == false) user.depositedAt = block.timestamp;
        pool.depositedAmount = pool.depositedAmount.sub(amount);

        emit Withdraw(msg.sender, pid, amount);
    }

    function withdrawAll(uint256 pid) external {
        UserInfo storage user = userInfo[pid][msg.sender];

        withdraw(pid, user.amount);
    }

    function claim(uint256 pid) public nonReentrant updateReward(pid) {
        PoolInfo storage pool = poolInfo[pid];
        UserInfo storage user = userInfo[pid][msg.sender];
        
        uint256 claimedAmount = safeTransferRewards(pid, msg.sender, user.pendingRewards);
        user.pendingRewards = user.pendingRewards.sub(claimedAmount);
        pool.rewardsAmount = pool.rewardsAmount.sub(claimedAmount);

        emit Claim(msg.sender, pid, claimedAmount);
    }

    function claimable(uint256 pid, address _user) external view returns (uint256) {
        require(poolInfo[pid].lastRewardBlock > 0 && block.number >= poolInfo[pid].lastRewardBlock, 'Staking not yet started');
        PoolInfo storage pool = poolInfo[pid];
        UserInfo storage user = userInfo[pid][_user];
        uint256 accPerShare = pool.accPerShare;
        uint256 depositedAmount = pool.depositedAmount;
        if (block.number > pool.lastRewardBlock && depositedAmount != 0) {
            uint256 multiplier = block.number.sub(pool.lastRewardBlock);
            uint256 reward = multiplier.mul(rewardPerBlock).mul(pool.allocPoint).div(totalAllocPoint);
            accPerShare = accPerShare.add(reward.mul(1e12).div(depositedAmount));
        }
        uint amount = user.amount;
        if (isVipPool == true && user.amount < user.initAmount.mul(vipLimit).div(MAX_FEE)) {
            amount = 0;
        }
        return amount.mul(accPerShare).div(1e12).sub(user.rewardDebt).add(user.pendingRewards);
    }
    
    function safeTransferRewards(uint256 pid, address to, uint256 amount) internal returns (uint256) {
        PoolInfo storage pool = poolInfo[pid];
        uint256 _bal = rewardToken.balanceOf(address(this));
        if (amount > pool.rewardsAmount) amount = pool.rewardsAmount;
        if (amount > _bal) amount = _bal;
        rewardToken.safeTransfer(to, amount);
        return amount;
    }
    
    function setRewardPerBlock(uint256 _rewardPerBlock) external onlyOwner {
        require(_rewardPerBlock > 0, "Rewards per block should be greater than 0!");

        // Update pool infos with old reward rate before setting new one first
        for (uint i = 0; i < poolInfo.length; i++) {
            PoolInfo storage pool = poolInfo[i];
            if (block.number <= pool.lastRewardBlock) {
                continue;
            }
            uint256 depositedAmount = pool.depositedAmount;
            if (pool.depositedAmount == 0) {
                pool.lastRewardBlock = block.number;
                continue;
            }
            uint256 multiplier = block.number.sub(pool.lastRewardBlock);
            uint256 reward = multiplier.mul(rewardPerBlock).mul(pool.allocPoint).div(totalAllocPoint);
            pool.rewardsAmount = pool.rewardsAmount.add(reward);
            pool.accPerShare = pool.accPerShare.add(reward.mul(1e12).div(depositedAmount));
            pool.lastRewardBlock = block.number;
        }

        rewardPerBlock = _rewardPerBlock;
    }

    function setMinDepositAmount(uint256 _amount) external onlyOwner {
        require(_amount > 0, "invalid value");
        minDepositAmount = _amount;
    }

    function setMaxDepositAmount(uint256 _amount) external onlyOwner {
        require(_amount > minDepositAmount, "invalid value, should be greater than mininum amount");
        maxDepositAmount = _amount;
    }

    function setWithdrawalFee(uint256 _fee) external onlyOwner {
        require(_fee < MAX_FEE, "invalid fee");

        withdrawalFee = _fee;
    }

    function setPenaltyFee(uint256 _fee) external onlyOwner {
        require(_fee < MAX_FEE, "invalid fee");

        penaltyFee = _fee;
    }

    function setFeeRecipient(address _recipient) external onlyOwner {
        feeRecipient = _recipient;
    }

    function setVipMode(bool _flag) external onlyOwner {
        isVipPool = _flag;
    }

    function setVipAgent(address _user) external onlyOwner {
        vipAgent = _user;
    }

    function setVipLimit(uint256 _limit) external onlyOwner {
        require (_limit < MAX_FEE, '!limit');
        vipLimit = _limit;
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    function emergencyWithdraw(address _token, uint256 _amount) external onlyOwner {
        uint256 _bal = IERC20(_token).balanceOf(address(this));
        if (_amount > _bal) _amount = _bal;

        IERC20(_token).safeTransfer(_msgSender(), _amount);
    }
}

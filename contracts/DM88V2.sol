// SPDX-License-Identifier: MIT
/*

██████╗ ███████╗██████╗  █████╗ ███████╗███████╗
██╔══██╗██╔════╝██╔══██╗██╔══██╗██╔════╝██╔════╝
██║  ██║█████╗  ██████╔╝███████║███████╗█████╗  
██║  ██║██╔══╝  ██╔══██╗██╔══██║╚════██║██╔══╝  
██████╔╝███████╗██████╔╝██║  ██║███████║███████╗
╚═════╝ ╚══════╝╚═════╝ ╚═╝  ╚═╝╚══════╝╚══════╝
                                               

* Debase: DM88V2.sol
* Description:
* Deposit DEBASE, DAI token to get DEBASE, DAI, MPH rewards.
*   Get MPH reward 7 days after deposit
*   Get DEBASE, DAI reward after unlocked
* Coded by: Ryuhei Matsuda, PunkUnknown
*/

pragma solidity >=0.8.0;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "./interfaces/IUniswapV2Pair.sol";
import "./interfaces/IDInterest.sol";

struct Vest {
    uint256 amount;
    uint256 vestPeriodInSeconds;
    uint256 creationTimestamp;
    uint256 withdrawnAmount;
}

interface IVesting {
    function withdrawVested(address account, uint256 vestIdx)
        external
        returns (uint256);

    function getVestWithdrawableAmount(address account, uint256 vestIdx)
        external
        view
        returns (uint256);

    function accountVestList(address account, uint256 vestIdx)
        external
        view
        returns (Vest memory);
}

contract DM88V2 is Ownable, IERC721Receiver, ReentrancyGuard {
    using SafeERC20 for IERC20;

    event onDeposit(
        address indexed user,
        uint256 daiAmount,
        uint256 debaseAmount,
        uint256 maturationTimestamp,
        uint256 depositId
    );
    event onWithdraw(address indexed user, uint256 depositId);
    event onWithdrawMphVested(
        address indexed user,
        uint256 amount,
        uint256 depositId
    );

    event LogSetDebaseRewardPercentage(uint256 debaseRewardPercentage_);
    event LogDebaseRewardIssued(uint256 rewardIssued, uint256 rewardsFinishBy);
    event LogSetBlockDuration(uint256 duration_);
    event LogSetPoolEnabled(bool poolEnabled_);
    event LogStartNewDistribtionCycle(
        uint256 poolShareAdded_,
        uint256 amount_,
        uint256 rewardRate_,
        uint256 periodFinish_
    );

    struct DepositInfo {
        uint256 rewardIndex;
        address owner;
        uint256 daiAmount;
        uint256 debaseGonAmount;
        uint256 debaseReward;
        uint256 debaseRewardPerTokenPaid;
        uint256 daiDepositId;
        uint256 mphReward;
        uint256 mphVestingIdx;
        uint256 maturationTimestamp;
        bool withdrawed;
    }

    uint256 private constant MAX_UINT256 = ~uint256(0);
    uint256 private constant INITIAL_FRAGMENTS_SUPPLY = 1000000 * 10**18;
    uint256 public constant TOTAL_GONS =
        MAX_UINT256 - (MAX_UINT256 % INITIAL_FRAGMENTS_SUPPLY);

    IUniswapV2Pair public debaseDaiPair;
    IDInterest public daiFixedPool;
    IVesting public mphVesting;
    IERC20 public dai;
    IERC20 public debase;
    IERC20 public mph;
    address public policy;

    uint256 public lockPeriod;
    uint256 public totalDaiLocked;

    mapping(uint256 => DepositInfo) public deposits;
    mapping(address => uint256[]) public depositIds;

    uint256 public depositLength;
    uint256 public daiFee = 300;
    uint256 public mphFee = 300;
    uint256 public mphTakeBackMultiplier = 300000000000000000;
    address public treasury;

    mapping(uint256 => uint256) public periodFinish;
    mapping(uint256 => uint256) public debaseRewardRate;
    mapping(uint256 => uint256) public lastUpdateBlock;
    mapping(uint256 => uint256) public debaseRewardPerTokenStored;

    uint256 public activeRewardIndex;
    bool public firstCycleRewarded;

    uint256 public debaseRewardPercentage;
    uint256 public debaseRewardDistributed;
    uint256 lastVestingIdx;
    uint256 firstDepositForVesting;

    // params for debase reward
    uint256 public blockDuration;
    bool public poolEnabled;

    modifier enabled() {
        require(poolEnabled, "Pool isn't enabled");
        _;
    }

    function _updateDebaseReward(uint256 depositId, uint256 rewardIndex)
        internal
    {
        debaseRewardPerTokenStored[rewardIndex] = debaseRewardPerToken(
            rewardIndex
        );
        lastUpdateBlock[rewardIndex] = _lastBlockRewardApplicable(rewardIndex);
        if (depositId < depositLength) {
            deposits[depositId].debaseReward = earned(depositId);
            deposits[depositId]
                .debaseRewardPerTokenPaid = debaseRewardPerTokenStored[
                rewardIndex
            ];
        }
    }

    constructor(
        IUniswapV2Pair _debaseDaiPair,
        IERC20 _dai,
        IERC20 _debase,
        IERC20 _mph,
        address _policy,
        IDInterest _daiFixedPool,
        IVesting _mphVesting,
        uint256 _lockPeriod,
        address _treasury,
        uint256 _debaseRewardPercentage,
        uint256 _blockDuration
    ) Ownable() {
        require(_treasury != address(0), "Invalid addr");
        debaseDaiPair = _debaseDaiPair;
        dai = _dai;
        debase = _debase;
        mph = _mph;
        policy = _policy;
        daiFixedPool = _daiFixedPool;
        mphVesting = _mphVesting;
        lockPeriod = _lockPeriod;
        treasury = _treasury;
        debaseRewardPercentage = _debaseRewardPercentage;
        blockDuration = _blockDuration;
    }

    function _depositDai(uint256 daiAmount)
        internal
        returns (uint256 daiDepositId, uint256 maturationTimestamp)
    {
        maturationTimestamp = block.timestamp + lockPeriod;
        dai.approve(address(daiFixedPool), daiAmount);
        daiFixedPool.deposit(daiAmount, maturationTimestamp);
        daiDepositId = daiFixedPool.depositsLength();
    }

    function _getCurrentVestingIdx() internal view returns (uint256) {
        uint256 vestIdx = lastVestingIdx;
        Vest memory vest = mphVesting.accountVestList(address(this), vestIdx);
        while (vest.creationTimestamp < block.timestamp) {
            vestIdx = vestIdx + 1;
            vest = mphVesting.accountVestList(address(this), vestIdx);
        }
        return vestIdx;
    }

    function _withdrawMphVested(uint256 depositId) internal {
        require(depositId < depositLength, "no deposit");
        DepositInfo storage depositInfo = deposits[depositId];
        require(depositInfo.owner == msg.sender, "not owner");

        uint256 _vestingIdx = depositInfo.mphVestingIdx;

        Vest memory vest =
            mphVesting.accountVestList(address(this), _vestingIdx);
        require(
            block.timestamp >=
                vest.creationTimestamp + vest.vestPeriodInSeconds,
            "Not ready to withdarw mph"
        );
        uint256 vested = mphVesting.withdrawVested(address(this), _vestingIdx);

        if (vested > 0) {
            deposits[depositId].mphReward =
                deposits[depositId].mphReward +
                vested;
            uint256 takeBackAmount = (vested * mphTakeBackMultiplier) / 1e18;
            uint256 mphVested = vested - takeBackAmount;
            uint256 mphFeeAmount = (mphVested * mphFee) / 1000;
            mph.transfer(depositInfo.owner, mphVested - mphFeeAmount);
            mph.transfer(treasury, mphFeeAmount);

            emit onWithdrawMphVested(depositInfo.owner, mphVested, depositId);
        }
    }

    function deposit(uint256 daiAmount, uint256 debaseAmount)
        external
        enabled
        nonReentrant
        returns (uint256)
    {
        require(daiAmount == debaseAmount);

        (uint256 daiDepositId, uint256 maturationTimestamp) =
            _depositDai(daiAmount);

        uint256 vestingIdx = _getCurrentVestingIdx();

        deposits[depositLength] = DepositInfo({
            rewardIndex: activeRewardIndex,
            owner: msg.sender,
            daiAmount: daiAmount,
            debaseGonAmount: debaseAmount * _gonsPerFragment(),
            debaseReward: 0,
            debaseRewardPerTokenPaid: 0,
            daiDepositId: daiDepositId,
            maturationTimestamp: maturationTimestamp,
            mphReward: 0,
            mphVestingIdx: vestingIdx,
            withdrawed: false
        });
        depositIds[msg.sender].push(depositLength);

        lastVestingIdx = vestingIdx + 1;
        depositLength = depositLength + 1;

        _updateDebaseReward(daiDepositId, activeRewardIndex);
        emit onDeposit(
            msg.sender,
            daiAmount,
            debaseAmount,
            maturationTimestamp,
            depositLength - 1
        );
        return depositLength - 1;
    }

    function userDepositLength(address user) external view returns (uint256) {
        return depositIds[user].length;
    }

    function _gonsPerFragment() internal view returns (uint256) {
        return TOTAL_GONS / debase.totalSupply();
    }

    function _withdrawDai(uint256 depositId, uint256 fundingId) internal {
        DepositInfo storage depositInfo = deposits[depositId];

        uint256 mphBalance = mph.balanceOf(address(this));
        mph.approve(address(daiFixedPool.mphMinter()), mphBalance);
        uint256 daiOldBalance = dai.balanceOf(address(this));
        daiFixedPool.withdraw(depositInfo.daiDepositId, fundingId);
        mph.approve(address(daiFixedPool.mphMinter()), 0);

        uint256 daiBalance = dai.balanceOf(address(this));
        uint256 daiReward = daiBalance - daiOldBalance - depositInfo.daiAmount;

        uint256 daiFeeAmount = (daiReward * daiFee) / 1000;

        dai.transfer(
            depositInfo.owner,
            depositInfo.daiAmount + daiReward - daiFeeAmount
        );
        dai.transfer(treasury, daiFeeAmount);
    }

    function _withdraw(
        address user,
        uint256 depositId,
        uint256 fundingId
    ) internal {
        require(depositId < depositLength, "no deposit");
        DepositInfo storage depositInfo = deposits[depositId];
        require(depositInfo.owner == user, "not owner");
        require(depositInfo.withdrawed == false, "withdrawed already");
        require(
            depositInfo.maturationTimestamp <= block.timestamp,
            "still locked"
        );

        _withdrawMphVested(depositId);
        _withdrawDai(depositId, fundingId);
        _withdrawDebase(depositId);
        depositInfo.withdrawed = true;
        totalDaiLocked = totalDaiLocked - depositInfo.daiAmount;
        emit onWithdraw(user, depositId);
    }

    function withdraw(uint256 depositId, uint256 fundingId)
        external
        nonReentrant
    {
        _withdraw(msg.sender, depositId, fundingId);
    }

    function multiWithdraw(
        uint256[] calldata depositIds_,
        uint256[] calldata fundingIds_
    ) external nonReentrant {
        require(depositIds_.length == fundingIds_.length, "incorrect length");
        for (uint256 i = 0; i < depositIds_.length; i += 1) {
            _withdraw(msg.sender, depositIds_[i], fundingIds_[i]);
        }
    }

    /**
     * @notice Function to set how much reward the stabilizer will request
     */
    function setRewardPercentage(uint256 debaseRewardPercentage_)
        external
        onlyOwner
    {
        debaseRewardPercentage = debaseRewardPercentage_;
        emit LogSetDebaseRewardPercentage(debaseRewardPercentage);
    }

    /**
     * @notice Function to set reward drop period
     */
    function setBlockDuration(uint256 blockDuration_) external onlyOwner {
        require(blockDuration_ >= 1, "invalid duration");
        blockDuration = blockDuration_;
        emit LogSetBlockDuration(blockDuration);
    }

    /**
     * @notice Function enabled or disable pool deposit
     */
    function setPoolEnabled(bool poolEnabled_) external onlyOwner {
        poolEnabled = poolEnabled_;
        emit LogSetPoolEnabled(poolEnabled);
    }

    function setDaiFee(uint256 _daiFee) external onlyOwner {
        daiFee = _daiFee;
    }

    function setMphFee(uint256 _mphFee) external onlyOwner {
        mphFee = _mphFee;
    }

    function setMphTakeBackMultiplier(uint256 _mphTakeBackMultiplier)
        external
        onlyOwner
    {
        mphTakeBackMultiplier = _mphTakeBackMultiplier;
    }

    function setTreasury(address _treasury) external onlyOwner {
        require(_treasury != address(0), "Invalid addr");
        treasury = _treasury;
    }

    function setPolicy(address _policy) external onlyOwner {
        require(_policy != address(0), "Invalid addr");
        policy = _policy;
    }

    function setLockPeriod(uint256 _lockPeriod) external onlyOwner {
        require(_lockPeriod > 0, "invalid lock period");
        lockPeriod = _lockPeriod;
    }

    function _lastBlockRewardApplicable(uint256 rewardIndex)
        internal
        view
        returns (uint256)
    {
        return Math.min(block.number, periodFinish[rewardIndex]);
    }

    function debaseRewardPerToken(uint256 rewardIndex)
        public
        view
        returns (uint256)
    {
        if (totalDaiLocked == 0) {
            return debaseRewardPerTokenStored[rewardIndex];
        }

        return
            (debaseRewardPerTokenStored[rewardIndex] +
                _lastBlockRewardApplicable(rewardIndex) -
                lastUpdateBlock[rewardIndex] *
                debaseRewardRate[rewardIndex] *
                10**18) / totalDaiLocked;
    }

    function earned(uint256 depositId) public view returns (uint256) {
        require(depositId < depositLength, "no deposit");
        return
            deposits[depositId].daiAmount *
            debaseRewardPerToken(deposits[depositId].rewardIndex) -
            deposits[depositId].debaseRewardPerTokenPaid /
            10**18 +
            deposits[depositId].debaseReward;
    }

    function _withdrawDebase(uint256 depositId) internal {
        _updateDebaseReward(depositId, deposits[depositId].rewardIndex);
        uint256 reward = earned(depositId);
        deposits[depositId].debaseReward = 0;

        uint256 rewardToClaim = (debase.totalSupply() * reward) / 10**18;

        debase.safeTransfer(
            deposits[depositId].owner,
            (rewardToClaim + deposits[depositId].debaseGonAmount) /
                _gonsPerFragment()
        );
        debaseRewardDistributed = debaseRewardDistributed + reward;
    }

    function checkStabilizerAndGetReward(
        int256 supplyDelta_,
        int256 rebaseLag_,
        uint256 exchangeRate_,
        uint256 debasePolicyBalance
    ) external returns (uint256 rewardAmount_) {
        require(
            msg.sender == policy,
            "Only debase policy contract can call this"
        );

        if (block.number > periodFinish[activeRewardIndex]) {
            uint256 rewardToClaim =
                (debasePolicyBalance * debaseRewardPercentage) / 10**18;

            if (firstCycleRewarded) {
                activeRewardIndex = activeRewardIndex + 1;
            } else {
                firstCycleRewarded = true;
            }

            if (debasePolicyBalance >= rewardToClaim) {
                startNewDistribtionCycle(rewardToClaim);
                return rewardToClaim;
            }
        }
        return 0;
    }

    function startNewDistribtionCycle(uint256 amount) internal {
        _updateDebaseReward(depositLength, activeRewardIndex);
        uint256 poolTotalShare = (amount * 10**18) / debase.totalSupply();

        debaseRewardRate[activeRewardIndex] = poolTotalShare / blockDuration;

        lastUpdateBlock[activeRewardIndex] = block.number;
        periodFinish[activeRewardIndex] = block.number + blockDuration;

        emit LogStartNewDistribtionCycle(
            poolTotalShare,
            amount,
            debaseRewardRate[activeRewardIndex],
            periodFinish[activeRewardIndex]
        );
    }

    function onERC721Received(
        address operator,
        address from,
        uint256 tokenId,
        bytes calldata data
    ) external pure override returns (bytes4) {
        return 0x150b7a02;
    }
}

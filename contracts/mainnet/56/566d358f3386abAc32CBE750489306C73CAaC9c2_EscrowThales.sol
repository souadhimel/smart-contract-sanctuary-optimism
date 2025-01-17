// SPDX-License-Identifier: MIT

pragma solidity ^0.5.16;

import "openzeppelin-solidity-2.3.0/contracts/math/SafeMath.sol";
import "openzeppelin-solidity-2.3.0/contracts/token/ERC20/SafeERC20.sol";

import "../utils/proxy/ProxyReentrancyGuard.sol";
import "../utils/proxy/ProxyOwned.sol";
import "../utils/proxy/ProxyPausable.sol";
import "@openzeppelin/upgrades-core/contracts/Initializable.sol";

import "../interfaces/IEscrowThales.sol";
import "../interfaces/IStakingThales.sol";
import "../interfaces/IThalesStakingRewardsPool.sol";

/// @title A Escrow contract that provides logic for escrow and vesting staking rewards
contract EscrowThales is IEscrowThales, Initializable, ProxyOwned, ProxyReentrancyGuard, ProxyPausable {
    using SafeMath for uint;
    using SafeERC20 for IERC20;

    IERC20 public vestingToken;
    IStakingThales public iStakingThales;
    address public airdropContract;

    uint public constant NUM_PERIODS = 10;
    uint public totalEscrowedRewards;
    uint public totalEscrowBalanceNotIncludedInStaking;
    uint public currentVestingPeriod;

    uint private _totalVested;

    struct VestingEntry {
        uint amount;
        uint vesting_period;
    }

    mapping(address => VestingEntry[NUM_PERIODS]) public vestingEntries;
    mapping(address => uint) public totalAccountEscrowedAmount;

    mapping(address => uint) public lastPeriodAddedReward;

    bool private testMode;
    IThalesStakingRewardsPool public ThalesStakingRewardsPool;

    /* ========== CONSTRUCTOR ========== */

    function initialize(
        address _owner,
        address _vestingToken //THALES
    ) public initializer {
        setOwner(_owner);
        initNonReentrant();
        vestingToken = IERC20(_vestingToken);
    }

    /* ========== VIEWS ========== */

    /// @notice Get the vesting period of specific vesting entry for the account
    /// @param account to get the vesting period for
    /// @param index of vesting entry to get vesting period for
    /// @return the vesting period
    function getStakerPeriod(address account, uint index) external view returns (uint) {
        require(account != address(0), "Invalid account address");
        return vestingEntries[account][index].vesting_period;
    }

    /// @notice Get the vesting amount of specific vesting entry for the account
    /// @param account to get the vesting amount for
    /// @param index of vesting entry to get vesting amount for
    /// @return the vesting amount for the account
    function getStakerAmounts(address account, uint index) external view returns (uint) {
        require(account != address(0), "Invalid account address");
        return vestingEntries[account][index].amount;
    }

    /// @notice Get the staked escrowed balance for the account
    /// @param account to get the staked escrowed balance for
    /// @return the staked escrowed balance for the account
    function getStakedEscrowedBalanceForRewards(address account) external view returns (uint) {
        if (lastPeriodAddedReward[account] == currentVestingPeriod) {
            return
                totalAccountEscrowedAmount[account].sub(
                    vestingEntries[account][currentVestingPeriod.mod(NUM_PERIODS)].amount
                );
        } else {
            return totalAccountEscrowedAmount[account];
        }
    }

    /// @notice Get the claimable vesting amount for the account
    /// @param account to get the claimable vesting amount for
    /// @return the claimable vesting amount for the account
    function claimable(address account) external view returns (uint) {
        require(account != address(0), "Invalid address");
        return totalAccountEscrowedAmount[account].sub(_getVestingNotAvailable(account));
    }

    /* ========== PUBLIC ========== */

    /// @notice Add the amount of staking token to the escrow for the account
    /// @param account to add the amount to the escrow for
    /// @param amount to add to the escrow
    function addToEscrow(address account, uint amount) external notPaused {
        require(account != address(0), "Invalid address");
        require(amount > 0, "Amount is 0");
        require(
            msg.sender == address(ThalesStakingRewardsPool) || msg.sender == airdropContract,
            "Add to escrow can only be called from staking or ongoing airdrop contracts"
        );

        totalAccountEscrowedAmount[account] = totalAccountEscrowedAmount[account].add(amount);

        if (lastPeriodAddedReward[account] == currentVestingPeriod) {
            vestingEntries[account][currentVestingPeriod.mod(NUM_PERIODS)].amount = vestingEntries[account][
                currentVestingPeriod.mod(NUM_PERIODS)
            ]
                .amount
                .add(amount);
        } else {
            vestingEntries[account][currentVestingPeriod.mod(NUM_PERIODS)].amount = amount;
        }
        vestingEntries[account][currentVestingPeriod.mod(NUM_PERIODS)].vesting_period = currentVestingPeriod.add(
            NUM_PERIODS
        );
        lastPeriodAddedReward[account] = currentVestingPeriod;

        totalEscrowedRewards = totalEscrowedRewards.add(amount);
        //Transfering THALES from StakingThales to EscrowThales
        vestingToken.safeTransferFrom(msg.sender, address(this), amount);

        // add to totalEscrowBalanceNotIncludedInStaking if user is not staking
        if (iStakingThales.stakedBalanceOf(account) == 0) {
            totalEscrowBalanceNotIncludedInStaking = totalEscrowBalanceNotIncludedInStaking.add(amount);
        }

        emit AddedToEscrow(account, amount);
    }

    /// @notice Vest the amount of escrowed tokens
    /// @param amount to vest
    function vest(uint amount) external nonReentrant notPaused returns (bool) {
        require(amount > 0, "Claimed amount is 0");
        require(currentVestingPeriod >= NUM_PERIODS, "Vesting rewards still not available");

        uint vestingAmount = 0;
        vestingAmount = totalAccountEscrowedAmount[msg.sender].sub(_getVestingNotAvailable(msg.sender));
        // Amount must be lower than the reward
        require(amount <= vestingAmount, "Amount exceeds the claimable rewards");
        totalAccountEscrowedAmount[msg.sender] = totalAccountEscrowedAmount[msg.sender].sub(amount);
        totalEscrowedRewards = totalEscrowedRewards.sub(amount);
        _totalVested = _totalVested.add(amount);
        vestingToken.safeTransfer(msg.sender, amount);

        // subtract from totalEscrowBalanceNotIncludedInStaking if user is not staking
        if (iStakingThales.stakedBalanceOf(msg.sender) == 0) {
            totalEscrowBalanceNotIncludedInStaking = totalEscrowBalanceNotIncludedInStaking.sub(amount);
        }

        emit Vested(msg.sender, amount);
        return true;
    }

    /// @notice Add the amount of tokens to the total escrow balance not included in staking
    /// @param amount to add
    function addTotalEscrowBalanceNotIncludedInStaking(uint amount) external {
        require(msg.sender == address(iStakingThales), "Can only be called from staking contract");
        totalEscrowBalanceNotIncludedInStaking = totalEscrowBalanceNotIncludedInStaking.add(amount);
    }

    /// @notice Subtract the amount of tokens form the total escrow balance not included in staking
    /// @param amount to subtract
    function subtractTotalEscrowBalanceNotIncludedInStaking(uint amount) external {
        require(msg.sender == address(iStakingThales), "Can only be called from staking contract");
        totalEscrowBalanceNotIncludedInStaking = totalEscrowBalanceNotIncludedInStaking.sub(amount);
    }

    /// @notice Update the current vesting period
    function updateCurrentPeriod() external returns (bool) {
        if (!testMode) {
            require(msg.sender == address(iStakingThales), "Can only be called from staking contract");
        }
        currentVestingPeriod = currentVestingPeriod.add(1);
        return true;
    }

    /// @notice Set address of Staking Thales contract
    /// @param StakingThalesContract address of Staking Thales contract
    function setStakingThalesContract(address StakingThalesContract) external onlyOwner {
        require(StakingThalesContract != address(0), "Invalid address set");
        iStakingThales = IStakingThales(StakingThalesContract);
        emit StakingThalesContractChanged(StakingThalesContract);
    }

    /// @notice Enable the test mode
    function enableTestMode() external onlyOwner {
        testMode = true;
    }

    /// @notice Set address of Airdrop contract
    /// @param AirdropContract address of Airdrop contract
    function setAirdropContract(address AirdropContract) external onlyOwner {
        require(AirdropContract != address(0), "Invalid address set");
        airdropContract = AirdropContract;
        emit AirdropContractChanged(AirdropContract);
    }

    /// @notice Set address of Thales staking rewards pool
    /// @param _thalesStakingRewardsPool address of Thales staking rewards pool
    function setThalesStakingRewardsPool(address _thalesStakingRewardsPool) public onlyOwner {
        require(_thalesStakingRewardsPool != address(0), "Invalid address");
        ThalesStakingRewardsPool = IThalesStakingRewardsPool(_thalesStakingRewardsPool);
        emit ThalesStakingRewardsPoolChanged(_thalesStakingRewardsPool);
    }

    /// @notice Fix the vesting entry for the account
    /// @param account to fix the vesting entry for
    function fixEscrowEntry(address account) external onlyOwner {
        vestingEntries[account][currentVestingPeriod.mod(NUM_PERIODS)].vesting_period = currentVestingPeriod.add(
            NUM_PERIODS
        );
    }

    /// @notice Merge account to transfer all escrow amounts to another account
    /// @param srcAccount to merge
    /// @param destAccount to merge into
    function mergeAccount(address srcAccount, address destAccount) external {
        require(msg.sender == address(iStakingThales), "Can only be called from staking contract");

        if (iStakingThales.stakedBalanceOf(srcAccount) == 0 && iStakingThales.stakedBalanceOf(destAccount) > 0) {
            if (totalAccountEscrowedAmount[srcAccount] > 0) {
                totalEscrowBalanceNotIncludedInStaking = totalEscrowBalanceNotIncludedInStaking.sub(
                    totalAccountEscrowedAmount[srcAccount]
                );
            }
        }
        if (iStakingThales.stakedBalanceOf(destAccount) == 0 && iStakingThales.stakedBalanceOf(srcAccount) > 0) {
            if (totalAccountEscrowedAmount[destAccount] > 0) {
                totalEscrowBalanceNotIncludedInStaking = totalEscrowBalanceNotIncludedInStaking.sub(
                    totalAccountEscrowedAmount[destAccount]
                );
            }
        }

        totalAccountEscrowedAmount[destAccount] = totalAccountEscrowedAmount[destAccount].add(
            totalAccountEscrowedAmount[srcAccount]
        );
        lastPeriodAddedReward[destAccount] = currentVestingPeriod;

        uint vestingEntriesIndex;
        uint vestingEntriesPeriod;
        for (uint i = 1; i <= NUM_PERIODS; i++) {
            vestingEntriesIndex = currentVestingPeriod.add(i).mod(NUM_PERIODS);
            vestingEntriesPeriod = currentVestingPeriod.add(i);

            if (vestingEntriesPeriod != vestingEntries[destAccount][vestingEntriesIndex].vesting_period) {
                vestingEntries[destAccount][vestingEntriesIndex].amount = 0;
                vestingEntries[destAccount][vestingEntriesIndex].vesting_period = vestingEntriesPeriod;
            }

            if (vestingEntriesPeriod == vestingEntries[srcAccount][vestingEntriesIndex].vesting_period) {
                vestingEntries[destAccount][vestingEntriesIndex].amount = vestingEntries[destAccount][vestingEntriesIndex]
                    .amount
                    .add(vestingEntries[srcAccount][vestingEntriesIndex].amount);
            }
        }

        delete totalAccountEscrowedAmount[srcAccount];
        delete lastPeriodAddedReward[srcAccount];
        delete vestingEntries[srcAccount];
    }

    /* ========== INTERNAL FUNCTIONS ========== */

    function _getVestingNotAvailable(address account) internal view returns (uint) {
        uint vesting_not_available = 0;
        for (uint i = 0; i < NUM_PERIODS; i++) {
            if (vestingEntries[account][i].vesting_period > currentVestingPeriod) {
                vesting_not_available = vesting_not_available.add(vestingEntries[account][i].amount);
            }
        }
        return vesting_not_available;
    }

    /* ========== EVENTS ========== */

    event AddedToEscrow(address acount, uint amount);
    event Vested(address account, uint amount);
    event StakingThalesContractChanged(address newAddress);
    event AirdropContractChanged(address newAddress);
    event ThalesStakingRewardsPoolChanged(address thalesStakingRewardsPool);
}

pragma solidity ^0.5.0;

/**
 * @dev Wrappers over Solidity's arithmetic operations with added overflow
 * checks.
 *
 * Arithmetic operations in Solidity wrap on overflow. This can easily result
 * in bugs, because programmers usually assume that an overflow raises an
 * error, which is the standard behavior in high level programming languages.
 * `SafeMath` restores this intuition by reverting the transaction when an
 * operation overflows.
 *
 * Using this library instead of the unchecked operations eliminates an entire
 * class of bugs, so it's recommended to use it always.
 */
library SafeMath {
    /**
     * @dev Returns the addition of two unsigned integers, reverting on
     * overflow.
     *
     * Counterpart to Solidity's `+` operator.
     *
     * Requirements:
     * - Addition cannot overflow.
     */
    function add(uint256 a, uint256 b) internal pure returns (uint256) {
        uint256 c = a + b;
        require(c >= a, "SafeMath: addition overflow");

        return c;
    }

    /**
     * @dev Returns the subtraction of two unsigned integers, reverting on
     * overflow (when the result is negative).
     *
     * Counterpart to Solidity's `-` operator.
     *
     * Requirements:
     * - Subtraction cannot overflow.
     */
    function sub(uint256 a, uint256 b) internal pure returns (uint256) {
        require(b <= a, "SafeMath: subtraction overflow");
        uint256 c = a - b;

        return c;
    }

    /**
     * @dev Returns the multiplication of two unsigned integers, reverting on
     * overflow.
     *
     * Counterpart to Solidity's `*` operator.
     *
     * Requirements:
     * - Multiplication cannot overflow.
     */
    function mul(uint256 a, uint256 b) internal pure returns (uint256) {
        // Gas optimization: this is cheaper than requiring 'a' not being zero, but the
        // benefit is lost if 'b' is also tested.
        // See: https://github.com/OpenZeppelin/openzeppelin-solidity/pull/522
        if (a == 0) {
            return 0;
        }

        uint256 c = a * b;
        require(c / a == b, "SafeMath: multiplication overflow");

        return c;
    }

    /**
     * @dev Returns the integer division of two unsigned integers. Reverts on
     * division by zero. The result is rounded towards zero.
     *
     * Counterpart to Solidity's `/` operator. Note: this function uses a
     * `revert` opcode (which leaves remaining gas untouched) while Solidity
     * uses an invalid opcode to revert (consuming all remaining gas).
     *
     * Requirements:
     * - The divisor cannot be zero.
     */
    function div(uint256 a, uint256 b) internal pure returns (uint256) {
        // Solidity only automatically asserts when dividing by 0
        require(b > 0, "SafeMath: division by zero");
        uint256 c = a / b;
        // assert(a == b * c + a % b); // There is no case in which this doesn't hold

        return c;
    }

    /**
     * @dev Returns the remainder of dividing two unsigned integers. (unsigned integer modulo),
     * Reverts when dividing by zero.
     *
     * Counterpart to Solidity's `%` operator. This function uses a `revert`
     * opcode (which leaves remaining gas untouched) while Solidity uses an
     * invalid opcode to revert (consuming all remaining gas).
     *
     * Requirements:
     * - The divisor cannot be zero.
     */
    function mod(uint256 a, uint256 b) internal pure returns (uint256) {
        require(b != 0, "SafeMath: modulo by zero");
        return a % b;
    }
}

pragma solidity ^0.5.0;

import "./IERC20.sol";
import "../../math/SafeMath.sol";
import "../../utils/Address.sol";

/**
 * @title SafeERC20
 * @dev Wrappers around ERC20 operations that throw on failure (when the token
 * contract returns false). Tokens that return no value (and instead revert or
 * throw on failure) are also supported, non-reverting calls are assumed to be
 * successful.
 * To use this library you can add a `using SafeERC20 for ERC20;` statement to your contract,
 * which allows you to call the safe operations as `token.safeTransfer(...)`, etc.
 */
library SafeERC20 {
    using SafeMath for uint256;
    using Address for address;

    function safeTransfer(IERC20 token, address to, uint256 value) internal {
        callOptionalReturn(token, abi.encodeWithSelector(token.transfer.selector, to, value));
    }

    function safeTransferFrom(IERC20 token, address from, address to, uint256 value) internal {
        callOptionalReturn(token, abi.encodeWithSelector(token.transferFrom.selector, from, to, value));
    }

    function safeApprove(IERC20 token, address spender, uint256 value) internal {
        // safeApprove should only be called when setting an initial allowance,
        // or when resetting it to zero. To increase and decrease it, use
        // 'safeIncreaseAllowance' and 'safeDecreaseAllowance'
        // solhint-disable-next-line max-line-length
        require((value == 0) || (token.allowance(address(this), spender) == 0),
            "SafeERC20: approve from non-zero to non-zero allowance"
        );
        callOptionalReturn(token, abi.encodeWithSelector(token.approve.selector, spender, value));
    }

    function safeIncreaseAllowance(IERC20 token, address spender, uint256 value) internal {
        uint256 newAllowance = token.allowance(address(this), spender).add(value);
        callOptionalReturn(token, abi.encodeWithSelector(token.approve.selector, spender, newAllowance));
    }

    function safeDecreaseAllowance(IERC20 token, address spender, uint256 value) internal {
        uint256 newAllowance = token.allowance(address(this), spender).sub(value);
        callOptionalReturn(token, abi.encodeWithSelector(token.approve.selector, spender, newAllowance));
    }

    /**
     * @dev Imitates a Solidity high-level call (i.e. a regular function call to a contract), relaxing the requirement
     * on the return value: the return value is optional (but if data is returned, it must not be false).
     * @param token The token targeted by the call.
     * @param data The call data (encoded using abi.encode or one of its variants).
     */
    function callOptionalReturn(IERC20 token, bytes memory data) private {
        // We need to perform a low level call here, to bypass Solidity's return data size checking mechanism, since
        // we're implementing it ourselves.

        // A Solidity high level call has three parts:
        //  1. The target address is checked to verify it contains contract code
        //  2. The call itself is made, and success asserted
        //  3. The return value is decoded, which in turn checks the size of the returned data.
        // solhint-disable-next-line max-line-length
        require(address(token).isContract(), "SafeERC20: call to non-contract");

        // solhint-disable-next-line avoid-low-level-calls
        (bool success, bytes memory returndata) = address(token).call(data);
        require(success, "SafeERC20: low-level call failed");

        if (returndata.length > 0) { // Return data is optional
            // solhint-disable-next-line max-line-length
            require(abi.decode(returndata, (bool)), "SafeERC20: ERC20 operation did not succeed");
        }
    }
}

// SPDX-License-Identifier: MIT

pragma solidity ^0.5.0;

/**
 * @dev Contract module that helps prevent reentrant calls to a function.
 *
 * Inheriting from `ReentrancyGuard` will make the `nonReentrant` modifier
 * available, which can be aplied to functions to make sure there are no nested
 * (reentrant) calls to them.
 *
 * Note that because there is a single `nonReentrant` guard, functions marked as
 * `nonReentrant` may not call one another. This can be worked around by making
 * those functions `private`, and then adding `external` `nonReentrant` entry
 * points to them.
 */
contract ProxyReentrancyGuard {
    /// @dev counter to allow mutex lock with only one SSTORE operation
    uint256 private _guardCounter;
    bool private _initialized;

    function initNonReentrant() public {
        require(!_initialized, "Already initialized");
        _initialized = true;
        _guardCounter = 1;
    }

    /**
     * @dev Prevents a contract from calling itself, directly or indirectly.
     * Calling a `nonReentrant` function from another `nonReentrant`
     * function is not supported. It is possible to prevent this from happening
     * by making the `nonReentrant` function external, and make it call a
     * `private` function that does the actual work.
     */
    modifier nonReentrant() {
        _guardCounter += 1;
        uint256 localCounter = _guardCounter;
        _;
        require(localCounter == _guardCounter, "ReentrancyGuard: reentrant call");
    }
}

// SPDX-License-Identifier: MIT

pragma solidity ^0.5.16;

// Clone of syntetix contract without constructor
contract ProxyOwned {
    address public owner;
    address public nominatedOwner;
    bool private _initialized;
    bool private _transferredAtInit;

    function setOwner(address _owner) public {
        require(_owner != address(0), "Owner address cannot be 0");
        require(!_initialized, "Already initialized, use nominateNewOwner");
        _initialized = true;
        owner = _owner;
        emit OwnerChanged(address(0), _owner);
    }

    function nominateNewOwner(address _owner) external onlyOwner {
        nominatedOwner = _owner;
        emit OwnerNominated(_owner);
    }

    function acceptOwnership() external {
        require(msg.sender == nominatedOwner, "You must be nominated before you can accept ownership");
        emit OwnerChanged(owner, nominatedOwner);
        owner = nominatedOwner;
        nominatedOwner = address(0);
    }

    function transferOwnershipAtInit(address proxyAddress) external onlyOwner {
        require(proxyAddress != address(0), "Invalid address");
        require(!_transferredAtInit, "Already transferred");
        owner = proxyAddress;
        _transferredAtInit = true;
        emit OwnerChanged(owner, proxyAddress);
    }

    modifier onlyOwner {
        _onlyOwner();
        _;
    }

    function _onlyOwner() private view {
        require(msg.sender == owner, "Only the contract owner may perform this action");
    }

    event OwnerNominated(address newOwner);
    event OwnerChanged(address oldOwner, address newOwner);
}

// SPDX-License-Identifier: MIT

pragma solidity ^0.5.16;

// Inheritance
import "./ProxyOwned.sol";

// Clone of syntetix contract without constructor

contract ProxyPausable is ProxyOwned {
    uint public lastPauseTime;
    bool public paused;

    

    /**
     * @notice Change the paused state of the contract
     * @dev Only the contract owner may call this.
     */
    function setPaused(bool _paused) external onlyOwner {
        // Ensure we're actually changing the state before we do anything
        if (_paused == paused) {
            return;
        }

        // Set our paused state.
        paused = _paused;

        // If applicable, set the last pause time.
        if (paused) {
            lastPauseTime = block.timestamp;
        }

        // Let everyone know that our pause state has changed.
        emit PauseChanged(paused);
    }

    event PauseChanged(bool isPaused);

    modifier notPaused {
        require(!paused, "This action cannot be performed while the contract is paused");
        _;
    }
}

// SPDX-License-Identifier: MIT

pragma solidity >=0.4.24 <0.7.0;


/**
 * @title Initializable
 *
 * @dev Helper contract to support initializer functions. To use it, replace
 * the constructor with a function that has the `initializer` modifier.
 * WARNING: Unlike constructors, initializer functions must be manually
 * invoked. This applies both to deploying an Initializable contract, as well
 * as extending an Initializable contract via inheritance.
 * WARNING: When used with inheritance, manual care must be taken to not invoke
 * a parent initializer twice, or ensure that all initializers are idempotent,
 * because this is not dealt with automatically as with constructors.
 */
contract Initializable {

  /**
   * @dev Indicates that the contract has been initialized.
   */
  bool private initialized;

  /**
   * @dev Indicates that the contract is in the process of being initialized.
   */
  bool private initializing;

  /**
   * @dev Modifier to use in the initializer function of a contract.
   */
  modifier initializer() {
    require(initializing || isConstructor() || !initialized, "Contract instance has already been initialized");

    bool isTopLevelCall = !initializing;
    if (isTopLevelCall) {
      initializing = true;
      initialized = true;
    }

    _;

    if (isTopLevelCall) {
      initializing = false;
    }
  }

  /// @dev Returns true if and only if the function is running in the constructor
  function isConstructor() private view returns (bool) {
    // extcodesize checks the size of the code stored in an address, and
    // address returns the current address. Since the code is still not
    // deployed when running a constructor, any checks on its code size will
    // yield zero, making it an effective way to detect if a contract is
    // under construction or not.
    address self = address(this);
    uint256 cs;
    assembly { cs := extcodesize(self) }
    return cs == 0;
  }

  // Reserved storage space to allow for layout changes in the future.
  uint256[50] private ______gap;
}

// SPDX-License-Identifier: MIT

pragma solidity >=0.5.16;

interface IEscrowThales {
    /* ========== VIEWS / VARIABLES ========== */
    function getStakerPeriod(address account, uint index) external view returns (uint);

    function getStakerAmounts(address account, uint index) external view returns (uint);

    function totalAccountEscrowedAmount(address account) external view returns (uint);

    function getStakedEscrowedBalanceForRewards(address account) external view returns (uint);

    function totalEscrowedRewards() external view returns (uint);

    function totalEscrowBalanceNotIncludedInStaking() external view returns (uint);

    function currentVestingPeriod() external view returns (uint);

    function updateCurrentPeriod() external returns (bool);

    function claimable(address account) external view returns (uint);

    function addToEscrow(address account, uint amount) external;

    function vest(uint amount) external returns (bool);

    function addTotalEscrowBalanceNotIncludedInStaking(uint amount) external;

    function subtractTotalEscrowBalanceNotIncludedInStaking(uint amount) external;

    function mergeAccount(address srcAccount, address destAccount) external;
}

// SPDX-License-Identifier: MIT

pragma solidity >=0.5.16;

interface IStakingThales {
    function updateVolume(address account, uint amount) external;

    /* ========== VIEWS / VARIABLES ========== */
    function totalStakedAmount() external view returns (uint);

    function stakedBalanceOf(address account) external view returns (uint);

    function currentPeriodRewards() external view returns (uint);

    function currentPeriodFees() external view returns (uint);

    function getLastPeriodOfClaimedRewards(address account) external view returns (uint);

    function getRewardsAvailable(address account) external view returns (uint);

    function getRewardFeesAvailable(address account) external view returns (uint);

    function getAlreadyClaimedRewards(address account) external view returns (uint);

    function getContractRewardFunds() external view returns (uint);

    function getContractFeeFunds() external view returns (uint);
}

// SPDX-License-Identifier: MIT

pragma solidity ^0.5.16;

interface IThalesStakingRewardsPool {
   
   function addToEscrow(address account, uint amount) external;

    
}

pragma solidity ^0.5.0;

/**
 * @dev Interface of the ERC20 standard as defined in the EIP. Does not include
 * the optional functions; to access them see `ERC20Detailed`.
 */
interface IERC20 {
    /**
     * @dev Returns the amount of tokens in existence.
     */
    function totalSupply() external view returns (uint256);

    /**
     * @dev Returns the amount of tokens owned by `account`.
     */
    function balanceOf(address account) external view returns (uint256);

    /**
     * @dev Moves `amount` tokens from the caller's account to `recipient`.
     *
     * Returns a boolean value indicating whether the operation succeeded.
     *
     * Emits a `Transfer` event.
     */
    function transfer(address recipient, uint256 amount) external returns (bool);

    /**
     * @dev Returns the remaining number of tokens that `spender` will be
     * allowed to spend on behalf of `owner` through `transferFrom`. This is
     * zero by default.
     *
     * This value changes when `approve` or `transferFrom` are called.
     */
    function allowance(address owner, address spender) external view returns (uint256);

    /**
     * @dev Sets `amount` as the allowance of `spender` over the caller's tokens.
     *
     * Returns a boolean value indicating whether the operation succeeded.
     *
     * > Beware that changing an allowance with this method brings the risk
     * that someone may use both the old and the new allowance by unfortunate
     * transaction ordering. One possible solution to mitigate this race
     * condition is to first reduce the spender's allowance to 0 and set the
     * desired value afterwards:
     * https://github.com/ethereum/EIPs/issues/20#issuecomment-263524729
     *
     * Emits an `Approval` event.
     */
    function approve(address spender, uint256 amount) external returns (bool);

    /**
     * @dev Moves `amount` tokens from `sender` to `recipient` using the
     * allowance mechanism. `amount` is then deducted from the caller's
     * allowance.
     *
     * Returns a boolean value indicating whether the operation succeeded.
     *
     * Emits a `Transfer` event.
     */
    function transferFrom(address sender, address recipient, uint256 amount) external returns (bool);

    /**
     * @dev Emitted when `value` tokens are moved from one account (`from`) to
     * another (`to`).
     *
     * Note that `value` may be zero.
     */
    event Transfer(address indexed from, address indexed to, uint256 value);

    /**
     * @dev Emitted when the allowance of a `spender` for an `owner` is set by
     * a call to `approve`. `value` is the new allowance.
     */
    event Approval(address indexed owner, address indexed spender, uint256 value);
}

pragma solidity ^0.5.0;

/**
 * @dev Collection of functions related to the address type,
 */
library Address {
    /**
     * @dev Returns true if `account` is a contract.
     *
     * This test is non-exhaustive, and there may be false-negatives: during the
     * execution of a contract's constructor, its address will be reported as
     * not containing a contract.
     *
     * > It is unsafe to assume that an address for which this function returns
     * false is an externally-owned account (EOA) and not a contract.
     */
    function isContract(address account) internal view returns (bool) {
        // This method relies in extcodesize, which returns 0 for contracts in
        // construction, since the code is only stored at the end of the
        // constructor execution.

        uint256 size;
        // solhint-disable-next-line no-inline-assembly
        assembly { size := extcodesize(account) }
        return size > 0;
    }
}
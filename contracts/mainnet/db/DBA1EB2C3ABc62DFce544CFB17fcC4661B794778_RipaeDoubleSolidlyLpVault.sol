pragma experimental ABIEncoderV2;
// SPDX-License-Identifier: MIT
pragma solidity 0.6.12;

import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/SafeERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";

import "../interfaces/IRewardPool.sol";
import "../interfaces/ISolidlyRouter.sol";
import "../interfaces/ISolidlyV1Pair.sol";
import "./IVault.sol";

interface IERC20Burnable is IERC20Upgradeable {
    function burn(uint256 amount) external;
}

contract RipaeDoubleSolidlyLpVault is ERC20Upgradeable, OwnableUpgradeable, ReentrancyGuardUpgradeable, PausableUpgradeable {
  using SafeERC20Upgradeable for IERC20Upgradeable;

  // user => rewardPerSharePaid
  mapping(address => uint) public userRewardPerSharePaid;
  uint public accRewardPerShare;

  IERC20Upgradeable public lp;
  IERC20Upgradeable public token0;
  IERC20Upgradeable public token1;
  bool public stable;
  IERC20Upgradeable public reward;
  IERC20Burnable public peg;
  uint public pid;
  IRewardPool public rewardPool;
  ISolidlyRouter public router;
  IERC20Upgradeable public rewardLp;
  IERC20Upgradeable public ripToken0;
  IERC20Upgradeable public ripToken1;
  IVault public ripRewardLp;
  ISolidlyRouter.route[] public rewardToLp0Route;
  ISolidlyRouter.route[] public rewardToLp1Route;
  ISolidlyRouter.route[] public rewardToPegRoute;
  ISolidlyRouter.route[] public rewardToUsdcRoute;
  ISolidlyRouter.route[] public rewardToRipLp0Route;
  ISolidlyRouter.route[] public rewardToRipLp1Route;
  address public govFeeRecipient;
  uint public govFee;
  uint public minHarvestAmount;
  uint public lastHarvest;
  bool public harvestOnWithdraw;
  bool public rewardPoolHasTotalSupply;

  event Deposit(address indexed user, uint amount, uint shares);
  event Withdraw(address indexed user, uint amount, uint shares);
  event Harvest(uint deposit);

  function initialize(
    ISolidlyV1Pair _lp,
    IERC20Upgradeable _reward,
    uint _pid,
    IRewardPool _rewardPool,
    ISolidlyRouter _router,
    IVault _ripRewardLp,
    ISolidlyRouter.route[] memory _rewardToLp0Route,
    ISolidlyRouter.route[] memory _rewardToLp1Route,
    ISolidlyRouter.route[] memory _rewardToPegRoute,
    ISolidlyRouter.route[] memory _rewardToUsdcRoute,
    ISolidlyRouter.route[] memory _rewardToRipLp0Route,
    ISolidlyRouter.route[] memory _rewardToRipLp1Route
  ) public initializer {
    lp = IERC20Upgradeable(address(_lp));
    token0 = IERC20Upgradeable(_lp.token0());
    token1 = IERC20Upgradeable(_lp.token1());
    stable = _lp.stable();
    reward = _reward;
    pid = _pid;
    rewardPool = _rewardPool;
    router = _router;
    ISolidlyV1Pair _rewardLp = ISolidlyV1Pair(_ripRewardLp.lp());
    rewardLp = IERC20Upgradeable(address(_rewardLp));
    ripToken0 = IERC20Upgradeable(_rewardLp.token0());
    ripToken1 = IERC20Upgradeable(_rewardLp.token1());
    ripRewardLp = _ripRewardLp;
    govFee = 5; // 5%
    minHarvestAmount = 1e17;
    harvestOnWithdraw = true;

    require(_rewardToLp0Route.length > 0, "empty _rewardToLp0Route");
    require(_rewardToLp1Route.length > 0, "empty _rewardToLp1Route");
    require(_rewardToPegRoute.length > 0, "empty _rewardToPegRoute");
    require(_rewardToUsdcRoute.length > 0, "empty _rewardToUsdcRoute");
    _setRoutes(_rewardToLp0Route, _rewardToLp1Route, _rewardToPegRoute, _rewardToUsdcRoute, _rewardToRipLp0Route, _rewardToRipLp1Route);

    lp.approve(address(rewardPool), type(uint).max);
    reward.approve(address(router), type(uint).max);
    rewardLp.approve(address(ripRewardLp), type(uint).max);
    token0.approve(address(router), 0);
    token0.approve(address(router), type(uint).max);
    token1.approve(address(router), 0);
    token1.approve(address(router), type(uint).max);
    ripToken0.approve(address(router), 0);
    ripToken0.approve(address(router), type(uint).max);
    ripToken1.approve(address(router), 0);
    ripToken1.approve(address(router), type(uint).max);

    __ERC20_init(
      string(abi.encodePacked("Ripae Double", _lp.symbol())),
      string(abi.encodePacked("rip-double-", _lp.symbol()))
    );
    __Ownable_init();
    __ReentrancyGuard_init();
    __Pausable_init();
  }

  function upgrade() external onlyOwner {
      rewardLp.approve(address(ripRewardLp), type(uint).max);
  }

  function _setRoutes(
    ISolidlyRouter.route[] memory _rewardToLp0Route,
    ISolidlyRouter.route[] memory _rewardToLp1Route,
    ISolidlyRouter.route[] memory _rewardToPegRoute,
    ISolidlyRouter.route[] memory _rewardToUsdcRoute,
    ISolidlyRouter.route[] memory _rewardToRipLp0Route,
    ISolidlyRouter.route[] memory _rewardToRipLp1Route
  ) internal {
    if (_rewardToLp0Route.length > 0) {
      delete rewardToLp0Route;
      require(_rewardToLp0Route[0].from == address(reward), "!swap from reward to token0");
      require(_rewardToLp0Route[_rewardToLp0Route.length - 1].to == address(token0), "!swap to token0");
      for (uint i; i < _rewardToLp0Route.length; i++) {
        rewardToLp0Route.push(_rewardToLp0Route[i]);
      }
    }
    if (_rewardToLp1Route.length > 0) {
      delete rewardToLp1Route;
      require(_rewardToLp1Route[0].from == address(reward), "!swap from reward to token1");
      require(_rewardToLp1Route[_rewardToLp1Route.length - 1].to == address(token1), "!swap to token1");
      for (uint i; i < _rewardToLp1Route.length; i++) {
        rewardToLp1Route.push(_rewardToLp1Route[i]);
      }
    }
    if (_rewardToPegRoute.length > 0) {
        delete rewardToPegRoute;
        require(_rewardToPegRoute[0].from == address(reward), "!swap from reward to peg");
        for (uint i; i < _rewardToPegRoute.length; i++) {
            rewardToPegRoute.push(_rewardToPegRoute[i]);
        }
        peg = IERC20Burnable(_rewardToPegRoute[_rewardToPegRoute.length - 1].to);
    }
    if (_rewardToUsdcRoute.length > 0) {
      delete rewardToUsdcRoute;
      require(_rewardToUsdcRoute[0].from == address(reward), "!swap from reward to usd");
      for (uint i; i < _rewardToUsdcRoute.length; i++) {
        rewardToUsdcRoute.push(_rewardToUsdcRoute[i]);
      }
    }
    if (_rewardToRipLp0Route.length > 0) {
        delete rewardToRipLp0Route;
        require(_rewardToRipLp0Route[0].from == address(reward), "!swap from reward to ripLp0");
        for (uint i; i < _rewardToRipLp0Route.length; i++) {
            rewardToRipLp0Route.push(_rewardToRipLp0Route[i]);
        }
    }
    if (_rewardToRipLp1Route.length > 0) {
        delete rewardToRipLp1Route;
        require(_rewardToRipLp1Route[0].from == address(reward), "!swap from reward to ripLp1");
        for (uint i; i < _rewardToRipLp1Route.length; i++) {
            rewardToRipLp1Route.push(_rewardToRipLp1Route[i]);
        }
    }
  }

  // balance of LP + deposited into reward pool
  function balance() public view returns (uint) {
    return lp.balanceOf(address(this)).add(balanceDeposited());
  }

  // balance of LP deposited into reward pool
  function balanceDeposited() public view returns (uint) {
    (uint256 amount, ) = rewardPool.userInfo(pid, address(this));
    return amount;
  }

  // LP amount per 1 ripToken
  function pricePerShare() public view returns (uint256) {
    return totalSupply() == 0 ? 1e18 : balance().mul(1e18).div(totalSupply());
  }

  function depositAll() external {
    deposit(lp.balanceOf(msg.sender));
  }

  // harvest pending reward, deposit LP
  function deposit(uint _amount) public nonReentrant whenNotPaused {
    require(_amount > 0, "Cant deposit 0");
    harvestIfEnoughRewards();
    _claim();

    uint _pool = balance();
    IERC20Upgradeable(address(lp)).safeTransferFrom(msg.sender, address(this), _amount);
    rewardPool.deposit(pid, lp.balanceOf(address(this)));
    uint256 _after = balance();
    _amount = _after.sub(_pool);
    uint256 shares = 0;
    if (totalSupply() == 0) {
      shares = _amount;
    } else {
      shares = (_amount.mul(totalSupply())).div(_pool);
    }
    _mint(msg.sender, shares);
    emit Deposit(msg.sender, _amount, shares);
  }

  function withdrawAll() external {
    withdraw(balanceOf(msg.sender));
  }

  // withdraw LP, burn ripToken
  function withdraw(uint256 _shares) public nonReentrant {
    if (harvestOnWithdraw) {
      harvestIfEnoughRewards();
    }

    _claim();
    uint256 amount = (balance().mul(_shares)).div(totalSupply());
    _burn(msg.sender, _shares);

    uint bal = lp.balanceOf(address(this));
    if (bal < amount) {
      uint _withdraw = amount.sub(bal);
      rewardPool.withdraw(pid, _withdraw);
      uint _after = lp.balanceOf(address(this));
      uint _diff = _after.sub(bal);
      if (_diff < _withdraw) {
        amount = bal.add(_diff);
      }
    }

    IERC20Upgradeable(address(lp)).safeTransfer(msg.sender, amount);
    emit Withdraw(msg.sender, amount, _shares);
  }

  function pendingReward(address _user) public view returns (uint) {
    return accRewardPerShare.sub(userRewardPerSharePaid[_user]).mul(balanceOf(_user)) / 1e18;
  }

  function pendingRewardWrite(address _user) external returns (uint) {
    harvestIfEnoughRewards();
    return pendingReward(_user);
  }

  function claim() external {
    harvestIfEnoughRewards();
    _claim();
  }

  function _claim() internal {
    uint pending = pendingReward(msg.sender);
    if (pending > 0) {
      IERC20Upgradeable(address(ripRewardLp)).safeTransfer(msg.sender, pending);
    }
    userRewardPerSharePaid[msg.sender] = accRewardPerShare;
  }

  function claimableRewards() public view returns (uint _rewards) {
    return rewardPool.pendingPAE(pid, address(this));
  }

  // claim reward if > 0.1 pending, charge gov fee, build LP
  function harvestIfEnoughRewards() public {
    uint rewards = claimableRewards();
    if (rewards >= minHarvestAmount) {
      rewardPool.deposit(pid, 0);

      _chargeFees();
      _addLiquidity();
      _addRewardLiquidity();

      uint depositBal = lp.balanceOf(address(this));
      rewardPool.deposit(pid, depositBal);

      uint balBefore = ripRewardLp.balanceOf(address(this));
      ripRewardLp.depositAll();
      uint harvestedBal = ripRewardLp.balanceOf(address(this)).sub(balBefore);
      if (totalSupply() > 0) {
        accRewardPerShare = accRewardPerShare.add(harvestedBal.mul(1e18).div(totalSupply()));
      }

      emit Harvest(depositBal);
      lastHarvest = block.timestamp;
    }
  }

  function _chargeFees() internal {
    uint rewardBal = reward.balanceOf(address(this)).mul(govFee).div(100);
    if (rewardBal > 0) {
      if (govFeeRecipient != address(0)) {
          router.swapExactTokensForTokens(rewardBal, 0, rewardToPegRoute, govFeeRecipient, block.timestamp);
      } else {
          router.swapExactTokensForTokens(rewardBal, 0, rewardToPegRoute, address(this), block.timestamp);
          peg.burn(peg.balanceOf(address(this)));
      }
    }
  }

  function _addLiquidity() internal {
    uint rewardBal = reward.balanceOf(address(this)).div(2);
    uint rewardToLp0 = rewardBal.div(2);
    uint rewardToLp1 = rewardBal.sub(rewardToLp0);

    if (stable) {
      uint out0 = router.getAmountsOut(rewardToLp0, rewardToLp0Route)[rewardToLp0Route.length];
      uint out1 = router.getAmountsOut(rewardToLp1, rewardToLp1Route)[rewardToLp1Route.length];
      (uint amountA, uint amountB,) = router.quoteAddLiquidity(address(token0), address(token1), stable, out0, out1);
      uint ratio = out0.mul(1e18).div(out1).mul(amountB).div(amountA);
      rewardToLp0 = rewardBal.mul(1e18).div(ratio.add(1e18));
      rewardToLp1 = rewardBal.sub(rewardToLp0);
    }

    if (reward != token0) {
      router.swapExactTokensForTokens(rewardToLp0, 0, rewardToLp0Route, address(this), block.timestamp);
    }
    if (reward != token1) {
      router.swapExactTokensForTokens(rewardToLp1, 0, rewardToLp1Route, address(this), block.timestamp);
    }

    uint lp0Bal = token0.balanceOf(address(this));
    uint lp1Bal = token1.balanceOf(address(this));
    router.addLiquidity(address(token0), address(token1), stable, lp0Bal, lp1Bal, 0, 0, address(this), block.timestamp);
  }

  function _addRewardLiquidity() internal {
    uint rewardBal = reward.balanceOf(address(this));
    uint rewardToLp0 = rewardBal.div(2);
    uint rewardToLp1 = rewardBal.sub(rewardToLp0);

    if (reward != ripToken0) {
      router.swapExactTokensForTokens(rewardToLp0, 0, rewardToRipLp0Route, address(this), block.timestamp);
    }
    if (reward != ripToken1) {
      router.swapExactTokensForTokens(rewardToLp1, 0, rewardToRipLp1Route, address(this), block.timestamp);
    }

    uint lp0Bal = ripToken0.balanceOf(address(this));
    uint lp1Bal = ripToken1.balanceOf(address(this));
    router.addLiquidity(address(ripToken0), address(ripToken1), false, lp0Bal, lp1Bal, 0, 0, address(this), block.timestamp);
  }

  function setRoutes(
    ISolidlyRouter.route[] memory _rewardToLp0Route,
    ISolidlyRouter.route[] memory _rewardToLp1Route,
    ISolidlyRouter.route[] memory _rewardToPegRoute,
    ISolidlyRouter.route[] memory _rewardToUsdcRoute,
    ISolidlyRouter.route[] memory _rewardToRipLp0Route,
    ISolidlyRouter.route[] memory _rewardToRipLp1Route
  ) external onlyOwner {
    _setRoutes(_rewardToLp0Route, _rewardToLp1Route, _rewardToPegRoute, _rewardToUsdcRoute, _rewardToRipLp0Route, _rewardToRipLp1Route);
  }

  function setMinHarvestAmount(uint _amount) external onlyOwner {
    minHarvestAmount = _amount;
  }

  function setGovFee(uint _fee) external onlyOwner {
    govFee = _fee;
  }

  function setGovFeeRecipient(address _recipient) external onlyOwner {
    govFeeRecipient = _recipient;
  }

  function setHarvestOnWithdraw(bool _harvest) external onlyOwner {
    harvestOnWithdraw = _harvest;
  }

  function setHasTotalSupply(bool _rewardPoolHasTotalSupply) external onlyOwner {
    rewardPoolHasTotalSupply = _rewardPoolHasTotalSupply;
  }

  function panic() external onlyOwner {
    rewardPool.emergencyWithdraw(pid);
    harvestOnWithdraw = false;
    _pause();
  }

  function pause() external onlyOwner {
    harvestOnWithdraw = false;
    _pause();
  }

  function unpause() external onlyOwner {
    _unpause();
  }

  // ripToken transfers not allowed due to claimable reward
  function _transfer(address, address, uint256) override internal virtual {
    revert();
  }

  function recoverToken(IERC20Upgradeable token) external onlyOwner {
    require(address(token) != address(lp), "!lp");
    token.transfer(owner(), token.balanceOf(address(this)));
  }

  function stat() external view returns (uint vaultTvl, uint totalStakedLP, uint totalRewardsUsd) {
    vaultTvl = balance();
    totalStakedLP = totalStaked();
    totalRewardsUsd = yearlyUsdRewards();
  }

  function totalStaked() public view returns (uint) {
    if (rewardPoolHasTotalSupply) {
        return rewardPool.totalSupply(pid);
    } else {
        return lp.balanceOf(address(rewardPool));
    }
  }

  function yearlyUsdRewards() public view returns (uint) {
    uint rewardPerSecond = rewardPool.paePerSecond();
    (, uint alloc) = rewardPool.poolInfo(pid);
    uint totalAlloc = rewardPool.totalAllocPoint();

    uint rewardPerYear = rewardPerSecond * 31536000 * alloc / totalAlloc;
    uint usdcPerReward = router.getAmountsOut(1e18, rewardToUsdcRoute)[rewardToUsdcRoute.length];
    return rewardPerYear * usdcPerReward / 1e6;
  }
}

// SPDX-License-Identifier: MIT

pragma solidity >=0.6.0 <0.8.0;

import "../utils/ContextUpgradeable.sol";
import "../proxy/Initializable.sol";
/**
 * @dev Contract module which provides a basic access control mechanism, where
 * there is an account (an owner) that can be granted exclusive access to
 * specific functions.
 *
 * By default, the owner account will be the one that deploys the contract. This
 * can later be changed with {transferOwnership}.
 *
 * This module is used through inheritance. It will make available the modifier
 * `onlyOwner`, which can be applied to your functions to restrict their use to
 * the owner.
 */
abstract contract OwnableUpgradeable is Initializable, ContextUpgradeable {
    address private _owner;

    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    /**
     * @dev Initializes the contract setting the deployer as the initial owner.
     */
    function __Ownable_init() internal initializer {
        __Context_init_unchained();
        __Ownable_init_unchained();
    }

    function __Ownable_init_unchained() internal initializer {
        address msgSender = _msgSender();
        _owner = msgSender;
        emit OwnershipTransferred(address(0), msgSender);
    }

    /**
     * @dev Returns the address of the current owner.
     */
    function owner() public view virtual returns (address) {
        return _owner;
    }

    /**
     * @dev Throws if called by any account other than the owner.
     */
    modifier onlyOwner() {
        require(owner() == _msgSender(), "Ownable: caller is not the owner");
        _;
    }

    /**
     * @dev Leaves the contract without owner. It will not be possible to call
     * `onlyOwner` functions anymore. Can only be called by the current owner.
     *
     * NOTE: Renouncing ownership will leave the contract without an owner,
     * thereby removing any functionality that is only available to the owner.
     */
    function renounceOwnership() public virtual onlyOwner {
        emit OwnershipTransferred(_owner, address(0));
        _owner = address(0);
    }

    /**
     * @dev Transfers ownership of the contract to a new account (`newOwner`).
     * Can only be called by the current owner.
     */
    function transferOwnership(address newOwner) public virtual onlyOwner {
        require(newOwner != address(0), "Ownable: new owner is the zero address");
        emit OwnershipTransferred(_owner, newOwner);
        _owner = newOwner;
    }
    uint256[49] private __gap;
}

// SPDX-License-Identifier: MIT

pragma solidity >=0.6.0 <0.8.0;

import "../../utils/ContextUpgradeable.sol";
import "./IERC20Upgradeable.sol";
import "../../math/SafeMathUpgradeable.sol";
import "../../proxy/Initializable.sol";

/**
 * @dev Implementation of the {IERC20} interface.
 *
 * This implementation is agnostic to the way tokens are created. This means
 * that a supply mechanism has to be added in a derived contract using {_mint}.
 * For a generic mechanism see {ERC20PresetMinterPauser}.
 *
 * TIP: For a detailed writeup see our guide
 * https://forum.zeppelin.solutions/t/how-to-implement-erc20-supply-mechanisms/226[How
 * to implement supply mechanisms].
 *
 * We have followed general OpenZeppelin guidelines: functions revert instead
 * of returning `false` on failure. This behavior is nonetheless conventional
 * and does not conflict with the expectations of ERC20 applications.
 *
 * Additionally, an {Approval} event is emitted on calls to {transferFrom}.
 * This allows applications to reconstruct the allowance for all accounts just
 * by listening to said events. Other implementations of the EIP may not emit
 * these events, as it isn't required by the specification.
 *
 * Finally, the non-standard {decreaseAllowance} and {increaseAllowance}
 * functions have been added to mitigate the well-known issues around setting
 * allowances. See {IERC20-approve}.
 */
contract ERC20Upgradeable is Initializable, ContextUpgradeable, IERC20Upgradeable {
    using SafeMathUpgradeable for uint256;

    mapping (address => uint256) private _balances;

    mapping (address => mapping (address => uint256)) private _allowances;

    uint256 private _totalSupply;

    string private _name;
    string private _symbol;
    uint8 private _decimals;

    /**
     * @dev Sets the values for {name} and {symbol}, initializes {decimals} with
     * a default value of 18.
     *
     * To select a different value for {decimals}, use {_setupDecimals}.
     *
     * All three of these values are immutable: they can only be set once during
     * construction.
     */
    function __ERC20_init(string memory name_, string memory symbol_) internal initializer {
        __Context_init_unchained();
        __ERC20_init_unchained(name_, symbol_);
    }

    function __ERC20_init_unchained(string memory name_, string memory symbol_) internal initializer {
        _name = name_;
        _symbol = symbol_;
        _decimals = 18;
    }

    /**
     * @dev Returns the name of the token.
     */
    function name() public view virtual returns (string memory) {
        return _name;
    }

    /**
     * @dev Returns the symbol of the token, usually a shorter version of the
     * name.
     */
    function symbol() public view virtual returns (string memory) {
        return _symbol;
    }

    /**
     * @dev Returns the number of decimals used to get its user representation.
     * For example, if `decimals` equals `2`, a balance of `505` tokens should
     * be displayed to a user as `5,05` (`505 / 10 ** 2`).
     *
     * Tokens usually opt for a value of 18, imitating the relationship between
     * Ether and Wei. This is the value {ERC20} uses, unless {_setupDecimals} is
     * called.
     *
     * NOTE: This information is only used for _display_ purposes: it in
     * no way affects any of the arithmetic of the contract, including
     * {IERC20-balanceOf} and {IERC20-transfer}.
     */
    function decimals() public view virtual returns (uint8) {
        return _decimals;
    }

    /**
     * @dev See {IERC20-totalSupply}.
     */
    function totalSupply() public view virtual override returns (uint256) {
        return _totalSupply;
    }

    /**
     * @dev See {IERC20-balanceOf}.
     */
    function balanceOf(address account) public view virtual override returns (uint256) {
        return _balances[account];
    }

    /**
     * @dev See {IERC20-transfer}.
     *
     * Requirements:
     *
     * - `recipient` cannot be the zero address.
     * - the caller must have a balance of at least `amount`.
     */
    function transfer(address recipient, uint256 amount) public virtual override returns (bool) {
        _transfer(_msgSender(), recipient, amount);
        return true;
    }

    /**
     * @dev See {IERC20-allowance}.
     */
    function allowance(address owner, address spender) public view virtual override returns (uint256) {
        return _allowances[owner][spender];
    }

    /**
     * @dev See {IERC20-approve}.
     *
     * Requirements:
     *
     * - `spender` cannot be the zero address.
     */
    function approve(address spender, uint256 amount) public virtual override returns (bool) {
        _approve(_msgSender(), spender, amount);
        return true;
    }

    /**
     * @dev See {IERC20-transferFrom}.
     *
     * Emits an {Approval} event indicating the updated allowance. This is not
     * required by the EIP. See the note at the beginning of {ERC20}.
     *
     * Requirements:
     *
     * - `sender` and `recipient` cannot be the zero address.
     * - `sender` must have a balance of at least `amount`.
     * - the caller must have allowance for ``sender``'s tokens of at least
     * `amount`.
     */
    function transferFrom(address sender, address recipient, uint256 amount) public virtual override returns (bool) {
        _transfer(sender, recipient, amount);
        _approve(sender, _msgSender(), _allowances[sender][_msgSender()].sub(amount, "ERC20: transfer amount exceeds allowance"));
        return true;
    }

    /**
     * @dev Atomically increases the allowance granted to `spender` by the caller.
     *
     * This is an alternative to {approve} that can be used as a mitigation for
     * problems described in {IERC20-approve}.
     *
     * Emits an {Approval} event indicating the updated allowance.
     *
     * Requirements:
     *
     * - `spender` cannot be the zero address.
     */
    function increaseAllowance(address spender, uint256 addedValue) public virtual returns (bool) {
        _approve(_msgSender(), spender, _allowances[_msgSender()][spender].add(addedValue));
        return true;
    }

    /**
     * @dev Atomically decreases the allowance granted to `spender` by the caller.
     *
     * This is an alternative to {approve} that can be used as a mitigation for
     * problems described in {IERC20-approve}.
     *
     * Emits an {Approval} event indicating the updated allowance.
     *
     * Requirements:
     *
     * - `spender` cannot be the zero address.
     * - `spender` must have allowance for the caller of at least
     * `subtractedValue`.
     */
    function decreaseAllowance(address spender, uint256 subtractedValue) public virtual returns (bool) {
        _approve(_msgSender(), spender, _allowances[_msgSender()][spender].sub(subtractedValue, "ERC20: decreased allowance below zero"));
        return true;
    }

    /**
     * @dev Moves tokens `amount` from `sender` to `recipient`.
     *
     * This is internal function is equivalent to {transfer}, and can be used to
     * e.g. implement automatic token fees, slashing mechanisms, etc.
     *
     * Emits a {Transfer} event.
     *
     * Requirements:
     *
     * - `sender` cannot be the zero address.
     * - `recipient` cannot be the zero address.
     * - `sender` must have a balance of at least `amount`.
     */
    function _transfer(address sender, address recipient, uint256 amount) internal virtual {
        require(sender != address(0), "ERC20: transfer from the zero address");
        require(recipient != address(0), "ERC20: transfer to the zero address");

        _beforeTokenTransfer(sender, recipient, amount);

        _balances[sender] = _balances[sender].sub(amount, "ERC20: transfer amount exceeds balance");
        _balances[recipient] = _balances[recipient].add(amount);
        emit Transfer(sender, recipient, amount);
    }

    /** @dev Creates `amount` tokens and assigns them to `account`, increasing
     * the total supply.
     *
     * Emits a {Transfer} event with `from` set to the zero address.
     *
     * Requirements:
     *
     * - `to` cannot be the zero address.
     */
    function _mint(address account, uint256 amount) internal virtual {
        require(account != address(0), "ERC20: mint to the zero address");

        _beforeTokenTransfer(address(0), account, amount);

        _totalSupply = _totalSupply.add(amount);
        _balances[account] = _balances[account].add(amount);
        emit Transfer(address(0), account, amount);
    }

    /**
     * @dev Destroys `amount` tokens from `account`, reducing the
     * total supply.
     *
     * Emits a {Transfer} event with `to` set to the zero address.
     *
     * Requirements:
     *
     * - `account` cannot be the zero address.
     * - `account` must have at least `amount` tokens.
     */
    function _burn(address account, uint256 amount) internal virtual {
        require(account != address(0), "ERC20: burn from the zero address");

        _beforeTokenTransfer(account, address(0), amount);

        _balances[account] = _balances[account].sub(amount, "ERC20: burn amount exceeds balance");
        _totalSupply = _totalSupply.sub(amount);
        emit Transfer(account, address(0), amount);
    }

    /**
     * @dev Sets `amount` as the allowance of `spender` over the `owner` s tokens.
     *
     * This internal function is equivalent to `approve`, and can be used to
     * e.g. set automatic allowances for certain subsystems, etc.
     *
     * Emits an {Approval} event.
     *
     * Requirements:
     *
     * - `owner` cannot be the zero address.
     * - `spender` cannot be the zero address.
     */
    function _approve(address owner, address spender, uint256 amount) internal virtual {
        require(owner != address(0), "ERC20: approve from the zero address");
        require(spender != address(0), "ERC20: approve to the zero address");

        _allowances[owner][spender] = amount;
        emit Approval(owner, spender, amount);
    }

    /**
     * @dev Sets {decimals} to a value other than the default one of 18.
     *
     * WARNING: This function should only be called from the constructor. Most
     * applications that interact with token contracts will not expect
     * {decimals} to ever change, and may work incorrectly if it does.
     */
    function _setupDecimals(uint8 decimals_) internal virtual {
        _decimals = decimals_;
    }

    /**
     * @dev Hook that is called before any transfer of tokens. This includes
     * minting and burning.
     *
     * Calling conditions:
     *
     * - when `from` and `to` are both non-zero, `amount` of ``from``'s tokens
     * will be to transferred to `to`.
     * - when `from` is zero, `amount` tokens will be minted for `to`.
     * - when `to` is zero, `amount` of ``from``'s tokens will be burned.
     * - `from` and `to` are never both zero.
     *
     * To learn more about hooks, head to xref:ROOT:extending-contracts.adoc#using-hooks[Using Hooks].
     */
    function _beforeTokenTransfer(address from, address to, uint256 amount) internal virtual { }
    uint256[44] private __gap;
}

// SPDX-License-Identifier: MIT

pragma solidity >=0.6.0 <0.8.0;

import "./IERC20Upgradeable.sol";
import "../../math/SafeMathUpgradeable.sol";
import "../../utils/AddressUpgradeable.sol";

/**
 * @title SafeERC20
 * @dev Wrappers around ERC20 operations that throw on failure (when the token
 * contract returns false). Tokens that return no value (and instead revert or
 * throw on failure) are also supported, non-reverting calls are assumed to be
 * successful.
 * To use this library you can add a `using SafeERC20 for IERC20;` statement to your contract,
 * which allows you to call the safe operations as `token.safeTransfer(...)`, etc.
 */
library SafeERC20Upgradeable {
    using SafeMathUpgradeable for uint256;
    using AddressUpgradeable for address;

    function safeTransfer(IERC20Upgradeable token, address to, uint256 value) internal {
        _callOptionalReturn(token, abi.encodeWithSelector(token.transfer.selector, to, value));
    }

    function safeTransferFrom(IERC20Upgradeable token, address from, address to, uint256 value) internal {
        _callOptionalReturn(token, abi.encodeWithSelector(token.transferFrom.selector, from, to, value));
    }

    /**
     * @dev Deprecated. This function has issues similar to the ones found in
     * {IERC20-approve}, and its usage is discouraged.
     *
     * Whenever possible, use {safeIncreaseAllowance} and
     * {safeDecreaseAllowance} instead.
     */
    function safeApprove(IERC20Upgradeable token, address spender, uint256 value) internal {
        // safeApprove should only be called when setting an initial allowance,
        // or when resetting it to zero. To increase and decrease it, use
        // 'safeIncreaseAllowance' and 'safeDecreaseAllowance'
        // solhint-disable-next-line max-line-length
        require((value == 0) || (token.allowance(address(this), spender) == 0),
            "SafeERC20: approve from non-zero to non-zero allowance"
        );
        _callOptionalReturn(token, abi.encodeWithSelector(token.approve.selector, spender, value));
    }

    function safeIncreaseAllowance(IERC20Upgradeable token, address spender, uint256 value) internal {
        uint256 newAllowance = token.allowance(address(this), spender).add(value);
        _callOptionalReturn(token, abi.encodeWithSelector(token.approve.selector, spender, newAllowance));
    }

    function safeDecreaseAllowance(IERC20Upgradeable token, address spender, uint256 value) internal {
        uint256 newAllowance = token.allowance(address(this), spender).sub(value, "SafeERC20: decreased allowance below zero");
        _callOptionalReturn(token, abi.encodeWithSelector(token.approve.selector, spender, newAllowance));
    }

    /**
     * @dev Imitates a Solidity high-level call (i.e. a regular function call to a contract), relaxing the requirement
     * on the return value: the return value is optional (but if data is returned, it must not be false).
     * @param token The token targeted by the call.
     * @param data The call data (encoded using abi.encode or one of its variants).
     */
    function _callOptionalReturn(IERC20Upgradeable token, bytes memory data) private {
        // We need to perform a low level call here, to bypass Solidity's return data size checking mechanism, since
        // we're implementing it ourselves. We use {Address.functionCall} to perform this call, which verifies that
        // the target address contains contract code and also asserts for success in the low-level call.

        bytes memory returndata = address(token).functionCall(data, "SafeERC20: low-level call failed");
        if (returndata.length > 0) { // Return data is optional
            // solhint-disable-next-line max-line-length
            require(abi.decode(returndata, (bool)), "SafeERC20: ERC20 operation did not succeed");
        }
    }
}

// SPDX-License-Identifier: MIT

pragma solidity >=0.6.0 <0.8.0;
import "../proxy/Initializable.sol";

/**
 * @dev Contract module that helps prevent reentrant calls to a function.
 *
 * Inheriting from `ReentrancyGuard` will make the {nonReentrant} modifier
 * available, which can be applied to functions to make sure there are no nested
 * (reentrant) calls to them.
 *
 * Note that because there is a single `nonReentrant` guard, functions marked as
 * `nonReentrant` may not call one another. This can be worked around by making
 * those functions `private`, and then adding `external` `nonReentrant` entry
 * points to them.
 *
 * TIP: If you would like to learn more about reentrancy and alternative ways
 * to protect against it, check out our blog post
 * https://blog.openzeppelin.com/reentrancy-after-istanbul/[Reentrancy After Istanbul].
 */
abstract contract ReentrancyGuardUpgradeable is Initializable {
    // Booleans are more expensive than uint256 or any type that takes up a full
    // word because each write operation emits an extra SLOAD to first read the
    // slot's contents, replace the bits taken up by the boolean, and then write
    // back. This is the compiler's defense against contract upgrades and
    // pointer aliasing, and it cannot be disabled.

    // The values being non-zero value makes deployment a bit more expensive,
    // but in exchange the refund on every call to nonReentrant will be lower in
    // amount. Since refunds are capped to a percentage of the total
    // transaction's gas, it is best to keep them low in cases like this one, to
    // increase the likelihood of the full refund coming into effect.
    uint256 private constant _NOT_ENTERED = 1;
    uint256 private constant _ENTERED = 2;

    uint256 private _status;

    function __ReentrancyGuard_init() internal initializer {
        __ReentrancyGuard_init_unchained();
    }

    function __ReentrancyGuard_init_unchained() internal initializer {
        _status = _NOT_ENTERED;
    }

    /**
     * @dev Prevents a contract from calling itself, directly or indirectly.
     * Calling a `nonReentrant` function from another `nonReentrant`
     * function is not supported. It is possible to prevent this from happening
     * by making the `nonReentrant` function external, and make it call a
     * `private` function that does the actual work.
     */
    modifier nonReentrant() {
        // On the first call to nonReentrant, _notEntered will be true
        require(_status != _ENTERED, "ReentrancyGuard: reentrant call");

        // Any calls to nonReentrant after this point will fail
        _status = _ENTERED;

        _;

        // By storing the original value once again, a refund is triggered (see
        // https://eips.ethereum.org/EIPS/eip-2200)
        _status = _NOT_ENTERED;
    }
    uint256[49] private __gap;
}

// SPDX-License-Identifier: MIT

pragma solidity >=0.6.0 <0.8.0;

import "./ContextUpgradeable.sol";
import "../proxy/Initializable.sol";

/**
 * @dev Contract module which allows children to implement an emergency stop
 * mechanism that can be triggered by an authorized account.
 *
 * This module is used through inheritance. It will make available the
 * modifiers `whenNotPaused` and `whenPaused`, which can be applied to
 * the functions of your contract. Note that they will not be pausable by
 * simply including this module, only once the modifiers are put in place.
 */
abstract contract PausableUpgradeable is Initializable, ContextUpgradeable {
    /**
     * @dev Emitted when the pause is triggered by `account`.
     */
    event Paused(address account);

    /**
     * @dev Emitted when the pause is lifted by `account`.
     */
    event Unpaused(address account);

    bool private _paused;

    /**
     * @dev Initializes the contract in unpaused state.
     */
    function __Pausable_init() internal initializer {
        __Context_init_unchained();
        __Pausable_init_unchained();
    }

    function __Pausable_init_unchained() internal initializer {
        _paused = false;
    }

    /**
     * @dev Returns true if the contract is paused, and false otherwise.
     */
    function paused() public view virtual returns (bool) {
        return _paused;
    }

    /**
     * @dev Modifier to make a function callable only when the contract is not paused.
     *
     * Requirements:
     *
     * - The contract must not be paused.
     */
    modifier whenNotPaused() {
        require(!paused(), "Pausable: paused");
        _;
    }

    /**
     * @dev Modifier to make a function callable only when the contract is paused.
     *
     * Requirements:
     *
     * - The contract must be paused.
     */
    modifier whenPaused() {
        require(paused(), "Pausable: not paused");
        _;
    }

    /**
     * @dev Triggers stopped state.
     *
     * Requirements:
     *
     * - The contract must not be paused.
     */
    function _pause() internal virtual whenNotPaused {
        _paused = true;
        emit Paused(_msgSender());
    }

    /**
     * @dev Returns to normal state.
     *
     * Requirements:
     *
     * - The contract must be paused.
     */
    function _unpause() internal virtual whenPaused {
        _paused = false;
        emit Unpaused(_msgSender());
    }
    uint256[49] private __gap;
}

// SPDX-License-Identifier: MIT

pragma solidity 0.6.12;

interface IRewardPool {
    function pae() external view returns (address);
    function userInfo(uint256 _pid, address _user) external view returns (uint256, uint256);
    function poolInfo(uint256 _pid) external view returns (address, uint256);
    function deposit(uint256 _pid, uint256 _amount) external;
    function withdraw(uint256 _pid, uint256 _amount) external;
    function emergencyWithdraw(uint256 _pid) external;
    function pendingPAE(uint256 _pid, address _user) external view returns (uint256);
    function paePerSecond() external view returns (uint256);
    function totalAllocPoint() external view returns (uint256);
    function totalSupply(uint256 _pid) external view returns (uint256); // in VeloStaker
}

// SPDX-License-Identifier: MIT

pragma experimental ABIEncoderV2;
pragma solidity 0.6.12;

interface ISolidlyRouter {

  struct route {
    address from;
    address to;
    bool stable;
  }

  function swapExactTokensForFTM(uint amountIn, uint amountOutMin, route[] calldata routes, address to, uint deadline)
  external returns (uint[] memory amounts);

  function swapExactTokensForTokens(uint amountIn, uint amountOutMin, route[] calldata routes, address to, uint deadline)
  external returns (uint[] memory amounts);

  function swapExactTokensForTokensSimple(uint amountIn, uint amountOutMin, address tokenFrom, address tokenTo, bool stable, address to, uint deadline)
  external returns (uint[] memory amounts);

  function getAmountsOut(uint amountIn, route[] memory routes) external view returns (uint[] memory amounts);

  function quoteAddLiquidity(
    address tokenA,
    address tokenB,
    bool stable,
    uint amountADesired,
    uint amountBDesired
  ) external view returns (uint amountA, uint amountB, uint liquidity);

  function addLiquidity(
    address tokenA,
    address tokenB,
    bool stable,
    uint amountADesired,
    uint amountBDesired,
    uint amountAMin,
    uint amountBMin,
    address to,
    uint deadline
  ) external returns (uint amountA, uint amountB, uint liquidity);
}

// SPDX-License-Identifier: MIT

pragma solidity ^0.6.0;

interface ISolidlyV1Pair {

  function symbol() external view returns (string memory);
  function stable() external view returns (bool);

  function token0() external view returns (address);
  function token1() external view returns (address);

  function reserve0CumulativeLast() external view returns (uint256);
  function reserve1CumulativeLast() external view returns (uint256);

  function currentCumulativePrices() external view returns (uint reserve0Cumulative, uint reserve1Cumulative, uint blockTimestamp);
  function getReserves() external view returns (uint _reserve0, uint _reserve1, uint _blockTimestampLast);

  function current(address tokenIn, uint amountIn) external view returns (uint amountOut);

  // as per `current`, however allows user configured granularity, up to the full window size
  function quote(address tokenIn, uint amountIn, uint granularity) external view returns (uint amountOut);

  // returns a memory set of twap prices
  function prices(address tokenIn, uint amountIn, uint points) external view returns (uint[] memory);
  function sample(address tokenIn, uint amountIn, uint points, uint window) external view returns (uint[] memory);

  function observationLength() external view returns (uint);
  function lastObservation() external view returns (uint timestamp, uint reserve0Cumulative, uint reserve1Cumulative);

  function getAmountOut(uint amountIn, address tokenIn) external view returns (uint);
}

// SPDX-License-Identifier: MIT

pragma solidity 0.6.12;

interface IVault {

  function lp() external view returns (address);
  function balanceOf(address _user) external view returns (uint);
  function depositAll() external;

}

// SPDX-License-Identifier: MIT

pragma solidity >=0.6.0 <0.8.0;
import "../proxy/Initializable.sol";

/*
 * @dev Provides information about the current execution context, including the
 * sender of the transaction and its data. While these are generally available
 * via msg.sender and msg.data, they should not be accessed in such a direct
 * manner, since when dealing with GSN meta-transactions the account sending and
 * paying for execution may not be the actual sender (as far as an application
 * is concerned).
 *
 * This contract is only required for intermediate, library-like contracts.
 */
abstract contract ContextUpgradeable is Initializable {
    function __Context_init() internal initializer {
        __Context_init_unchained();
    }

    function __Context_init_unchained() internal initializer {
    }
    function _msgSender() internal view virtual returns (address payable) {
        return msg.sender;
    }

    function _msgData() internal view virtual returns (bytes memory) {
        this; // silence state mutability warning without generating bytecode - see https://github.com/ethereum/solidity/issues/2691
        return msg.data;
    }
    uint256[50] private __gap;
}

// SPDX-License-Identifier: MIT

// solhint-disable-next-line compiler-version
pragma solidity >=0.4.24 <0.8.0;

import "../utils/AddressUpgradeable.sol";

/**
 * @dev This is a base contract to aid in writing upgradeable contracts, or any kind of contract that will be deployed
 * behind a proxy. Since a proxied contract can't have a constructor, it's common to move constructor logic to an
 * external initializer function, usually called `initialize`. It then becomes necessary to protect this initializer
 * function so it can only be called once. The {initializer} modifier provided by this contract will have this effect.
 *
 * TIP: To avoid leaving the proxy in an uninitialized state, the initializer function should be called as early as
 * possible by providing the encoded function call as the `_data` argument to {UpgradeableProxy-constructor}.
 *
 * CAUTION: When used with inheritance, manual care must be taken to not invoke a parent initializer twice, or to ensure
 * that all initializers are idempotent. This is not verified automatically as constructors are by Solidity.
 */
abstract contract Initializable {

    /**
     * @dev Indicates that the contract has been initialized.
     */
    bool private _initialized;

    /**
     * @dev Indicates that the contract is in the process of being initialized.
     */
    bool private _initializing;

    /**
     * @dev Modifier to protect an initializer function from being invoked twice.
     */
    modifier initializer() {
        require(_initializing || _isConstructor() || !_initialized, "Initializable: contract is already initialized");

        bool isTopLevelCall = !_initializing;
        if (isTopLevelCall) {
            _initializing = true;
            _initialized = true;
        }

        _;

        if (isTopLevelCall) {
            _initializing = false;
        }
    }

    /// @dev Returns true if and only if the function is running in the constructor
    function _isConstructor() private view returns (bool) {
        return !AddressUpgradeable.isContract(address(this));
    }
}

// SPDX-License-Identifier: MIT

pragma solidity >=0.6.2 <0.8.0;

/**
 * @dev Collection of functions related to the address type
 */
library AddressUpgradeable {
    /**
     * @dev Returns true if `account` is a contract.
     *
     * [IMPORTANT]
     * ====
     * It is unsafe to assume that an address for which this function returns
     * false is an externally-owned account (EOA) and not a contract.
     *
     * Among others, `isContract` will return false for the following
     * types of addresses:
     *
     *  - an externally-owned account
     *  - a contract in construction
     *  - an address where a contract will be created
     *  - an address where a contract lived, but was destroyed
     * ====
     */
    function isContract(address account) internal view returns (bool) {
        // This method relies on extcodesize, which returns 0 for contracts in
        // construction, since the code is only stored at the end of the
        // constructor execution.

        uint256 size;
        // solhint-disable-next-line no-inline-assembly
        assembly { size := extcodesize(account) }
        return size > 0;
    }

    /**
     * @dev Replacement for Solidity's `transfer`: sends `amount` wei to
     * `recipient`, forwarding all available gas and reverting on errors.
     *
     * https://eips.ethereum.org/EIPS/eip-1884[EIP1884] increases the gas cost
     * of certain opcodes, possibly making contracts go over the 2300 gas limit
     * imposed by `transfer`, making them unable to receive funds via
     * `transfer`. {sendValue} removes this limitation.
     *
     * https://diligence.consensys.net/posts/2019/09/stop-using-soliditys-transfer-now/[Learn more].
     *
     * IMPORTANT: because control is transferred to `recipient`, care must be
     * taken to not create reentrancy vulnerabilities. Consider using
     * {ReentrancyGuard} or the
     * https://solidity.readthedocs.io/en/v0.5.11/security-considerations.html#use-the-checks-effects-interactions-pattern[checks-effects-interactions pattern].
     */
    function sendValue(address payable recipient, uint256 amount) internal {
        require(address(this).balance >= amount, "Address: insufficient balance");

        // solhint-disable-next-line avoid-low-level-calls, avoid-call-value
        (bool success, ) = recipient.call{ value: amount }("");
        require(success, "Address: unable to send value, recipient may have reverted");
    }

    /**
     * @dev Performs a Solidity function call using a low level `call`. A
     * plain`call` is an unsafe replacement for a function call: use this
     * function instead.
     *
     * If `target` reverts with a revert reason, it is bubbled up by this
     * function (like regular Solidity function calls).
     *
     * Returns the raw returned data. To convert to the expected return value,
     * use https://solidity.readthedocs.io/en/latest/units-and-global-variables.html?highlight=abi.decode#abi-encoding-and-decoding-functions[`abi.decode`].
     *
     * Requirements:
     *
     * - `target` must be a contract.
     * - calling `target` with `data` must not revert.
     *
     * _Available since v3.1._
     */
    function functionCall(address target, bytes memory data) internal returns (bytes memory) {
      return functionCall(target, data, "Address: low-level call failed");
    }

    /**
     * @dev Same as {xref-Address-functionCall-address-bytes-}[`functionCall`], but with
     * `errorMessage` as a fallback revert reason when `target` reverts.
     *
     * _Available since v3.1._
     */
    function functionCall(address target, bytes memory data, string memory errorMessage) internal returns (bytes memory) {
        return functionCallWithValue(target, data, 0, errorMessage);
    }

    /**
     * @dev Same as {xref-Address-functionCall-address-bytes-}[`functionCall`],
     * but also transferring `value` wei to `target`.
     *
     * Requirements:
     *
     * - the calling contract must have an ETH balance of at least `value`.
     * - the called Solidity function must be `payable`.
     *
     * _Available since v3.1._
     */
    function functionCallWithValue(address target, bytes memory data, uint256 value) internal returns (bytes memory) {
        return functionCallWithValue(target, data, value, "Address: low-level call with value failed");
    }

    /**
     * @dev Same as {xref-Address-functionCallWithValue-address-bytes-uint256-}[`functionCallWithValue`], but
     * with `errorMessage` as a fallback revert reason when `target` reverts.
     *
     * _Available since v3.1._
     */
    function functionCallWithValue(address target, bytes memory data, uint256 value, string memory errorMessage) internal returns (bytes memory) {
        require(address(this).balance >= value, "Address: insufficient balance for call");
        require(isContract(target), "Address: call to non-contract");

        // solhint-disable-next-line avoid-low-level-calls
        (bool success, bytes memory returndata) = target.call{ value: value }(data);
        return _verifyCallResult(success, returndata, errorMessage);
    }

    /**
     * @dev Same as {xref-Address-functionCall-address-bytes-}[`functionCall`],
     * but performing a static call.
     *
     * _Available since v3.3._
     */
    function functionStaticCall(address target, bytes memory data) internal view returns (bytes memory) {
        return functionStaticCall(target, data, "Address: low-level static call failed");
    }

    /**
     * @dev Same as {xref-Address-functionCall-address-bytes-string-}[`functionCall`],
     * but performing a static call.
     *
     * _Available since v3.3._
     */
    function functionStaticCall(address target, bytes memory data, string memory errorMessage) internal view returns (bytes memory) {
        require(isContract(target), "Address: static call to non-contract");

        // solhint-disable-next-line avoid-low-level-calls
        (bool success, bytes memory returndata) = target.staticcall(data);
        return _verifyCallResult(success, returndata, errorMessage);
    }

    function _verifyCallResult(bool success, bytes memory returndata, string memory errorMessage) private pure returns(bytes memory) {
        if (success) {
            return returndata;
        } else {
            // Look for revert reason and bubble it up if present
            if (returndata.length > 0) {
                // The easiest way to bubble the revert reason is using memory via assembly

                // solhint-disable-next-line no-inline-assembly
                assembly {
                    let returndata_size := mload(returndata)
                    revert(add(32, returndata), returndata_size)
                }
            } else {
                revert(errorMessage);
            }
        }
    }
}

// SPDX-License-Identifier: MIT

pragma solidity >=0.6.0 <0.8.0;

/**
 * @dev Interface of the ERC20 standard as defined in the EIP.
 */
interface IERC20Upgradeable {
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
     * Emits a {Transfer} event.
     */
    function transfer(address recipient, uint256 amount) external returns (bool);

    /**
     * @dev Returns the remaining number of tokens that `spender` will be
     * allowed to spend on behalf of `owner` through {transferFrom}. This is
     * zero by default.
     *
     * This value changes when {approve} or {transferFrom} are called.
     */
    function allowance(address owner, address spender) external view returns (uint256);

    /**
     * @dev Sets `amount` as the allowance of `spender` over the caller's tokens.
     *
     * Returns a boolean value indicating whether the operation succeeded.
     *
     * IMPORTANT: Beware that changing an allowance with this method brings the risk
     * that someone may use both the old and the new allowance by unfortunate
     * transaction ordering. One possible solution to mitigate this race
     * condition is to first reduce the spender's allowance to 0 and set the
     * desired value afterwards:
     * https://github.com/ethereum/EIPs/issues/20#issuecomment-263524729
     *
     * Emits an {Approval} event.
     */
    function approve(address spender, uint256 amount) external returns (bool);

    /**
     * @dev Moves `amount` tokens from `sender` to `recipient` using the
     * allowance mechanism. `amount` is then deducted from the caller's
     * allowance.
     *
     * Returns a boolean value indicating whether the operation succeeded.
     *
     * Emits a {Transfer} event.
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
     * a call to {approve}. `value` is the new allowance.
     */
    event Approval(address indexed owner, address indexed spender, uint256 value);
}

// SPDX-License-Identifier: MIT

pragma solidity >=0.6.0 <0.8.0;

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
library SafeMathUpgradeable {
    /**
     * @dev Returns the addition of two unsigned integers, with an overflow flag.
     *
     * _Available since v3.4._
     */
    function tryAdd(uint256 a, uint256 b) internal pure returns (bool, uint256) {
        uint256 c = a + b;
        if (c < a) return (false, 0);
        return (true, c);
    }

    /**
     * @dev Returns the substraction of two unsigned integers, with an overflow flag.
     *
     * _Available since v3.4._
     */
    function trySub(uint256 a, uint256 b) internal pure returns (bool, uint256) {
        if (b > a) return (false, 0);
        return (true, a - b);
    }

    /**
     * @dev Returns the multiplication of two unsigned integers, with an overflow flag.
     *
     * _Available since v3.4._
     */
    function tryMul(uint256 a, uint256 b) internal pure returns (bool, uint256) {
        // Gas optimization: this is cheaper than requiring 'a' not being zero, but the
        // benefit is lost if 'b' is also tested.
        // See: https://github.com/OpenZeppelin/openzeppelin-contracts/pull/522
        if (a == 0) return (true, 0);
        uint256 c = a * b;
        if (c / a != b) return (false, 0);
        return (true, c);
    }

    /**
     * @dev Returns the division of two unsigned integers, with a division by zero flag.
     *
     * _Available since v3.4._
     */
    function tryDiv(uint256 a, uint256 b) internal pure returns (bool, uint256) {
        if (b == 0) return (false, 0);
        return (true, a / b);
    }

    /**
     * @dev Returns the remainder of dividing two unsigned integers, with a division by zero flag.
     *
     * _Available since v3.4._
     */
    function tryMod(uint256 a, uint256 b) internal pure returns (bool, uint256) {
        if (b == 0) return (false, 0);
        return (true, a % b);
    }

    /**
     * @dev Returns the addition of two unsigned integers, reverting on
     * overflow.
     *
     * Counterpart to Solidity's `+` operator.
     *
     * Requirements:
     *
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
     *
     * - Subtraction cannot overflow.
     */
    function sub(uint256 a, uint256 b) internal pure returns (uint256) {
        require(b <= a, "SafeMath: subtraction overflow");
        return a - b;
    }

    /**
     * @dev Returns the multiplication of two unsigned integers, reverting on
     * overflow.
     *
     * Counterpart to Solidity's `*` operator.
     *
     * Requirements:
     *
     * - Multiplication cannot overflow.
     */
    function mul(uint256 a, uint256 b) internal pure returns (uint256) {
        if (a == 0) return 0;
        uint256 c = a * b;
        require(c / a == b, "SafeMath: multiplication overflow");
        return c;
    }

    /**
     * @dev Returns the integer division of two unsigned integers, reverting on
     * division by zero. The result is rounded towards zero.
     *
     * Counterpart to Solidity's `/` operator. Note: this function uses a
     * `revert` opcode (which leaves remaining gas untouched) while Solidity
     * uses an invalid opcode to revert (consuming all remaining gas).
     *
     * Requirements:
     *
     * - The divisor cannot be zero.
     */
    function div(uint256 a, uint256 b) internal pure returns (uint256) {
        require(b > 0, "SafeMath: division by zero");
        return a / b;
    }

    /**
     * @dev Returns the remainder of dividing two unsigned integers. (unsigned integer modulo),
     * reverting when dividing by zero.
     *
     * Counterpart to Solidity's `%` operator. This function uses a `revert`
     * opcode (which leaves remaining gas untouched) while Solidity uses an
     * invalid opcode to revert (consuming all remaining gas).
     *
     * Requirements:
     *
     * - The divisor cannot be zero.
     */
    function mod(uint256 a, uint256 b) internal pure returns (uint256) {
        require(b > 0, "SafeMath: modulo by zero");
        return a % b;
    }

    /**
     * @dev Returns the subtraction of two unsigned integers, reverting with custom message on
     * overflow (when the result is negative).
     *
     * CAUTION: This function is deprecated because it requires allocating memory for the error
     * message unnecessarily. For custom revert reasons use {trySub}.
     *
     * Counterpart to Solidity's `-` operator.
     *
     * Requirements:
     *
     * - Subtraction cannot overflow.
     */
    function sub(uint256 a, uint256 b, string memory errorMessage) internal pure returns (uint256) {
        require(b <= a, errorMessage);
        return a - b;
    }

    /**
     * @dev Returns the integer division of two unsigned integers, reverting with custom message on
     * division by zero. The result is rounded towards zero.
     *
     * CAUTION: This function is deprecated because it requires allocating memory for the error
     * message unnecessarily. For custom revert reasons use {tryDiv}.
     *
     * Counterpart to Solidity's `/` operator. Note: this function uses a
     * `revert` opcode (which leaves remaining gas untouched) while Solidity
     * uses an invalid opcode to revert (consuming all remaining gas).
     *
     * Requirements:
     *
     * - The divisor cannot be zero.
     */
    function div(uint256 a, uint256 b, string memory errorMessage) internal pure returns (uint256) {
        require(b > 0, errorMessage);
        return a / b;
    }

    /**
     * @dev Returns the remainder of dividing two unsigned integers. (unsigned integer modulo),
     * reverting with custom message when dividing by zero.
     *
     * CAUTION: This function is deprecated because it requires allocating memory for the error
     * message unnecessarily. For custom revert reasons use {tryMod}.
     *
     * Counterpart to Solidity's `%` operator. This function uses a `revert`
     * opcode (which leaves remaining gas untouched) while Solidity uses an
     * invalid opcode to revert (consuming all remaining gas).
     *
     * Requirements:
     *
     * - The divisor cannot be zero.
     */
    function mod(uint256 a, uint256 b, string memory errorMessage) internal pure returns (uint256) {
        require(b > 0, errorMessage);
        return a % b;
    }
}
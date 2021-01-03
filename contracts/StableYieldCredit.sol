// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "./lib/SafeERC20.sol";
import "./interfaces/Oracle.sol";
import "./interfaces/Factory.sol";
import "./interfaces/Pair.sol";
import "./lib/ReentrancyGuard.sol";
import "./lib/SwapLibrary.sol";
import "./lib/Math.sol";

contract StableYieldCredit is ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// @notice EIP-20 token name for this token
    string public constant name = "Stable Yield Credit";

    /// @notice EIP-20 token symbol for this token
    string public constant symbol = "yCREDIT";

    /// @notice EIP-20 token decimals for this token
    uint8 public constant decimals = 8;

    /// @notice Total number of tokens in circulation
    uint public totalSupply = 0;
    
    /// @notice Total number of tokens staked for yield
    uint public stakedSupply = 0;

    address public operator;
    uint public singleDepositCap = type(uint).max;
    uint public totalDepositCap = type(uint).max;

    mapping(address => mapping (address => uint)) internal allowances;
    mapping(address => uint) internal balances;
    mapping(address => uint) public stakes;

    /// @notice The EIP-712 typehash for the contract's domain
    bytes32 public constant DOMAIN_TYPEHASH = keccak256("EIP712Domain(string name,uint chainId,address verifyingContract)");
    bytes32 public immutable DOMAINSEPARATOR;

    /// @notice The EIP-712 typehash for the permit struct used by the contract
    bytes32 public constant PERMIT_TYPEHASH = keccak256("Permit(address owner,address spender,uint value,uint nonce,uint deadline)");

    /// @notice A record of states for signing / validating signatures
    mapping (address => uint) public nonces;

    function safe32(uint n, string memory errorMessage) internal pure returns (uint32) {
        require(n < 2**32, errorMessage);
        return uint32(n);
    }

    /// @notice The standard EIP-20 transfer event
    event Transfer(address indexed from, address indexed to, uint amount);
    
    /// @notice Stake event for claiming rewards
    event Staked(address indexed from, uint amount);
    
    // @notice Unstake event
    event Unstaked(address indexed from, uint amount);
    
    event Earned(address indexed from, uint amount);
    event Fees(uint amount);

    /// @notice The standard EIP-20 approval event
    event Approval(address indexed owner, address indexed spender, uint amount);

    // Oracle used for price debt data (external to the AMM balance to avoid internal manipulation)
    Oracle public constant LINK = Oracle(0x271bf4568fb737cc2e6277e9B1EE0034098cDA2a);
    Factory public constant FACTORY = Factory(0xC0AEe478e3658e2610c5F7A4A2E1777cE9e4f2Ac);
    
    // user => token => collateral
    mapping (address => mapping(address => uint)) public collateral;
    // user => token => credit
    mapping (address => mapping(address => uint)) public collateralCredit;
    
    address[] private _markets;
    mapping (address => bool) pairs;
    
    uint public rewardRate = 0;
    uint public periodFinish = 0;
    uint public DURATION = 7 days;
    uint public lastUpdateTime;
    uint public rewardPerTokenStored;
    
    mapping(address => uint) public userRewardPerTokenPaid;
    mapping(address => uint) public rewards;
    
    event Deposit(address indexed creditor, address indexed collateral, uint creditOut, uint amountIn, uint creditMinted);
    event Withdraw(address indexed creditor, address indexed collateral, uint creditIn, uint creditOut, uint amountOut);
    
    constructor () {
      operator = msg.sender;
      DOMAINSEPARATOR = keccak256(abi.encode(DOMAIN_TYPEHASH, keccak256(bytes(name)), _getChainId(), address(this)));
    }
    
    uint public FEE = 50;
    uint public BASE = 10000;

    function setSingleDepositCap(uint _cap) external {
      require(msg.sender == operator);
      singleDepositCap = _cap;
    }

    function setTotalDepositCap(uint _cap) external {
      require(msg.sender == operator);
      totalDepositCap = _cap;
    }

    function setOperator(address _operator) external {
      require(msg.sender == operator);
      operator = _operator;
    }
    
    function lastTimeRewardApplicable() public view returns (uint) {
        return Math.min(block.timestamp, periodFinish);
    }
    
    function rewardPerToken() public view returns (uint) {
        if (stakedSupply == 0) {
            return rewardPerTokenStored;
        }
        return
            rewardPerTokenStored +
                ((lastTimeRewardApplicable() - 
                lastUpdateTime) * 
                rewardRate * 1e18 / stakedSupply);
    }
    
    function earned(address account) public view returns (uint) {
        return (stakes[account] * (rewardPerToken() - userRewardPerTokenPaid[account]) / 1e18) + rewards[account];
    }

    function getRewardForDuration() external view returns (uint) {
        return rewardRate * DURATION;
    }
    
    modifier updateReward(address account) {
        rewardPerTokenStored = rewardPerToken();
        lastUpdateTime = lastTimeRewardApplicable();
        if (account != address(0)) {
            rewards[account] = earned(account);
            userRewardPerTokenPaid[account] = rewardPerTokenStored;
        }
        _;
    }
    
    function stake(uint256 amount) external nonReentrant updateReward(msg.sender) {
        require(amount > 0, "Cannot stake 0");
        stakedSupply += amount;
        stakes[msg.sender] += amount;
        _transferTokens(msg.sender, address(this), amount);
        emit Staked(msg.sender, amount);
    }

    function unstake(uint amount) public nonReentrant updateReward(msg.sender) {
        require(amount > 0, "Cannot withdraw 0");
        stakedSupply -= amount;
        stakes[msg.sender] -= amount;
        _transferTokens(address(this), msg.sender, amount);
        emit Unstaked(msg.sender, amount);
    }

    function getReward() public nonReentrant updateReward(msg.sender) {
        uint256 reward = rewards[msg.sender];
        if (reward > 0) {
            rewards[msg.sender] = 0;
            _transferTokens(address(this), msg.sender, reward);
            emit Earned(msg.sender, reward);
        }
    }

    function exit() external {
        unstake(stakes[msg.sender]);
        getReward();
    }
    
    function notifyFeeAmount(uint reward) internal updateReward(address(0)) {
        if (block.timestamp >= periodFinish) {
            rewardRate = reward / DURATION;
        } else {
            uint remaining = periodFinish - block.timestamp;
            uint leftover = remaining * rewardRate;
            rewardRate = (reward + leftover) / DURATION;
        }

        // Ensure the provided reward amount is not more than the balance in the contract.
        // This keeps the reward rate in the right range, preventing overflows due to
        // very high values of rewardRate in the earned and rewardsPerToken functions;
        // Reward + leftover must be less than 2^256 / 10^18 to avoid overflow.
        uint balance = balances[address(this)];
        require(rewardRate <= balance / DURATION, "Provided reward too high");

        lastUpdateTime = block.timestamp;
        periodFinish = block.timestamp + DURATION;
        emit Fees(reward);
    }
    
    function markets() external view returns (address[] memory) {
        return _markets;
    }
    
    function _mint(address dst, uint amount) internal {
        // mint the amount
        totalSupply += amount;
        // transfer the amount to the recipient
        balances[dst] += amount;
        emit Transfer(address(0), dst, amount);
    }
    
    function _burn(address dst, uint amount) internal {
        // burn the amount
        totalSupply -= amount;
        // transfer the amount from the recipient
        balances[dst] -= amount;
        emit Transfer(dst, address(0), amount);
    }
    
    function depositAll(IERC20 token) external returns (uint) {
        return _deposit(token, token.balanceOf(msg.sender));
    }
    
    function deposit(IERC20 token, uint amount) external returns (uint) {
        return _deposit(token, amount);
    }
    
    function _addLiquidity(
        address tokenA,
        address tokenB,
        uint amountADesired,
        uint amountBDesired
    ) internal virtual returns (address pair, uint amountA, uint amountB) {
        // create the pair if it doesn't exist yet
        pair = FACTORY.getPair(tokenA, tokenB);
        if (pair == address(0)) {
            pair = FACTORY.createPair(tokenA, tokenB);
            pairs[pair] = true;
            _markets.push(tokenA);
        } else if (!pairs[pair]) {
            pairs[pair] = true;
            _markets.push(tokenA);
        }
        
        (uint reserveA, uint reserveB) = SwapLibrary.getReserves(address(FACTORY), tokenA, tokenB);
        if (reserveA == 0 && reserveB == 0) {
            (amountA, amountB) = (amountADesired, amountBDesired);
        } else {
            uint amountBOptimal = SwapLibrary.quote(amountADesired, reserveA, reserveB);
            if (amountBOptimal <= amountBDesired) {
                (amountA, amountB) = (amountADesired, amountBOptimal);
            } else {
                uint amountAOptimal = SwapLibrary.quote(amountBDesired, reserveB, reserveA);
                assert(amountAOptimal <= amountADesired);
                (amountA, amountB) = (amountAOptimal, amountBDesired);
            }
        }
    }
    
    function _deposit(IERC20 token, uint amount) internal returns (uint) {
        uint _value = LINK.getPriceUSD(address(token)) * amount / uint256(10)**token.decimals();
        require(_value > 0, "!value");
        
        (address _pair, uint amountA, uint amountB) = _addLiquidity(address(token), address(this), amount, _value);
        
        require(amountB <= _value, 'value too big');
        _value = amountB;
        require(_value <= singleDepositCap, "over singleDepositCap");

        token.safeTransferFrom(msg.sender, _pair, amountA);
        _mint(_pair, _value); // Amount of scUSD to mint
        
        uint _liquidity = Pair(_pair).mint(address(this));
        collateral[msg.sender][address(token)] += _liquidity;
        
        collateralCredit[msg.sender][address(token)] += _value;
        uint _fee = _value * FEE / BASE;
        _mint(msg.sender, _value - _fee);
        _mint(address(this), _fee);
        notifyFeeAmount(_fee);
        require(totalSupply / 2 <= totalDepositCap, "over totalDepositCap");
        emit Deposit(msg.sender, address(token), _value, amount, _value);
        return _value;
    }
    
    function withdrawAll(IERC20 token) external {
        _withdraw(token, IERC20(address(this)).balanceOf(msg.sender));
    }
    
    function withdraw(IERC20 token, uint amount) external {
        _withdraw(token, amount);
    }
    
    function _withdraw(IERC20 token, uint amount) internal {
        uint _credit = collateralCredit[msg.sender][address(token)];
        uint _collateral = collateral[msg.sender][address(token)];
        
        if (_credit < amount) {
            amount = _credit;
        }
        
        // Calculate % of collateral to release
        uint _burned = _collateral * amount / _credit;
        address _pair = FACTORY.getPair(address(token), address(this));
        
        IERC20(_pair).safeTransfer(_pair, _burned); // send liquidity to pair
        (uint _amount0, uint _amount1) = Pair(_pair).burn(msg.sender);
        (address _token0,) = SwapLibrary.sortTokens(address(token), address(this));
        (uint _amountA, uint _amountB) = address(token) == _token0 ? (_amount0, _amount1) : (_amount1, _amount0);
        
        collateralCredit[msg.sender][address(token)] -= amount;
        collateral[msg.sender][address(token)] -= _burned;
        _burn(msg.sender, amount * 2); // Amount of scUSD to burn (value of A leaving the system)
        
        emit Withdraw(msg.sender, address(token), amount, _amountB, _amountA);
    }

    /**
     * @notice Get the number of tokens `spender` is approved to spend on behalf of `account`
     * @param account The address of the account holding the funds
     * @param spender The address of the account spending the funds
     * @return The number of tokens approved
     */
    function allowance(address account, address spender) external view returns (uint) {
        return allowances[account][spender];
    }

    /**
     * @notice Approve `spender` to transfer up to `amount` from `src`
     * @dev This will overwrite the approval amount for `spender`
     *  and is subject to issues noted [here](https://eips.ethereum.org/EIPS/eip-20#approve)
     * @param spender The address of the account which may transfer tokens
     * @param amount The number of tokens that are approved (2^256-1 means infinite)
     * @return Whether or not the approval succeeded
     */
    function approve(address spender, uint amount) external returns (bool) {
        allowances[msg.sender][spender] = amount;

        emit Approval(msg.sender, spender, amount);
        return true;
    }

    /**
     * @notice Triggers an approval from owner to spends
     * @param owner The address to approve from
     * @param spender The address to be approved
     * @param amount The number of tokens that are approved (2^256-1 means infinite)
     * @param deadline The time at which to expire the signature
     * @param v The recovery byte of the signature
     * @param r Half of the ECDSA signature pair
     * @param s Half of the ECDSA signature pair
     */
    function permit(address owner, address spender, uint amount, uint deadline, uint8 v, bytes32 r, bytes32 s) external {
        bytes32 structHash = keccak256(abi.encode(PERMIT_TYPEHASH, owner, spender, amount, nonces[owner]++, deadline));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", DOMAINSEPARATOR, structHash));
        address signatory = ecrecover(digest, v, r, s);
        require(signatory != address(0), "permit: signature");
        require(signatory == owner, "permit: unauthorized");
        require(block.timestamp <= deadline, "permit: expired");

        allowances[owner][spender] = amount;

        emit Approval(owner, spender, amount);
    }

    /**
     * @notice Get the number of tokens held by the `account`
     * @param account The address of the account to get the balance of
     * @return The number of tokens held
     */
    function balanceOf(address account) external view returns (uint) {
        return balances[account];
    }

    /**
     * @notice Transfer `amount` tokens from `msg.sender` to `dst`
     * @param dst The address of the destination account
     * @param amount The number of tokens to transfer
     * @return Whether or not the transfer succeeded
     */
    function transfer(address dst, uint amount) external returns (bool) {
        _transferTokens(msg.sender, dst, amount);
        return true;
    }

    /**
     * @notice Transfer `amount` tokens from `src` to `dst`
     * @param src The address of the source account
     * @param dst The address of the destination account
     * @param amount The number of tokens to transfer
     * @return Whether or not the transfer succeeded
     */
    function transferFrom(address src, address dst, uint amount) external returns (bool) {
        address spender = msg.sender;
        uint spenderAllowance = allowances[src][spender];

        if (spender != src && spenderAllowance != type(uint).max) {
            uint newAllowance = spenderAllowance - amount;
            allowances[src][spender] = newAllowance;

            emit Approval(src, spender, newAllowance);
        }

        _transferTokens(src, dst, amount);
        return true;
    }

    function _transferTokens(address src, address dst, uint amount) internal {
        balances[src] -= amount;
        balances[dst] += amount;
        
        emit Transfer(src, dst, amount);
        
        if (pairs[src]) {
            uint _fee = amount * FEE / BASE;
            _transferTokens(dst, address(this), _fee);
            notifyFeeAmount(_fee);
        }
    }

    function _getChainId() internal view returns (uint) {
        uint chainId;
        assembly { chainId := chainid() }
        return chainId;
    }
}
// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.10;

import "../../interfaces/IIdleCDOStrategy.sol";
import "../../interfaces/IERC20Detailed.sol";
import "../../interfaces/aave/ILendingPool.sol";
import "../../interfaces/aave/IAToken.sol";

import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";

import "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import "hardhat/console.sol";

contract IdleLeveragedAaveStrategy is Initializable, OwnableUpgradeable, ERC20Upgradeable, ReentrancyGuardUpgradeable, IIdleCDOStrategy {
    using SafeERC20Upgradeable for IERC20Detailed;

    /// @notice underlying token address (eg mUSD)
    address public override token;

    /// @notice address of the strategy used, in this case imUSD
    address public override strategyToken;

    /// @notice decimals of the underlying asset
    uint256 public override tokenDecimals;

    uint256 public correlatedTokenDecimals;

    /// @notice one underlying token
    uint256 public override oneToken;

    uint256 public oneCorrelatedToken;

    /// @notice address of the IdleCDO
    address public idleCDO;

    /// @notice underlying ERC20 token contract
    IERC20Detailed public underlyingToken;

    IERC20Detailed public correlatedToken;

    IERC20Detailed public underlyingDebtToken;

    IERC20Detailed public correlatedDebtToken;

    address public correlatedStrategyToken;

    ILendingPool public lendingPool;

    uint256 public borrowFraction;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        token = address(1);
    }

    function initialize(
        address _strategyToken,
        address _underlyingToken,
        address _correlatedStrategyToken,
        address _correlatedToken,
        ILendingPool _lendingPool,
        address _underlyingDebtToken,
        address _correlatedDebtToken,
        address _owner
    ) public initializer {
        OwnableUpgradeable.__Ownable_init();
        ReentrancyGuardUpgradeable.__ReentrancyGuard_init();
        require(token == address(0), "Token is already initialized");

        strategyToken = _strategyToken;
        correlatedStrategyToken = _correlatedStrategyToken;
        token = _underlyingToken;
        underlyingToken = IERC20Detailed(_underlyingToken);
        correlatedToken = IERC20Detailed(_correlatedToken);
        tokenDecimals = IERC20Detailed(_underlyingToken).decimals();
        correlatedTokenDecimals = IERC20Detailed(_correlatedToken).decimals();
        oneToken = 10**(tokenDecimals);
        oneCorrelatedToken = 10**(correlatedTokenDecimals);
        lendingPool = _lendingPool;

        borrowFraction = 60e18; // 60%
        underlyingDebtToken = IERC20Detailed(_underlyingDebtToken);
        correlatedDebtToken = IERC20Detailed(_correlatedDebtToken);

        ERC20Upgradeable.__ERC20_init("Idle Leveraged Aave Strategy Token", string(abi.encodePacked("idleLAS", underlyingToken.symbol())));
        transferOwnership(_owner);
        IERC20Detailed(_underlyingToken).approve(address(_lendingPool), type(uint256).max);
        IERC20Detailed(_correlatedToken).approve(address(_lendingPool), type(uint256).max);
    }

    function refreshAllowance() public {
        IERC20Detailed(underlyingToken).approve(address(lendingPool), type(uint256).max);
        IERC20Detailed(correlatedToken).approve(address(lendingPool), type(uint256).max);
    }

    function redeemRewards(bytes calldata _extraData) external override onlyIdleCDO returns (uint256[] memory rewards) {}

    function pullStkAAVE() external pure override returns (uint256) {}

    /// @notice net price in underlyings of 1 strategyToken
    /// @return _price
    function price() public view override returns (uint256 _price) {}

    /// @notice Get the reward token
    /// @return _rewards array of reward token (empty as rewards are handled in this strategy)
    function getRewardTokens() external pure override returns (address[] memory _rewards) {}

    /// @notice Deposit the underlying token to vault
    /// @param _amount number of tokens to deposit
    /// @return minted number of reward tokens minted
    function deposit(uint256 _amount) external override onlyIdleCDO returns (uint256 minted) {
        if (_amount > 0) {
            underlyingToken.transferFrom(msg.sender, address(this), _amount);
            minted = _depositToVault(_amount);
        }
    }

    function _depositToVault(uint256 amount) internal returns (uint256) {
        // aave-v2 ensure that same number aTokens are minted, hence return amount directly
        lendingPool.deposit(address(underlyingToken), amount, address(this), 0);
        _updateApr(int256(amount));
        return amount;
    }

    /// @notice update last saved apr
    /// @param _amount amount of underlying tokens to mint/redeem
    function _updateApr(int256 _amount) internal {}

    /// @notice Redeem Tokens
    /// @param _amount amount of strategy tokens to redeem
    /// @return Amount of underlying tokens received
    function redeem(uint256 _amount) external override onlyIdleCDO returns (uint256) {
        _redeem(_amount, msg.sender);
        return _amount;
    }

    /// @notice Redeem Tokens
    /// @param _amount amount of underlying tokens to redeem
    /// @return Amount of underlying tokens received
    function redeemUnderlying(uint256 _amount) external override onlyIdleCDO returns (uint256) {
        _redeem(_amount, msg.sender);
        return _amount;
    }

    function _redeem(uint256 amount, address to) internal {
        lendingPool.withdraw(address(underlyingToken), amount, to);
    }

    function boostRewards(uint256 numberOfTimesToBoost) external onlyIdleCDO {
        for (uint256 index = 0; index < numberOfTimesToBoost; index++) {
            uint256 borrowAmount = _calculateBorrowAmountUnderlyingToCorrelated();
            console.log("borrowAmount", borrowAmount);

            if (borrowAmount == 0) {
                return;
            }

            lendingPool.borrow(address(correlatedToken), borrowAmount, 1, 0, address(this));
            _print();
            lendingPool.deposit(address(correlatedToken), borrowAmount, address(this), 0);
            // _print();
            // borrowAmount = _calculateBorrowAmountCorrelatedToUnderlying();
            // lendingPool.borrow(address(underlyingToken), borrowAmount, 1, 0, address(this));
            // _print();
        }
    }

    function _calculateBorrowAmountUnderlyingToCorrelated() internal view returns (uint256) {
        // borrows fraction of borrowable amount
        uint256 underlyingAmountDeposited = IAToken(strategyToken).balanceOf(address(this));
        uint256 scaledUnderlyingAmountDeposited = (underlyingAmountDeposited * oneCorrelatedToken) / oneToken;
        uint256 correlatedDebtTokenBorrowed = IERC20Detailed(correlatedDebtToken).balanceOf(address(this));
        if (correlatedDebtTokenBorrowed > scaledUnderlyingAmountDeposited) {
            return 0;
        } else {
            return ((scaledUnderlyingAmountDeposited - correlatedDebtTokenBorrowed) * borrowFraction) / 1e20;
        }
    }

    function _calculateBorrowAmountCorrelatedToUnderlying() internal view returns (uint256) {
        uint256 correlatedAmountDeposited = IAToken(correlatedStrategyToken).balanceOf(address(this));
        uint256 scaledCorrelatedAmountDeposited = (correlatedAmountDeposited * oneToken) / oneCorrelatedToken;
        uint256 debtTokenBorrowed = IERC20Detailed(underlyingDebtToken).balanceOf(address(this));
        if (debtTokenBorrowed > scaledCorrelatedAmountDeposited) {
            return 0;
        } else {
            return ((scaledCorrelatedAmountDeposited - debtTokenBorrowed) * borrowFraction) / 1e20;
        }
    }

    function _print() internal view {
        uint256 underlyingTokenBalance = underlyingToken.balanceOf(address(this));
        console.log("underlyingTokenBalance", underlyingTokenBalance);
        uint256 correlatedTokenBalance = IERC20Detailed(correlatedToken).balanceOf(address(this));
        console.log("correlatedTokenBalance", correlatedTokenBalance);
        uint256 strategyTokenBalance = IERC20Detailed(strategyToken).balanceOf(address(this));
        console.log("strategyTokenBalance", strategyTokenBalance);
        uint256 correlatedStrategyTokenBalance = IERC20(correlatedStrategyToken).balanceOf(address(this));
        console.log("correlatedStrategyTokenBalance", correlatedStrategyTokenBalance);
        uint256 underlyingDebtBalance = underlyingDebtToken.balanceOf(address(this));
        console.log("underlyingDebtBalance", underlyingDebtBalance);
        uint256 correlatedDebtBalance = correlatedDebtToken.balanceOf(address(this));
        console.log("correlatedDebtBalance", correlatedDebtBalance);
    }

    /// @notice Approximate APR
    /// @return apr
    function getApr() external view override returns (uint256 apr) {}

    /// @notice allow to update whitelisted address
    function setWhitelistedCDO(address _cdo) external onlyOwner {
        require(_cdo != address(0), "IS_0");
        idleCDO = _cdo;
    }

    /// @notice Modifier to make sure that caller os only the idleCDO contract
    modifier onlyIdleCDO() {
        require(idleCDO == msg.sender, "Only IdleCDO can call");
        _;
    }
}

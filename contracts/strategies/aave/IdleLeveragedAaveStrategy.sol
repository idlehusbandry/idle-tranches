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

    /// @notice one underlying token
    uint256 public override oneToken;

    /// @notice address of the IdleCDO
    address public idleCDO;

    /// @notice underlying ERC20 token contract
    IERC20Detailed public underlyingToken;

    ILendingPool public lendingPool;

    uint256 public borrowFraction;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        token = address(1);
    }

    function initialize(
        address _strategyToken,
        address _underlyingToken,
        ILendingPool _lendingPool,
        address _owner
    ) public initializer {
        OwnableUpgradeable.__Ownable_init();
        ReentrancyGuardUpgradeable.__ReentrancyGuard_init();
        require(token == address(0), "Token is already initialized");

        strategyToken = _strategyToken;
        token = _underlyingToken;
        underlyingToken = IERC20Detailed(_underlyingToken);
        tokenDecimals = IERC20Detailed(_underlyingToken).decimals();
        lendingPool = _lendingPool;

        borrowFraction = 60e18; // 100%

        ERC20Upgradeable.__ERC20_init("Idle Leveraged Aave Strategy Token", string(abi.encodePacked("idleLAS", underlyingToken.symbol())));
        transferOwnership(_owner);
        IERC20Detailed(_underlyingToken).approve(address(_lendingPool), type(uint256).max);
    }

    function refreshAllowance() public {
        IERC20Detailed(underlyingToken).approve(address(lendingPool), type(uint256).max);
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
        uint256 scaledBalanceBefore = IAToken(strategyToken).scaledBalanceOf(address(this));
        console.log("scaledBalanceBefore", scaledBalanceBefore);
        lendingPool.deposit(address(underlyingToken), amount, address(this), 0);
        uint256 scaledBalanceAfter = IAToken(strategyToken).scaledBalanceOf(address(this));
        console.log("scaledBalanceAfter", scaledBalanceAfter);
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
            uint256 aTokenBalance = IAToken(strategyToken).balanceOf(address(this));
            console.log("aTokenBalance", aTokenBalance);

            uint256 borrowAmount = (aTokenBalance * borrowFraction) / 1e20;
            console.log("borrowAmount", borrowAmount);

            if (borrowAmount == 0) {
                return;
            }

            uint256 underlyingTokenBalanceBefore = underlyingToken.balanceOf(address(this));
            console.log("underlyingTokenBalanceBefore", underlyingTokenBalanceBefore);

            lendingPool.borrow(address(underlyingToken), borrowAmount, 1, 0, address(this));

            uint256 underlyingTokenBalanceAfter = underlyingToken.balanceOf(address(this));
            console.log("underlyingTokenBalanceAfter", underlyingTokenBalanceAfter);
        }
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

// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.10;

import "../../interfaces/IIdleCDOStrategy.sol";
import "../../interfaces/IERC20Detailed.sol";
import "../../interfaces/compound/ICToken.sol";
import "../../interfaces/compound/IComptroller.sol";

import "../../interfaces/IUniswapV2Router02.sol";

import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";

import "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import "hardhat/console.sol";

contract IdleLeveragedCompoundStrategy is
    Initializable,
    OwnableUpgradeable,
    ERC20Upgradeable,
    ReentrancyGuardUpgradeable,
    IIdleCDOStrategy
{
    using SafeERC20Upgradeable for IERC20Detailed;

    /// @notice underlying token address (eg DAI)
    address public override token;

    /// @notice address of the strategy used, in this case cDAI
    address public override strategyToken;

    /// @notice decimals of the underlying asset
    uint256 public override tokenDecimals;

    /// @notice one underlying token
    uint256 public override oneToken;

    /// @notice underlying ERC20 token contract
    IERC20Detailed public underlyingToken;

    /// @notice address of the IdleCDO
    address public idleCDO;

    /// @notice borrowFraction
    uint256 public borrowFraction;

    /// @notice _comptroller
    address public comptroller;

    address public compToken;

    /// @notice uniswap router path that should be used to swap the tokens
    address[] public uniswapRouterPath;

    /// @notice interface derived from uniswap router
    IUniswapV2Router02 public uniswapV2Router02;

    /// @notice amount last indexed for calculating APR
    uint256 public lastIndexAmount;

    /// @notice time when last deposit/redeem was made, used for calculating the APR
    uint256 public lastIndexedTime;

    /// @notice latest saved apr
    uint256 public lastApr;

    /// @notice one year, used to calculate the APR
    uint256 public constant YEAR = 365 days;

    function initialize(
        address _strategyToken,
        address _underlyingToken,
        address _comptroller,
        address _compToken,
        address _uniswapV2Router02,
        address[] calldata _routerPath,
        address _owner
    ) public initializer {
        OwnableUpgradeable.__Ownable_init();
        ReentrancyGuardUpgradeable.__ReentrancyGuard_init();
        require(token == address(0), "Token is already initialized");

        //----- // -------//
        strategyToken = _strategyToken;
        token = _underlyingToken;
        underlyingToken = IERC20Detailed(_underlyingToken);
        tokenDecimals = IERC20Detailed(_underlyingToken).decimals();
        oneToken = 10**(tokenDecimals);

        borrowFraction = 60e18; // 60%

        ERC20Upgradeable.__ERC20_init("Idle MStable Strategy Token", string(abi.encodePacked("idleMS", underlyingToken.symbol())));
        address[] memory markets = new address[](1);
        markets[0] = _strategyToken;
        IComptroller(_comptroller).enterMarkets(markets);
        comptroller = _comptroller;
        compToken = _compToken;
        transferOwnership(_owner);
        IERC20Detailed(_underlyingToken).approve(_strategyToken, type(uint256).max);

        uniswapRouterPath = _routerPath;
        uniswapV2Router02 = IUniswapV2Router02(_uniswapV2Router02);
    }

    function refreshAllowance() public {
        IERC20Detailed(underlyingToken).approve(strategyToken, type(uint256).max);
    }

    function redeemRewards() external onlyOwner returns (uint256[] memory rewards) {
        rewards = new uint256[](2);
        rewards[1] = _claimGovernanceTokens();
        rewards[0] = _swapGovTokenOnUniswapAndDepositBack(0);
    }

    function redeemRewards(bytes calldata _extraData) external override onlyIdleCDO returns (uint256[] memory rewards) {
        uint256 minLiquidityTokenToReceive = abi.decode(_extraData, (uint256));
        rewards = new uint256[](2);
        rewards[1] = _claimGovernanceTokens();
        rewards[0] = _swapGovTokenOnUniswapAndDepositBack(minLiquidityTokenToReceive);
    }

    function _swapGovTokenOnUniswapAndDepositBack(uint256 minLiquidityTokenToReceive) internal returns (uint256) {
        IERC20Detailed _govToken = IERC20Detailed(compToken);
        uint256 govTokensToSend = _govToken.balanceOf(address(this));
        IUniswapV2Router02 _uniswapV2Router02 = uniswapV2Router02;

        _govToken.approve(address(_uniswapV2Router02), govTokensToSend);
        uint256 balanceBefore = IERC20Detailed(underlyingToken).balanceOf(address(this));
        _uniswapV2Router02.swapExactTokensForTokens(
            govTokensToSend,
            minLiquidityTokenToReceive,
            uniswapRouterPath,
            address(this),
            block.timestamp
        );
        uint256 balanceAfter = IERC20Detailed(underlyingToken).balanceOf(address(this));
        uint256 deposited = _deposit(balanceAfter - balanceBefore);
        _updateApr(int256(balanceAfter - balanceBefore));
        return deposited;
    }

    function _claimGovernanceTokens() internal returns (uint256) {
        uint256 balanceBefore = IERC20Detailed(compToken).balanceOf(address(this));
        IComptroller(comptroller).claimComp(address(this));
        uint256 balanceAfter = IERC20Detailed(compToken).balanceOf(address(this));
        return balanceAfter - balanceBefore;
    }

    function pullStkAAVE() external pure override returns (uint256) {}

    function deposit(uint256 _amount) external override onlyIdleCDO returns (uint256 minted) {
        if (_amount > 0) {
            return _deposit(_amount);
        }
    }

    function _deposit(uint256 _amount) internal returns (uint256 minted) {
        underlyingToken.transferFrom(msg.sender, address(this), _amount);
        uint256 status = ICToken(strategyToken).mint(_amount);
        uint256 cTokenBalanceBefore = IERC20Detailed(strategyToken).balanceOf(address(this));
        require(status == 0, "Error during Compound Mint");
        uint256 cTokenBalanceAfter = IERC20Detailed(strategyToken).balanceOf(address(this));
        _updateApr(int256(_amount));
        return cTokenBalanceAfter - cTokenBalanceBefore;
    }

    function boostRewards(uint256 numberOfTimes) external onlyIdleCDO {
        for (uint256 index = 0; index < numberOfTimes; index++) {
            uint256 cTokenBalanceAvailable = IERC20Detailed(strategyToken).balanceOf(address(this));
            console.log("cTokenBalanceAvailable", cTokenBalanceAvailable);
            uint256 amountAvailable = ICToken(strategyToken).balanceOfUnderlying(address(this));
            console.log("amountAvailable", amountAvailable);
            uint256 borrowAmount = calculateBorrowableAmount();
            console.log("borrowAmount", borrowAmount);
            uint256 status = ICToken(strategyToken).borrow(borrowAmount);
            require(status == 0, "Compound Error");
            status = ICToken(strategyToken).mint(borrowAmount);
            require(status == 0, "Compound Error");
            _print();
        }
    }

    function unboostAndRepay(uint256 amount) external onlyIdleCDO {
        uint256 status = ICToken(strategyToken).redeemUnderlying(amount);
        require(status == 0, "Compound redeem fail");
        status = ICToken(strategyToken).repayBorrow(amount);
        require(status == 0, "Compound Repay fail");
        _updateApr(-int256(amount));
    }

    function _print() internal view {
        (uint256 _error, uint256 accountLiquidity, uint256 shortfall) = IComptroller(comptroller).getAccountLiquidity(address(this));
        console.log("_error", _error);
        console.log("accountLiquidity", accountLiquidity);
        console.log("shortfall", shortfall);
    }

    function calculateBorrowableAmount() public view returns (uint256) {
        (uint256 _error, uint256 accountLiquidity, uint256 shortfall) = IComptroller(comptroller).getAccountLiquidity(address(this));
        require(_error == 0, "Can't borrow");
        return ((((accountLiquidity - shortfall) * oneToken) / 1e18) * borrowFraction) / 1e20;
    }

    function redeem(uint256 _amount) external override onlyIdleCDO returns (uint256) {
        uint256 exchangeRate = ICToken(strategyToken).exchangeRateCurrent();
        int256 amount = int256((_amount * exchangeRate) / 1e18);
        _updateApr(-amount);
        return ICToken(strategyToken).redeem(_amount);
    }

    function redeemUnderlying(uint256 _amount) external override onlyIdleCDO returns (uint256) {
        _updateApr(-int256(_amount));
        return ICToken(strategyToken).redeemUnderlying(_amount);
    }

    /// @notice net price in underlyings of 1 strategyToken
    /// @return _price
    function price() public view override returns (uint256 _price) {
        return ICToken(strategyToken).exchangeRateStored();
    }

    /// @notice Get the reward token
    /// @return _rewards array of reward token (empty as rewards are handled in this strategy)
    function getRewardTokens() external pure override returns (address[] memory _rewards) {}

    /// @notice Approximate APR
    /// @return apr
    function getApr() external view override returns (uint256 apr) {
        apr = lastApr;
    }

    /// @notice allow to update whitelisted address
    function setWhitelistedCDO(address _cdo) external onlyOwner {
        require(_cdo != address(0), "IS_0");
        idleCDO = _cdo;
    }

    /// @notice update last saved apr
    /// @param _amount amount of underlying tokens to mint/redeem
    function _updateApr(int256 _amount) internal {
        uint256 underlyingAmount = ICToken(strategyToken).balanceOfUnderlying(address(this));
        uint256 _lastIndexAmount = lastIndexAmount;
        if (lastIndexAmount > 0) {
            uint256 gainPerc = ((underlyingAmount - _lastIndexAmount) * 10**20) / _lastIndexAmount;
            lastApr = (YEAR / (block.timestamp - lastIndexedTime)) * gainPerc;
        }
        lastIndexedTime = block.timestamp;
        lastIndexAmount = uint256(int256(underlyingAmount) + _amount);
    }

    /// @notice Modifier to make sure that caller os only the idleCDO contract
    modifier onlyIdleCDO() {
        require(idleCDO == msg.sender, "Only IdleCDO can call");
        _;
    }
}

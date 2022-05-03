// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.10;

import "../../interfaces/IIdleCDOStrategy.sol";
import "../../interfaces/IERC20Detailed.sol";
import "../../interfaces/compound/ICToken.sol";
import "../../interfaces/compound/IComptroller.sol";

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

    function initialize(
        address _strategyToken,
        address _underlyingToken,
        address _comptroller,
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
        transferOwnership(_owner);
        IERC20Detailed(_underlyingToken).approve(_strategyToken, type(uint256).max);
    }

    function refreshAllowance() public {
        IERC20Detailed(underlyingToken).approve(strategyToken, type(uint256).max);
    }

    function redeemRewards(bytes calldata _extraData) external override onlyIdleCDO returns (uint256[] memory rewards) {}

    function pullStkAAVE() external pure override returns (uint256) {}

    function deposit(uint256 _amount) external override onlyIdleCDO returns (uint256 minted) {
        if (_amount > 0) {
            underlyingToken.transferFrom(msg.sender, address(this), _amount);
            uint256 status = ICToken(strategyToken).mint(_amount);
            uint256 cTokenBalanceBefore = IERC20Detailed(strategyToken).balanceOf(address(this));
            require(status == 0, "Error during Compound Mint");
            uint256 cTokenBalanceAfter = IERC20Detailed(strategyToken).balanceOf(address(this));
            return cTokenBalanceAfter - cTokenBalanceBefore;
        }
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

    function redeem(uint256 _amount) external override onlyIdleCDO returns (uint256) {}

    function redeemUnderlying(uint256 _amount) external override onlyIdleCDO returns (uint256) {}

    /// @notice net price in underlyings of 1 strategyToken
    /// @return _price
    function price() public view override returns (uint256 _price) {}

    /// @notice Get the reward token
    /// @return _rewards array of reward token (empty as rewards are handled in this strategy)
    function getRewardTokens() external pure override returns (address[] memory _rewards) {}

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

// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.10;

import "../../interfaces/IIdleCDOStrategy.sol";
import "../../interfaces/IERC20Detailed.sol";
import "../../interfaces/liquity/IStabilityPool.sol";

import "../../interfaces/IUniswapV3Interface.sol";
import "../../interfaces/IUniswapV3Pool.sol";
import "../../interfaces/IUniswapV3SwapCallback.sol";

import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";

import "hardhat/console.sol";

contract IdleLiquityStrategy is Initializable, OwnableUpgradeable, ERC20Upgradeable, ReentrancyGuardUpgradeable, IIdleCDOStrategy {
    using SafeERC20Upgradeable for IERC20Detailed;

    /// @notice underlying token address (ex: LUSD)
    address public override token;

    /// @notice strategy token address. (No strategy token for LUSD)
    address public override strategyToken;

    /// @notice decimals of the underlying asset
    uint256 public override tokenDecimals;

    /// @notice one underlying token
    uint256 public override oneToken;

    /// @notice underlying ERC20 token contract
    IERC20Detailed public underlyingToken;

    // ------------------new declarations ---------------//
    /// @notice address of stability
    IStabilityPool public stabilityPool;

    /// @notice LUSD has no gov token, however variable is declared as gov token for sake of consistency across all strategies
    address public govToken;

    /// @notice address of the IdleCDO
    address public idleCDO;

    /// @notice total strategy tokens staked
    uint256 public totalLpTokensStaked;

    /// @notice total strategy tokens locked
    uint256 public totalLpTokensLocked;

    /// @notice harvested strategy tokens release delay
    uint256 public releaseBlocksPeriod;

    /// @notice latest harvest
    uint256 public latestHarvestBlock;

    /// @notice latest saved apr
    uint256 public lastApr;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        token = address(1);
    }

    function initialize(address _owner) public initializer {
        OwnableUpgradeable.__Ownable_init();
        ReentrancyGuardUpgradeable.__ReentrancyGuard_init();

        token = 0x5f98805A4E8be255a32880FDeC7F6728C6568bA0;
        strategyToken = 0x66017D22b0f8556afDd19FC67041899Eb65a21bb;

        govToken = 0x6DEA81C8171D0bA574754EF6F8b412F2Ed88c54D;

        underlyingToken = IERC20Detailed(token);

        stabilityPool = IStabilityPool(strategyToken);
        ERC20Upgradeable.__ERC20_init("Idle Liquity Strategy Token", string(abi.encodePacked("idleLQTY", underlyingToken.symbol())));

        transferOwnership(_owner);

        IERC20Detailed(underlyingToken).safeApprove(strategyToken, type(uint256).max);
    }

    function redeemRewards() external onlyOwner returns (uint256[] memory rewards) {
        revert("To-Do");
    }

    function redeemRewards(bytes calldata _extraData) external override onlyIdleCDO returns (uint256[] memory rewards) {
        revert("To-Do");
    }

    function pullStkAAVE() external pure override returns (uint256) {
        return 0;
    }

    function price() public view override returns (uint256 _price) {
        uint256 _totalSupply = totalSupply();

        if (_totalSupply == 0) {
            _price = oneToken;
        } else {
            _price = ((totalLpTokensStaked - _lockedLpTokens()) * oneToken) / _totalSupply;
        }
    }

    function getRewardTokens() external pure override returns (address[] memory _rewards) {
        return _rewards;
    }

    function deposit(uint256 _amount) external override onlyIdleCDO returns (uint256 minted) {
        if (_amount != 0) {
            underlyingToken.transferFrom(msg.sender, address(this), _amount);
            minted = _depositToStabilityPool(_amount);
            console.log("deposit:minted", minted);
        }
    }

    function _depositToStabilityPool(uint256 _amount) internal returns (uint256) {
        uint256 lusdDepositBefore = stabilityPool.getCompoundedLUSDDeposit(address(this));
        stabilityPool.provideToSP(_amount, address(0));
        uint256 lusdDepositAfter = stabilityPool.getCompoundedLUSDDeposit(address(this));
        return lusdDepositAfter - lusdDepositBefore;
    }

    function getDepositorPosition()
        public
        view
        returns (
            uint256,
            uint256,
            uint256
        )
    {
        return (
            stabilityPool.getCompoundedLUSDDeposit(address(this)),
            stabilityPool.getDepositorETHGain(address(this)),
            stabilityPool.getDepositorLQTYGain(address(this))
        );
    }

    function redeem(uint256 _amount) external override onlyIdleCDO returns (uint256) {
        revert("To-do");
    }

    function redeemUnderlying(uint256 _amount) external override onlyIdleCDO returns (uint256) {
        revert("to-do");
    }

    function getApr() external view override returns (uint256 apr) {
        return lastApr;
    }

    function _lockedLpTokens() internal view returns (uint256 _locked) {
        uint256 _releaseBlocksPeriod = releaseBlocksPeriod;
        uint256 _blocksSinceLastHarvest = block.number - latestHarvestBlock;
        uint256 _totalLockedLpTokens = totalLpTokensLocked;

        if (_totalLockedLpTokens > 0 && _blocksSinceLastHarvest < _releaseBlocksPeriod) {
            // progressively release harvested rewards
            _locked = (_totalLockedLpTokens * (_releaseBlocksPeriod - _blocksSinceLastHarvest)) / _releaseBlocksPeriod;
        }
    }

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

const { expect } = require("chai");

const { ethers } = require("hardhat");

const { isAddress } = require("@ethersproject/address");
const { BigNumber } = require("@ethersproject/bignumber");
const BN = (n) => BigNumber.from(n.toString());

const erc20 = require("../../../artifacts/contracts/interfaces/IERC20Detailed.sol/IERC20Detailed.json");
const idleLiquityStrategyAbi =
  require("../../../artifacts/contracts/strategies/liquity/IdleLiquityStrategy.sol/IdleLiquityStrategy.json").abi;
const uniswapV3FactoryAbi = require("../../../artifacts/contracts/interfaces/IUniswapV3Interface.sol/IUniswapV3Factory.json").abi;
const uniswapV3PoolAbi = require("../../../artifacts/contracts/interfaces/IUniswapV3Pool.sol/IUniswapV3Pool.json").abi;
const swapRouterAbi = require("../../../artifacts/@uniswap/v3-periphery/contracts/interfaces/ISwapRouter.sol/ISwapRouter.json").abi;
const troveManagerAbi = require("../../../artifacts/contracts/interfaces/liquity/ITroveManager.sol/ITroveManager.json").abi;

const dai_whale = "0x075e72a5eDf65F0A5f44699c7654C1a76941Ddc8";

const DAIAddress = "0x6B175474E89094C44Da98b954EedeAC495271d0F";
const USDTAddress = "0xdAC17F958D2ee523a2206206994597C13D831ec7";
const LUSDAddress = "0x5f98805A4E8be255a32880FDeC7F6728C6568bA0";

const AMOUNT_TO_TRANSFER = BN("100000000000000000000"); // 100 DAI
const uniswapV3Factory = "0x1F98431c8aD98523631AE4a59f267346ea31F984";
const uniswapSwapRouter = "0xE592427A0AEce92De3Edee1F18E0157C05861564";

const zeroAddress = "0x0000000000000000000000000000000000000000";

const troveManagerAddress = "0xA39739EF8b0231DbFA0DcdA07d7e29faAbCf4bb2";

const LUSD_AMOUNT_TO_USE = BN("90000000000000000000");

// https://etherscan.io/tx/0xdd01aa7cb59c9b930d36f834732d3decf9bbde3815329b98b335c5428387dbd4
// transaction to refer to
describe.only("Idle Liquity Strategy", async () => {
  let IdleLiquityStrategy;
  let UniswapV3Factory;
  let uniswapPoolAddress;
  let uniswapPool;
  let swapRotuer;
  let swapper;
  let troveManager;

  let DAI;
  let LUSD;

  let owner;
  let user;
  let proxyAdmin;

  let dai_signer;

  let snapshotId;
  before(async () => {
    await ethers.provider.send("hardhat_impersonateAccount", [dai_whale]);
    await ethers.provider.send("hardhat_setBalance", [dai_whale, "0xffffffffffffffff"]);
    [owner, user, , , proxyAdmin, , anotherUser] = await ethers.getSigners();

    dai_signer = await ethers.getSigner(dai_whale);

    DAI = await ethers.getContractAt(erc20.abi, DAIAddress);
    await DAI.connect(dai_signer).transfer(user.address, AMOUNT_TO_TRANSFER);

    LUSD = await ethers.getContractAt(erc20.abi, LUSDAddress);

    let IdleLiquityStrategyFactory = await ethers.getContractFactory("IdleLiquityStrategy");
    let IdleLiquityStrategyLogic = await IdleLiquityStrategyFactory.deploy();

    let TransparentUpgradableProxyFactory = await ethers.getContractFactory("TransparentUpgradeableProxy");
    let TransparentUpgradableProxy = await TransparentUpgradableProxyFactory.deploy(
      IdleLiquityStrategyLogic.address,
      proxyAdmin.address,
      "0x"
    );
    await TransparentUpgradableProxy.deployed();

    IdleLiquityStrategy = await ethers.getContractAt(idleLiquityStrategyAbi, TransparentUpgradableProxy.address);
    await IdleLiquityStrategy.connect(owner).initialize(owner.address);
    UniswapV3Factory = await ethers.getContractAt(uniswapV3FactoryAbi, uniswapV3Factory);
    uniswapPoolAddress = await UniswapV3Factory.connect(user).getPool(DAIAddress, LUSDAddress, 500);
    expect(uniswapPoolAddress).not.eq(zeroAddress);

    uniswapPool = await ethers.getContractAt(uniswapV3PoolAbi, uniswapPoolAddress);
    swapRotuer = await ethers.getContractAt(swapRouterAbi, uniswapSwapRouter);
    troveManager = await ethers.getContractAt(troveManagerAbi, troveManagerAddress);

    let SwapperFactory = await ethers.getContractFactory("Swapper");
    swapper = await SwapperFactory.deploy(swapRotuer.address);
    await swapper.deployed();

    await DAI.connect(user).approve(swapper.address, AMOUNT_TO_TRANSFER);
    let path = encodeForUniswapV3([LUSDAddress, DAIAddress], [500]);

    console.log({ path });

    let userLUSDBalanceBefore = await LUSD.balanceOf(user.address);
    await swapper.connect(user).swapExactOutputMultihop(DAIAddress, path, LUSD_AMOUNT_TO_USE, AMOUNT_TO_TRANSFER);
    let userLUSDBalanceAfter = await LUSD.balanceOf(user.address);
    expect(userLUSDBalanceAfter.sub(userLUSDBalanceBefore)).eq(LUSD_AMOUNT_TO_USE);

    await IdleLiquityStrategy.connect(owner).setWhitelistedCDO(user.address);
  });

  beforeEach(async () => {
    snapshotId = await hre.network.provider.request({
      method: "evm_snapshot",
      params: [],
    });
  });

  afterEach(async () => {
    await hre.network.provider.request({
      method: "evm_revert",
      params: [snapshotId],
    });
  });

  it("Check deployments and balances", async () => {
    expect(isAddress(IdleLiquityStrategy.address)).eq(true);
    console.log({ uniswapPoolAddress });
  });

  it("Deposit", async () => {
    await LUSD.connect(user).approve(IdleLiquityStrategy.address, LUSD_AMOUNT_TO_USE);
    await IdleLiquityStrategy.connect(user).deposit(LUSD_AMOUNT_TO_USE);
    let result = await IdleLiquityStrategy.getDepositorPosition();
    result = result.map((a) => a.toString());
    console.log({ result });
  });

  it("Deposit Details after trove liquidations", async () => {
    await LUSD.connect(user).approve(IdleLiquityStrategy.address, LUSD_AMOUNT_TO_USE);
    await IdleLiquityStrategy.connect(user).deposit(LUSD_AMOUNT_TO_USE);
    let resultBefore = await IdleLiquityStrategy.getDepositorPosition();
    resultBefore = resultBefore.map((a) => a.toString());

    await troveManager.connect(anotherUser).liquidateTroves(10);

    let resultAfter = await IdleLiquityStrategy.getDepositorPosition();
    resultAfter = resultAfter.map((a) => a.toString());

    console.log({ resultBefore, resultAfter });
  });
});

function encodeForUniswapV3(path, fees) {
  const FEE_SIZE = 3;

  if (path.length != fees.length + 1) {
    throw new Error("path/fee lengths do not match");
  }

  let encoded = "0x";
  for (let i = 0; i < fees.length; i++) {
    // 20 byte encoding of the address
    encoded += path[i].slice(2);
    // 3 byte encoding of the fee
    encoded += fees[i].toString(16).padStart(2 * FEE_SIZE, "0");
  }
  // encode the final token
  encoded += path[path.length - 1].slice(2);

  return encoded.toLowerCase();
}

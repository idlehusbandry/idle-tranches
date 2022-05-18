require("hardhat/config");
const { ethers } = require("hardhat");
const { BigNumber } = require("@ethersproject/bignumber");
const BN = (n) => BigNumber.from(n.toString());

const erc20 = require("../../../artifacts/contracts/interfaces/IERC20Detailed.sol/IERC20Detailed.json");
const IdleLeveragedCompoundStrategyAbi =
  require("../../../artifacts/contracts/strategies/compound/IdleLeveragedCompoundStrategy.sol/IdleLeveragedCompoundStrategy.json").abi;

const { expect } = require("chai");

const DAIAddress = "0x6B175474E89094C44Da98b954EedeAC495271d0F"; // DAI

const strategyToken = "0x5d3a536e4d6dbd6114cc1ead35777bab948e3643"; // cDAI

const comptroller = "0x3d9819210a31b4961b30ef54be2aed79b9c9cd3b";

const comp = "0xc00e94cb662c3520282e6f5717214004a7f26888"; // COMP token

const dai_whale = "0x075e72a5eDf65F0A5f44699c7654C1a76941Ddc8";

const AMOUNT_TO_TRANSFER = BN("10000000000000000000000"); // 10000 DAI
const AMOUNT_TO_USE = BN("1000000000000000000"); // 1 DAI

describe.only("Leverage Compound Strategy", async () => {
  let snapshotId;

  let IdleLeveragedCompoundStrategy;
  let DAI;

  let owner;
  let user;
  let proxyAdmin;

  let dai_signer;

  beforeEach(async () => {
    await ethers.provider.send("hardhat_impersonateAccount", [dai_whale]);
    await ethers.provider.send("hardhat_setBalance", [dai_whale, "0xffffffffffffffff"]);

    [owner, user, , , proxyAdmin] = await ethers.getSigners();
    DAI = await ethers.getContractAt(erc20.abi, DAIAddress);
    dai_signer = await ethers.getSigner(dai_whale);

    let IdleLeveragedCompoundStrategyFactory = await ethers.getContractFactory("IdleLeveragedCompoundStrategy");
    let IdleLeveragedCompoundStrategyLogic = await IdleLeveragedCompoundStrategyFactory.deploy();

    let TransparentUpgradableProxyFactory = await ethers.getContractFactory("TransparentUpgradeableProxy");
    let TransparentUpgradableProxy = await TransparentUpgradableProxyFactory.deploy(
      IdleLeveragedCompoundStrategyLogic.address,
      proxyAdmin.address,
      "0x"
    );
    IdleLeveragedCompoundStrategy = await ethers.getContractAt(IdleLeveragedCompoundStrategyAbi, TransparentUpgradableProxy.address);

    await DAI.connect(dai_signer).transfer(user.address, AMOUNT_TO_TRANSFER);

    await IdleLeveragedCompoundStrategy.connect(owner).initialize(strategyToken, DAIAddress, comptroller, owner.address);
    await IdleLeveragedCompoundStrategy.connect(owner).setWhitelistedCDO(user.address);

    await TransparentUpgradableProxy.deployed();
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

  it("Check Deployment", async () => {});

  it("Deposit", async () => {
    await DAI.connect(user).approve(IdleLeveragedCompoundStrategy.address, AMOUNT_TO_USE);
    await IdleLeveragedCompoundStrategy.connect(user).deposit(AMOUNT_TO_USE);
  });

  it("Boost Reward", async () => {
    await DAI.connect(user).approve(IdleLeveragedCompoundStrategy.address, AMOUNT_TO_USE);
    await IdleLeveragedCompoundStrategy.connect(user).deposit(AMOUNT_TO_USE);
    await IdleLeveragedCompoundStrategy.connect(user).boostRewards(10);
  });
});

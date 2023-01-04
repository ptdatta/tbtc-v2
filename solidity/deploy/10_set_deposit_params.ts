import type { HardhatRuntimeEnvironment } from "hardhat/types"
import type { DeployFunction } from "hardhat-deploy/types"

const func: DeployFunction = async (hre: HardhatRuntimeEnvironment) => {
  const { deployments, ethers, getNamedAccounts } = hre
  const { execute, read } = deployments
  const { deployer } = await getNamedAccounts()

  deployments.log("setting initial deposit parameters")

  const depositTreasuryFeeDivisor = ethers.BigNumber.from("0")

  // We set the deposit reveal ahead period to 8 months and two weeks, assuming
  // 1 month = 4 weeks = 28 days. That gives 238 days which translates to
  // 238 * 24 * 60 * 60 = 20563200 seconds
  const depositRevealAheadPeriod = ethers.BigNumber.from("20563200")

  // Fetch the current values of other deposit parameters to keep them unchanged.
  const depositParameters = await read("Bridge", "depositParameters")

  await execute(
    "Bridge",
    { from: deployer, log: true, waitConfirmations: 1 },
    "updateDepositParameters",
    depositParameters.depositDustThreshold,
    depositTreasuryFeeDivisor,
    depositParameters.depositTxMaxFee,
    depositRevealAheadPeriod
  )
}

export default func

func.tags = ["SetDepositParams"]
func.dependencies = ["Bridge"]

func.skip = async (hre: HardhatRuntimeEnvironment): Promise<boolean> =>
  hre.network.name !== "mainnet"

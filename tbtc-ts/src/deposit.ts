// @ts-ignore
import bcoin from "bcoin"
// @ts-ignore
import { opcodes } from "bcoin/lib/script/common"
// @ts-ignore
import wif from "wif"
import { BigNumber } from "ethers"
import {
  Client as BitcoinClient,
  isCompressedPublicKey,
  RawTransaction,
  UnspentTransactionOutput,
} from "./bitcoin"

/**
 * Contains deposit data.
 */
export interface DepositData {
  /**
   * Ethereum address prefixed with '0x' that should be used for TBTC accounting.
   */
  ethereumAddress: string

  /**
   * Deposit amount in sathoshis.
   */
  amount: BigNumber

  /**
   * Compressed (33 bytes long with 02 or 03 prefix) Bitcoin public key that
   * is meant to be used during deposit refund after the locktime passes.
   */
  refundPublicKey: string

  /**
   * An 8 bytes number. Must be unique for given Ethereum address, signing group
   * public key and refund public key.
   */
  blindingFactor: BigNumber
}

// TODO: Documentation
export async function makeDeposit(
  depositData: DepositData,
  depositorPrivateKey: string,
  bitcoinClient: BitcoinClient
): Promise<void> {
  const decodedDepositorPrivateKey = wif.decode(depositorPrivateKey)

  const depositorKeyRing = new bcoin.KeyRing({
    witness: true,
    privateKey: decodedDepositorPrivateKey.privateKey,
    compressed: decodedDepositorPrivateKey.compressed,
  })

  const depositorAddress = depositorKeyRing.getAddress("string")

  const utxos = await bitcoinClient.findAllUnspentTransactionOutputs(
    depositorAddress
  )

  const utxosWithRaw: (UnspentTransactionOutput & RawTransaction)[] = []
  for (const utxo of utxos) {
    const rawTransaction = await bitcoinClient.getRawTransaction(
      utxo.transactionHash
    )

    utxosWithRaw.push({
      ...utxo,
      transactionHex: rawTransaction.transactionHex,
    })
  }

  const rawUnsignedTransaction = await createDepositTransaction(
    depositData,
    utxosWithRaw,
    depositorAddress
  )

  const unsignedTransaction = bcoin.MTX.fromRaw(
    rawUnsignedTransaction.transactionHex,
    "hex"
  )
  const signedTransaction = unsignedTransaction.sign(depositorKeyRing)

  await bitcoinClient.broadcast({
    transactionHex: signedTransaction.toRaw().toString("hex"),
  })
}

// TODO: Documentation
export async function createDepositTransaction(
  depositData: DepositData,
  utxos: (UnspentTransactionOutput & RawTransaction)[],
  changeAddress: string
): Promise<RawTransaction> {
  const inputCoins = utxos.map((utxo) =>
    bcoin.Coin.fromTX(
      bcoin.MTX.fromRaw(utxo.transactionHex, "hex"),
      utxo.outputIndex,
      -1
    )
  )

  const transaction = new bcoin.MTX()

  const scriptHash = await createDepositScriptHash(depositData)

  transaction.addOutput({
    script: bcoin.Script.fromScripthash(scriptHash),
    value: depositData.amount.toNumber(),
  })

  await transaction.fund(inputCoins, {
    rate: null, // set null explicitly to always use the default value
    changeAddress: changeAddress,
    subtractFee: false, // do not subtract the fee from outputs
  })

  return {
    transactionHex: transaction.toRaw().toString("hex"),
  }
}

// TODO: Documentation
export async function createDepositScript(
  depositData: DepositData
): Promise<string> {
  // Make sure Ethereum address is prefixed since the prefix is removed
  // while constructing the script.
  const ethereumAddress = depositData.ethereumAddress
  if (ethereumAddress.substring(0, 2) !== "0x") {
    throw new Error("Ethereum address must be prefixed with 0x")
  }

  // Blinding factor should be an 8 bytes number.
  const blindingFactor = depositData.blindingFactor
  if (blindingFactor.toHexString().substring(2).length != 16) {
    throw new Error("Blinding factor must be an 8 bytes number")
  }

  // Get the active wallet public key and use it as signing group public key.
  const signingGroupPublicKey = await getActiveWalletPublicKey()
  if (!isCompressedPublicKey(signingGroupPublicKey)) {
    throw new Error("Signing group public key must be compressed")
  }

  const refundPublicKey = depositData.refundPublicKey
  if (!isCompressedPublicKey(refundPublicKey)) {
    throw new Error("Refund public key must be compressed")
  }

  // Locktime is an Unix timestamp in seconds, computed as now + 30 days.
  const locktime = BigNumber.from(Math.floor(Date.now() / 1000) + 2592000)

  // All HEXes pushed to the script must be un-prefixed.
  const script = new bcoin.Script()
  script.clear()
  script.pushData(Buffer.from(ethereumAddress.substring(2), "hex"))
  script.pushOp(opcodes.OP_DROP)
  script.pushData(Buffer.from(blindingFactor.toHexString().substring(2), "hex"))
  script.pushOp(opcodes.OP_DROP)
  script.pushOp(opcodes.OP_DUP)
  script.pushOp(opcodes.OP_HASH160)
  script.pushData(Buffer.from(signingGroupPublicKey, "hex"))
  script.pushOp(opcodes.OP_EQUAL)
  script.pushOp(opcodes.OP_IF)
  script.pushOp(opcodes.OP_CHECKSIG)
  script.pushOp(opcodes.OP_ELSE)
  script.pushOp(opcodes.OP_DUP)
  script.pushOp(opcodes.OP_HASH160)
  script.pushData(Buffer.from(refundPublicKey, "hex"))
  script.pushOp(opcodes.OP_EQUALVERIFY)
  script.pushData(Buffer.from(locktime.toHexString().substring(2), "hex"))
  script.pushOp(opcodes.OP_CHECKLOCKTIMEVERIFY)
  script.pushOp(opcodes.OP_DROP)
  script.pushOp(opcodes.OP_CHECKSIG)
  script.pushOp(opcodes.OP_ENDIF)
  script.compile()

  // Return script as HEX string.
  return script.toRaw().toString("hex")
}

// TODO: Documentation
export async function createDepositScriptHash(
  depositData: DepositData
): Promise<Buffer> {
  const script = await createDepositScript(depositData)
  // Parse the script from HEX string and compute the HASH160.
  return bcoin.Script.fromRaw(Buffer.from(script, "hex")).hash160()
}

// TODO: Documentation
export async function createDepositAddress(
  depositData: DepositData,
  network: string
): Promise<string> {
  const scriptHash = await createDepositScriptHash(depositData)
  const address = bcoin.Address.fromScripthash(scriptHash)
  return address.toString(network)
}

// TODO: Implementation and documentation. Dummy key is returned for now,
async function getActiveWalletPublicKey(): Promise<string> {
  return "0222a6145ec68cf6f3e94a17e4ed3ee4e092a8cdc551075b1376054479f65b7480"
}

export async function revealDeposit(): Promise<void> {
  // TODO: Implementation.
}

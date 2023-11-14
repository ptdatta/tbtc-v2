import { ethers, Signer } from "ethers"
import {
  Account,
  WalletAPIClient,
  WindowMessageTransport,
} from "@ledgerhq/wallet-api-client"
import BigNumber from "bignumber.js"
import { AddressZero } from "@ethersproject/constants"
import { Deferrable } from "@ethersproject/properties"
import { Hex } from "./hex"

class AccountNotFoundError extends Error {
  constructor() {
    super(
      "Account not found. Please use `requestAccount` method or set the signer account with `setAccount` method."
    )
  }
}

/**
 * Ethereum signer extended from `ethers` Signer class. The main purpose of it
 * is to allow the user to communicate with eth contracts through our tBTC SDK
 * inside Ledger Live application, when the app is used there as a Live App.
 */
export class LedgerLiveEthereumSigner extends Signer {
  private _walletApiClient: WalletAPIClient
  private _windowMessageTransport: WindowMessageTransport
  private _account: Account | undefined

  constructor(
    provider: ethers.providers.Provider
  ) {
    super()
    ethers.utils.defineReadOnly(this, "provider", provider || null)
    this._windowMessageTransport = getWindowMessageTransport()
    this._walletApiClient = getWalletAPIClient(this._windowMessageTransport)
  }

  get account() {
    return this._account
  }

  setAccount(account: Account | undefined): void {
    this._account = account
  }

  async requestAccount(
    params: { currencyIds?: string[] | undefined } | undefined
  ): Promise<Account> {
    this._windowMessageTransport.connect()
    const account = await this._walletApiClient.account.request(params)
    this._windowMessageTransport.disconnect()
    this._account = account
    return this._account
  }

  getAccountId(): string {
    if (!this._account || !this._account.id) {
      throw new AccountNotFoundError()
    }
    return this._account.id
  }

  async getAddress(): Promise<string> {
    if (!this._account || !this._account.address) {
      throw new AccountNotFoundError()
    }
    return this._account.address
  }

  async signMessage(message: string): Promise<string> {
    if (!this._account || !this._account.address) {
      throw new AccountNotFoundError()
    }
    this._windowMessageTransport.connect()
    const buffer = await this._walletApiClient.message.sign(
      this._account.id,
      Buffer.from(message)
    )
    this._windowMessageTransport.disconnect()
    return buffer.toString()
  }

  async signTransaction(
    transaction: ethers.providers.TransactionRequest
  ): Promise<string> {
    if (!this._account || !this._account.address) {
      throw new AccountNotFoundError()
    }

    const { value, to, nonce, data, gasPrice, gasLimit } = transaction

    const ethereumTransaction: any = {
      family: "ethereum" as const,
      amount: value ? new BigNumber(value.toString()) : new BigNumber(0),
      recipient: to ? to : AddressZero,
    }

    if (nonce) ethereumTransaction.nonce = nonce
    if (data)
      ethereumTransaction.data = Buffer.from(
        Hex.from(data.toString()).toString(),
        "hex"
      )
    if (gasPrice)
      ethereumTransaction.gasPrice = new BigNumber(gasPrice.toString())
    if (gasLimit)
      ethereumTransaction.gasLimit = new BigNumber(gasLimit.toString())

    this._windowMessageTransport.connect()
    const buffer = await this._walletApiClient.transaction.sign(
      this._account.id,
      ethereumTransaction
    )
    this._windowMessageTransport.disconnect()
    return buffer.toString()
  }

  async sendTransaction(
    transaction: Deferrable<ethers.providers.TransactionRequest>
  ): Promise<ethers.providers.TransactionResponse> {
    if (!this._account || !this._account.address) {
      throw new AccountNotFoundError()
    }

    const { value, to, nonce, data, gasPrice, gasLimit } = transaction

    const ethereumTransaction: any = {
      family: "ethereum" as const,
      amount: value ? new BigNumber(value.toString()) : new BigNumber(0),
      recipient: to ? to : AddressZero,
    }

    if (nonce) ethereumTransaction.nonce = nonce
    if (data)
      ethereumTransaction.data = Buffer.from(
        Hex.from(data.toString()).toString(),
        "hex"
      )
    if (gasPrice)
      ethereumTransaction.gasPrice = new BigNumber(gasPrice.toString())
    if (gasLimit)
      ethereumTransaction.gasLimit = new BigNumber(gasLimit.toString())

    this._windowMessageTransport.connect()
    const transactionHash =
      await this._walletApiClient.transaction.signAndBroadcast(
        this._account.id,
        ethereumTransaction
      )
    this._windowMessageTransport.disconnect()

    const transactionResponse = await this.provider?.getTransaction(
      transactionHash
    )

    if (!transactionResponse) {
      throw new Error("Transaction response not found!")
    }

    return transactionResponse
  }

  connect(provider: ethers.providers.Provider): Signer {
    return new LedgerLiveEthereumSigner(provider)
  }
}

const getWindowMessageTransport = () => {
  return new WindowMessageTransport()
}

const getWalletAPIClient = (
  windowMessageTransport: WindowMessageTransport
) => {
  const walletApiClient = new WalletAPIClient(windowMessageTransport)

  return walletApiClient
}

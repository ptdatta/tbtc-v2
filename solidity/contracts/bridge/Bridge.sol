// SPDX-License-Identifier: MIT

// ██████████████     ▐████▌     ██████████████
// ██████████████     ▐████▌     ██████████████
//               ▐████▌    ▐████▌
//               ▐████▌    ▐████▌
// ██████████████     ▐████▌     ██████████████
// ██████████████     ▐████▌     ██████████████
//               ▐████▌    ▐████▌
//               ▐████▌    ▐████▌
//               ▐████▌    ▐████▌
//               ▐████▌    ▐████▌
//               ▐████▌    ▐████▌
//               ▐████▌    ▐████▌

pragma solidity ^0.8.9;

import "@openzeppelin/contracts/access/Ownable.sol";

import {BTCUtils} from "@keep-network/bitcoin-spv-sol/contracts/BTCUtils.sol";
import {BytesLib} from "@keep-network/bitcoin-spv-sol/contracts/BytesLib.sol";

import {IWalletOwner as EcdsaWalletOwner} from "@keep-network/ecdsa/contracts/api/IWalletOwner.sol";

import "./IRelay.sol";
import "./BridgeState.sol";
import "./Deposit.sol";
import "./Sweep.sol";
import "./BitcoinTx.sol";
import "./EcdsaLib.sol";
import "./Wallets.sol";
import "./Frauds.sol";

import "../bank/Bank.sol";

/// @title Bitcoin Bridge
/// @notice Bridge manages BTC deposit and redemption flow and is increasing and
///         decreasing balances in the Bank as a result of BTC deposit and
///         redemption operations performed by depositors and redeemers.
///
///         Depositors send BTC funds to the most recently created off-chain
///         ECDSA wallet of the bridge using pay-to-script-hash (P2SH) or
///         pay-to-witness-script-hash (P2WSH) containing hashed information
///         about the depositor’s Ethereum address. Then, the depositor reveals
///         their Ethereum address along with their deposit blinding factor,
///         refund public key hash and refund locktime to the Bridge on Ethereum
///         chain. The off-chain ECDSA wallet listens for these sorts of
///         messages and when it gets one, it checks the Bitcoin network to make
///         sure the deposit lines up. If it does, the off-chain ECDSA wallet
///         may decide to pick the deposit transaction for sweeping, and when
///         the sweep operation is confirmed on the Bitcoin network, the ECDSA
///         wallet informs the Bridge about the sweep increasing appropriate
///         balances in the Bank.
/// @dev Bridge is an upgradeable component of the Bank.
///
/// TODO: All wallets-related operations that are currently done directly
///       by the Bridge can be probably delegated to the Wallets library.
///       Examples of such operations are main UTXO or pending redemptions
///       value updates.
contract Bridge is Ownable, EcdsaWalletOwner {
    using BridgeState for BridgeState.Storage;
    using Deposit for BridgeState.Storage;
    using Sweep for BridgeState.Storage;
    using Frauds for Frauds.Data;
    using Wallets for Wallets.Data;

    using BTCUtils for bytes;
    using BTCUtils for uint256;
    using BytesLib for bytes;

    /// @notice Represents a redemption request.
    struct RedemptionRequest {
        // ETH address of the redeemer who created the request.
        address redeemer;
        // Requested TBTC amount in satoshi.
        uint64 requestedAmount;
        // Treasury TBTC fee in satoshi at the moment of request creation.
        uint64 treasuryFee;
        // Transaction maximum BTC fee in satoshi at the moment of request
        // creation.
        uint64 txMaxFee;
        // UNIX timestamp the request was created at.
        uint32 requestedAt;
    }

    /// @notice Represents an outcome of the redemption Bitcoin transaction
    ///         outputs processing.
    struct RedemptionTxOutputsInfo {
        // Total TBTC value in satoshi that should be burned by the Bridge.
        // It includes the total amount of all BTC redeemed in the transaction
        // and the fee paid to BTC miners for the redemption transaction.
        uint64 totalBurnableValue;
        // Total TBTC value in satoshi that should be transferred to
        // the treasury. It is a sum of all treasury fees paid by all
        // redeemers included in the redemption transaction.
        uint64 totalTreasuryFee;
        // Index of the change output. The change output becomes
        // the new main wallet's UTXO.
        uint32 changeIndex;
        // Value in satoshi of the change output.
        uint64 changeValue;
    }

    /// @notice Represents temporary information needed during the processing of
    ///         the redemption Bitcoin transaction outputs. This structure is an
    ///         internal one and should not be exported outside of the redemption
    ///         transaction processing code.
    /// @dev Allows to mitigate "stack too deep" errors on EVM.
    struct RedemptionTxOutputsProcessingInfo {
        // The first output starting index in the transaction.
        uint256 outputStartingIndex;
        // The number of outputs in the transaction.
        uint256 outputsCount;
        // P2PKH script for the wallet. Needed to determine the change output.
        bytes32 walletP2PKHScriptKeccak;
        // P2WPKH script for the wallet. Needed to determine the change output.
        bytes32 walletP2WPKHScriptKeccak;
    }

    BridgeState.Storage internal self;

    /// TODO: Make it governable.
    /// @notice The minimal amount that can be requested for redemption.
    ///         Value of this parameter must take into account the value of
    ///         `redemptionTreasuryFeeDivisor` and `redemptionTxMaxFee`
    ///         parameters in order to make requests that can incur the
    ///         treasury and transaction fee and still satisfy the redeemer.
    uint64 public redemptionDustThreshold;

    /// TODO: Make it governable.
    /// @notice Divisor used to compute the treasury fee taken from each
    ///         redemption request and transferred to the treasury upon
    ///         successful request finalization. That fee is computed as follows:
    ///         `treasuryFee = requestedAmount / redemptionTreasuryFeeDivisor`
    ///         For example, if the treasury fee needs to be 2% of each
    ///         redemption request, the `redemptionTreasuryFeeDivisor` should
    ///         be set to `50` because `1/50 = 0.02 = 2%`.
    uint64 public redemptionTreasuryFeeDivisor;

    /// TODO: Make it governable.
    /// @notice Maximum amount of BTC transaction fee that can be incurred by
    ///         each redemption request being part of the given redemption
    ///         transaction. If the maximum BTC transaction fee is exceeded, such
    ///         transaction is considered a fraud.
    /// @dev This is a per-redemption output max fee for the redemption transaction.
    uint64 public redemptionTxMaxFee;

    /// TODO: Make it governable.
    /// @notice Time after which the redemption request can be reported as
    ///         timed out. It is counted from the moment when the redemption
    ///         request was created via `requestRedemption` call. Reported
    ///         timed out requests are cancelled and locked TBTC is returned
    ///         to the redeemer in full amount.
    uint256 public redemptionTimeout;

    /// TODO: Make it governable.
    /// @notice Maximum amount of the total BTC transaction fee that is
    ///         acceptable in a single moving funds transaction.
    /// @dev This is a TOTAL max fee for the moving funds transaction. Note that
    ///      `depositTxMaxFee` is per single deposit and `redemptionTxMaxFee`
    ///      if per single redemption. `movingFundsTxMaxTotalFee` is a total fee
    ///      for the entire transaction.
    uint64 public movingFundsTxMaxTotalFee;

    /// @notice Collection of all pending redemption requests indexed by
    ///         redemption key built as
    ///         keccak256(walletPubKeyHash | redeemerOutputScript). The
    ///         walletPubKeyHash is the 20-byte wallet's public key hash
    ///         (computed using Bitcoin HASH160 over the compressed ECDSA
    ///         public key) and redeemerOutputScript is a Bitcoin script
    ///         (P2PKH, P2WPKH, P2SH or P2WSH) that will be used to lock
    ///         redeemed BTC as requested by the redeemer. Requests are added
    ///         to this mapping by the `requestRedemption` method (duplicates
    ///         not allowed) and are removed by one of the following methods:
    ///         - `submitRedemptionProof` in case the request was handled
    ///           successfully
    ///         - `notifyRedemptionTimeout` in case the request was reported
    ///           to be timed out
    mapping(uint256 => RedemptionRequest) public pendingRedemptions;

    /// @notice Collection of all timed out redemptions requests indexed by
    ///         redemption key built as
    ///         keccak256(walletPubKeyHash | redeemerOutputScript). The
    ///         walletPubKeyHash is the 20-byte wallet's public key hash
    ///         (computed using Bitcoin HASH160 over the compressed ECDSA
    ///         public key) and redeemerOutputScript is the Bitcoin script
    ///         (P2PKH, P2WPKH, P2SH or P2WSH) that is involved in the timed
    ///         out request. Timed out requests are stored in this mapping to
    ///         avoid slashing the wallets multiple times for the same timeout.
    ///         Only one method can add to this mapping:
    ///         - `notifyRedemptionTimeout` which puts the redemption key
    ///           to this mapping basing on a timed out request stored
    ///           previously in `pendingRedemptions` mapping.
    mapping(uint256 => RedemptionRequest) public timedOutRedemptions;

    /// @notice Contains parameters related to frauds and the collection of all
    ///         submitted fraud challenges.
    Frauds.Data internal frauds;

    /// @notice State related with wallets.
    Wallets.Data internal wallets;

    event WalletCreationPeriodUpdated(uint32 newCreationPeriod);

    event WalletBtcBalanceRangeUpdated(
        uint64 newMinBtcBalance,
        uint64 newMaxBtcBalance
    );

    event WalletMaxAgeUpdated(uint32 newMaxAge);

    event NewWalletRequested();

    event NewWalletRegistered(
        bytes32 indexed ecdsaWalletID,
        bytes20 indexed walletPubKeyHash
    );

    event WalletMovingFunds(
        bytes32 indexed ecdsaWalletID,
        bytes20 indexed walletPubKeyHash
    );

    event WalletClosed(
        bytes32 indexed ecdsaWalletID,
        bytes20 indexed walletPubKeyHash
    );

    event WalletTerminated(
        bytes32 indexed ecdsaWalletID,
        bytes20 indexed walletPubKeyHash
    );

    event VaultStatusUpdated(address indexed vault, bool isTrusted);

    event FraudSlashingAmountUpdated(uint256 newFraudSlashingAmount);

    event FraudNotifierRewardMultiplierUpdated(
        uint256 newFraudNotifierRewardMultiplier
    );

    event FraudChallengeDefeatTimeoutUpdated(
        uint256 newFraudChallengeDefeatTimeout
    );

    event FraudChallengeDepositAmountUpdated(
        uint256 newFraudChallengeDepositAmount
    );

    event DepositRevealed(
        bytes32 fundingTxHash,
        uint32 fundingOutputIndex,
        address depositor,
        uint64 amount,
        bytes8 blindingFactor,
        bytes20 walletPubKeyHash,
        bytes20 refundPubKeyHash,
        bytes4 refundLocktime,
        address vault
    );

    event DepositsSwept(bytes20 walletPubKeyHash, bytes32 sweepTxHash);

    event RedemptionRequested(
        bytes20 walletPubKeyHash,
        bytes redeemerOutputScript,
        address redeemer,
        uint64 requestedAmount,
        uint64 treasuryFee,
        uint64 txMaxFee
    );

    event RedemptionsCompleted(
        bytes20 walletPubKeyHash,
        bytes32 redemptionTxHash
    );

    event RedemptionTimedOut(
        bytes20 walletPubKeyHash,
        bytes redeemerOutputScript
    );

    event FraudChallengeSubmitted(
        bytes20 walletPublicKeyHash,
        bytes32 sighash,
        uint8 v,
        bytes32 r,
        bytes32 s
    );

    event FraudChallengeDefeated(bytes20 walletPublicKeyHash, bytes32 sighash);

    event FraudChallengeDefeatTimedOut(
        bytes20 walletPublicKeyHash,
        bytes32 sighash
    );

    event MovingFundsCompleted(
        bytes20 walletPubKeyHash,
        bytes32 movingFundsTxHash
    );

    constructor(
        address _bank,
        address _relay,
        address _treasury,
        address _ecdsaWalletRegistry,
        uint256 _txProofDifficultyFactor
    ) {
        require(_bank != address(0), "Bank address cannot be zero");
        self.bank = Bank(_bank);

        require(_relay != address(0), "Relay address cannot be zero");
        self.relay = IRelay(_relay);

        require(_treasury != address(0), "Treasury address cannot be zero");
        self.treasury = _treasury;

        self.txProofDifficultyFactor = _txProofDifficultyFactor;

        // TODO: Revisit initial values.
        self.depositDustThreshold = 1000000; // 1000000 satoshi = 0.01 BTC
        self.depositTxMaxFee = 10000; // 10000 satoshi
        self.depositTreasuryFeeDivisor = 2000; // 1/2000 == 5bps == 0.05% == 0.0005
        redemptionDustThreshold = 1000000; // 1000000 satoshi = 0.01 BTC
        redemptionTreasuryFeeDivisor = 2000; // 1/2000 == 5bps == 0.05% == 0.0005
        redemptionTxMaxFee = 10000; // 10000 satoshi
        redemptionTimeout = 172800; // 48 hours
        movingFundsTxMaxTotalFee = 10000; // 10000 satoshi

        // TODO: Revisit initial values.
        frauds.setSlashingAmount(10000 * 1e18); // 10000 T
        frauds.setNotifierRewardMultiplier(100); // 100%
        frauds.setChallengeDefeatTimeout(7 days);
        frauds.setChallengeDepositAmount(2 ether);

        // TODO: Revisit initial values.
        wallets.init(_ecdsaWalletRegistry);
        wallets.setCreationPeriod(1 weeks);
        wallets.setBtcBalanceRange(1 * 1e8, 10 * 1e8); // [1 BTC, 10 BTC]
        wallets.setMaxAge(26 weeks); // ~6 months
    }

    /// @notice Updates parameters used by the `Wallets` library.
    /// @param creationPeriod New value of the wallet creation period
    /// @param minBtcBalance New value of the minimum BTC balance
    /// @param maxBtcBalance New value of the maximum BTC balance
    /// @param maxAge New value of the wallet maximum age
    /// @dev Requirements:
    ///      - Caller must be the contract owner.
    ///      - Minimum BTC balance must be greater than zero
    ///      - Maximum BTC balance must be greater than minimum BTC balance
    function updateWalletsParameters(
        uint32 creationPeriod,
        uint64 minBtcBalance,
        uint64 maxBtcBalance,
        uint32 maxAge
    ) external onlyOwner {
        wallets.setCreationPeriod(creationPeriod);
        wallets.setBtcBalanceRange(minBtcBalance, maxBtcBalance);
        wallets.setMaxAge(maxAge);
    }

    /// @return creationPeriod Value of the wallet creation period
    /// @return minBtcBalance Value of the minimum BTC balance
    /// @return maxBtcBalance Value of the maximum BTC balance
    /// @return maxAge Value of the wallet max age
    function getWalletsParameters()
        external
        view
        returns (
            uint32 creationPeriod,
            uint64 minBtcBalance,
            uint64 maxBtcBalance,
            uint32 maxAge
        )
    {
        creationPeriod = wallets.creationPeriod;
        minBtcBalance = wallets.minBtcBalance;
        maxBtcBalance = wallets.maxBtcBalance;
        maxAge = wallets.maxAge;

        return (creationPeriod, minBtcBalance, maxBtcBalance, maxAge);
    }

    /// @notice Allows the Governance to mark the given vault address as trusted
    ///         or no longer trusted. Vaults are not trusted by default.
    ///         Trusted vault must meet the following criteria:
    ///         - `IVault.receiveBalanceIncrease` must have a known, low gas
    ///           cost.
    ///         - `IVault.receiveBalanceIncrease` must never revert.
    /// @dev Without restricting reveal only to trusted vaults, malicious
    ///      vaults not meeting the criteria would be able to nuke sweep proof
    ///      transactions executed by ECDSA wallet with  deposits routed to
    ///      them.
    /// @param vault The address of the vault
    /// @param isTrusted flag indicating whether the vault is trusted or not
    /// @dev Can only be called by the Governance.
    function setVaultStatus(address vault, bool isTrusted) external onlyOwner {
        self.isVaultTrusted[vault] = isTrusted;
        emit VaultStatusUpdated(vault, isTrusted);
    }

    /// @notice Requests creation of a new wallet. This function just
    ///         forms a request and the creation process is performed
    ///         asynchronously. Once a wallet is created, the ECDSA Wallet
    ///         Registry will notify this contract by calling the
    ///         `__ecdsaWalletCreatedCallback` function.
    /// @param activeWalletMainUtxo Data of the active wallet's main UTXO, as
    ///        currently known on the Ethereum chain.
    /// @dev Requirements:
    ///      - `activeWalletMainUtxo` components must point to the recent main
    ///        UTXO of the given active wallet, as currently known on the
    ///        Ethereum chain. If there is no active wallet at the moment, or
    ///        the active wallet has no main UTXO, this parameter can be
    ///        empty as it is ignored.
    ///      - Wallet creation must not be in progress
    ///      - If the active wallet is set, one of the following
    ///        conditions must be true:
    ///        - The active wallet BTC balance is above the minimum threshold
    ///          and the active wallet is old enough, i.e. the creation period
    ///          was elapsed since its creation time
    ///        - The active wallet BTC balance is above the maximum threshold
    function requestNewWallet(BitcoinTx.UTXO calldata activeWalletMainUtxo)
        external
    {
        wallets.requestNewWallet(activeWalletMainUtxo);
    }

    /// @notice A callback function that is called by the ECDSA Wallet Registry
    ///         once a new ECDSA wallet is created.
    /// @param ecdsaWalletID Wallet's unique identifier.
    /// @param publicKeyX Wallet's public key's X coordinate.
    /// @param publicKeyY Wallet's public key's Y coordinate.
    /// @dev Requirements:
    ///      - The only caller authorized to call this function is `registry`
    ///      - Given wallet data must not belong to an already registered wallet
    function __ecdsaWalletCreatedCallback(
        bytes32 ecdsaWalletID,
        bytes32 publicKeyX,
        bytes32 publicKeyY
    ) external override {
        wallets.registerNewWallet(ecdsaWalletID, publicKeyX, publicKeyY);
    }

    /// @notice A callback function that is called by the ECDSA Wallet Registry
    ///         once a wallet heartbeat failure is detected.
    /// @param publicKeyX Wallet's public key's X coordinate
    /// @param publicKeyY Wallet's public key's Y coordinate
    /// @dev Requirements:
    ///      - The only caller authorized to call this function is `registry`
    ///      - Wallet must be in Live state
    function __ecdsaWalletHeartbeatFailedCallback(
        bytes32,
        bytes32 publicKeyX,
        bytes32 publicKeyY
    ) external override {
        wallets.notifyWalletHeartbeatFailed(publicKeyX, publicKeyY);
    }

    /// @notice Notifies that the wallet is either old enough or has too few
    ///         satoshis left and qualifies to be closed.
    /// @param walletPubKeyHash 20-byte public key hash of the wallet
    /// @param walletMainUtxo Data of the wallet's main UTXO, as currently
    ///        known on the Ethereum chain.
    /// @dev Requirements:
    ///      - Wallet must not be set as the current active wallet
    ///      - Wallet must exceed the wallet maximum age OR the wallet BTC
    ///        balance must be lesser than the minimum threshold. If the latter
    ///        case is true, the `walletMainUtxo` components must point to the
    ///        recent main UTXO of the given wallet, as currently known on the
    ///        Ethereum chain. If the wallet has no main UTXO, this parameter
    ///        can be empty as it is ignored since the wallet balance is
    ///        assumed to be zero.
    ///      - Wallet must be in Live state
    function notifyCloseableWallet(
        bytes20 walletPubKeyHash,
        BitcoinTx.UTXO calldata walletMainUtxo
    ) external {
        wallets.notifyCloseableWallet(walletPubKeyHash, walletMainUtxo);
    }

    /// @notice Gets details about a registered wallet.
    /// @param walletPubKeyHash The 20-byte wallet public key hash (computed
    ///        using Bitcoin HASH160 over the compressed ECDSA public key)
    /// @return Wallet details.
    function getWallet(bytes20 walletPubKeyHash)
        external
        view
        returns (Wallets.Wallet memory)
    {
        return wallets.registeredWallets[walletPubKeyHash];
    }

    /// @notice Gets the public key hash of the active wallet.
    /// @return The 20-byte public key hash (computed using Bitcoin HASH160
    ///         over the compressed ECDSA public key) of the active wallet.
    ///         Returns bytes20(0) if there is no active wallet at the moment.
    function getActiveWalletPubKeyHash() external view returns (bytes20) {
        return wallets.activeWalletPubKeyHash;
    }

    /// @notice Used by the depositor to reveal information about their P2(W)SH
    ///         Bitcoin deposit to the Bridge on Ethereum chain. The off-chain
    ///         wallet listens for revealed deposit events and may decide to
    ///         include the revealed deposit in the next executed sweep.
    ///         Information about the Bitcoin deposit can be revealed before or
    ///         after the Bitcoin transaction with P2(W)SH deposit is mined on
    ///         the Bitcoin chain. Worth noting, the gas cost of this function
    ///         scales with the number of P2(W)SH transaction inputs and
    ///         outputs. The deposit may be routed to one of the trusted vaults.
    ///         When a deposit is routed to a vault, vault gets notified when
    ///         the deposit gets swept and it may execute the appropriate action.
    /// @param fundingTx Bitcoin funding transaction data, see `BitcoinTx.Info`
    /// @param reveal Deposit reveal data, see `RevealInfo struct
    /// @dev Requirements:
    ///      - `reveal.walletPubKeyHash` must identify a `Live` wallet
    ///      - `reveal.vault` must be 0x0 or point to a trusted vault
    ///      - `reveal.fundingOutputIndex` must point to the actual P2(W)SH
    ///        output of the BTC deposit transaction
    ///      - `reveal.depositor` must be the Ethereum address used in the
    ///        P2(W)SH BTC deposit transaction,
    ///      - `reveal.blindingFactor` must be the blinding factor used in the
    ///        P2(W)SH BTC deposit transaction,
    ///      - `reveal.walletPubKeyHash` must be the wallet pub key hash used in
    ///        the P2(W)SH BTC deposit transaction,
    ///      - `reveal.refundPubKeyHash` must be the refund pub key hash used in
    ///        the P2(W)SH BTC deposit transaction,
    ///      - `reveal.refundLocktime` must be the refund locktime used in the
    ///        P2(W)SH BTC deposit transaction,
    ///      - BTC deposit for the given `fundingTxHash`, `fundingOutputIndex`
    ///        can be revealed only one time.
    ///
    ///      If any of these requirements is not met, the wallet _must_ refuse
    ///      to sweep the deposit and the depositor has to wait until the
    ///      deposit script unlocks to receive their BTC back.
    function revealDeposit(
        BitcoinTx.Info calldata fundingTx,
        Deposit.RevealInfo calldata reveal
    ) external {
        self.revealDeposit(wallets, fundingTx, reveal);
    }

    /// @notice Used by the wallet to prove the BTC deposit sweep transaction
    ///         and to update Bank balances accordingly. Sweep is only accepted
    ///         if it satisfies SPV proof.
    ///
    ///         The function is performing Bank balance updates by first
    ///         computing the Bitcoin fee for the sweep transaction. The fee is
    ///         divided evenly between all swept deposits. Each depositor
    ///         receives a balance in the bank equal to the amount inferred
    ///         during the reveal transaction, minus their fee share.
    ///
    ///         It is possible to prove the given sweep only one time.
    /// @param sweepTx Bitcoin sweep transaction data
    /// @param sweepProof Bitcoin sweep proof data
    /// @param mainUtxo Data of the wallet's main UTXO, as currently known on
    ///        the Ethereum chain. If no main UTXO exists for the given wallet,
    ///        this parameter is ignored
    /// @dev Requirements:
    ///      - `sweepTx` components must match the expected structure. See
    ///        `BitcoinTx.Info` docs for reference. Their values must exactly
    ///        correspond to appropriate Bitcoin transaction fields to produce
    ///        a provable transaction hash.
    ///      - The `sweepTx` should represent a Bitcoin transaction with 1..n
    ///        inputs. If the wallet has no main UTXO, all n inputs should
    ///        correspond to P2(W)SH revealed deposits UTXOs. If the wallet has
    ///        an existing main UTXO, one of the n inputs must point to that
    ///        main UTXO and remaining n-1 inputs should correspond to P2(W)SH
    ///        revealed deposits UTXOs. That transaction must have only
    ///        one P2(W)PKH output locking funds on the 20-byte wallet public
    ///        key hash.
    ///      - `sweepProof` components must match the expected structure. See
    ///        `BitcoinTx.Proof` docs for reference. The `bitcoinHeaders`
    ///        field must contain a valid number of block headers, not less
    ///        than the `txProofDifficultyFactor` contract constant.
    ///      - `mainUtxo` components must point to the recent main UTXO
    ///        of the given wallet, as currently known on the Ethereum chain.
    ///        If there is no main UTXO, this parameter is ignored.
    function submitSweepProof(
        BitcoinTx.Info calldata sweepTx,
        BitcoinTx.Proof calldata sweepProof,
        BitcoinTx.UTXO calldata mainUtxo
    ) external {
        self.submitSweepProof(wallets, sweepTx, sweepProof, mainUtxo);
    }

    /// @notice Submits a fraud challenge indicating that a UTXO being under
    ///         wallet control was unlocked by the wallet but was not used
    ///         according to the protocol rules. That means the wallet signed
    ///         a transaction input pointing to that UTXO and there is a unique
    ///         sighash and signature pair associated with that input. This
    ///         function uses those parameters to create a fraud accusation that
    ///         proves a given transaction input unlocking the given UTXO was
    ///         actually signed by the wallet. This function cannot determine
    ///         whether the transaction was actually broadcast and the input was
    ///         consumed in a fraudulent way so it just opens a challenge period
    ///         during which the wallet can defeat the challenge by submitting
    ///         proof of a transaction that consumes the given input according
    ///         to protocol rules. To prevent spurious allegations, the caller
    ///         must deposit ETH that is returned back upon justified fraud
    ///         challenge or confiscated otherwise.
    ///@param walletPublicKey The public key of the wallet in the uncompressed
    ///       and unprefixed format (64 bytes)
    /// @param sighash The hash that was used to produce the ECDSA signature
    ///        that is the subject of the fraud claim. This hash is constructed
    ///        by applying double SHA-256 over a serialized subset of the
    ///        transaction. The exact subset used as hash preimage depends on
    ///        the transaction input the signature is produced for. See BIP-143
    ///        for reference
    /// @param signature Bitcoin signature in the R/S/V format
    /// @dev Requirements:
    ///      - Wallet behind `walletPubKey` must be in `Live` or `MovingFunds`
    ///        state
    ///      - The challenger must send appropriate amount of ETH used as
    ///        fraud challenge deposit
    ///      - The signature (represented by r, s and v) must be generated by
    ///        the wallet behind `walletPubKey` during signing of `sighash`
    ///      - Wallet can be challenged for the given signature only once
    function submitFraudChallenge(
        bytes calldata walletPublicKey,
        bytes32 sighash,
        BitcoinTx.RSVSignature calldata signature
    ) external payable {
        bytes memory compressedWalletPublicKey = EcdsaLib.compressPublicKey(
            walletPublicKey.slice32(0),
            walletPublicKey.slice32(32)
        );
        bytes20 walletPubKeyHash = compressedWalletPublicKey.hash160View();

        Wallets.Wallet storage wallet = wallets.registeredWallets[
            walletPubKeyHash
        ];

        require(
            wallet.state == Wallets.WalletState.Live ||
                wallet.state == Wallets.WalletState.MovingFunds,
            "Wallet is neither in Live nor MovingFunds state"
        );

        frauds.submitChallenge(
            walletPublicKey,
            walletPubKeyHash,
            sighash,
            signature
        );
    }

    /// @notice Allows to defeat a pending fraud challenge against a wallet if
    ///         the transaction that spends the UTXO follows the protocol rules.
    ///         In order to defeat the challenge the same `walletPublicKey` and
    ///         signature (represented by `r`, `s` and `v`) must be provided as
    ///         were used to calculate the sighash during input signing.
    ///         The fraud challenge defeat attempt will only succeed if the
    ///         inputs in the preimage are considered honestly spent by the
    ///         wallet. Therefore the transaction spending the UTXO must be
    ///         proven in the Bridge before a challenge defeat is called.
    ///         If successfully defeated, the fraud challenge is marked as
    ///         resolved and the amount of ether deposited by the challenger is
    ///         sent to the treasury.
    /// @param walletPublicKey The public key of the wallet in the uncompressed
    ///        and unprefixed format (64 bytes)
    /// @param preimage The preimage which produces sighash used to generate the
    ///        ECDSA signature that is the subject of the fraud claim. It is a
    ///        serialized subset of the transaction. The exact subset used as
    ///        the preimage depends on the transaction input the signature is
    ///        produced for. See BIP-143 for reference
    /// @param witness Flag indicating whether the preimage was produced for a
    ///        witness input. True for witness, false for non-witness input
    /// @dev Requirements:
    ///      - `walletPublicKey` and `sighash` calculated as `hash256(preimage)`
    ///        must identify an open fraud challenge
    ///      - the preimage must be a valid preimage of a transaction generated
    ///        according to the protocol rules and already proved in the Bridge
    ///      - before a defeat attempt is made the transaction that spends the
    ///        given UTXO must be proven in the Bridge
    function defeatFraudChallenge(
        bytes calldata walletPublicKey,
        bytes calldata preimage,
        bool witness
    ) external {
        uint256 utxoKey = frauds.unwrapChallenge(
            walletPublicKey,
            preimage,
            witness
        );

        // Check that the UTXO key identifies a correctly spent UTXO.
        require(
            self.deposits[utxoKey].sweptAt > 0 || self.spentMainUTXOs[utxoKey],
            "Spent UTXO not found among correctly spent UTXOs"
        );

        frauds.defeatChallenge(walletPublicKey, preimage, self.treasury);
    }

    /// @notice Notifies about defeat timeout for the given fraud challenge.
    ///         Can be called only if there was a fraud challenge identified by
    ///         the provided `walletPublicKey` and `sighash` and it was not
    ///         defeated on time. The amount of time that needs to pass after
    ///         a fraud challenge is reported is indicated by the
    ///         `challengeDefeatTimeout`. After a successful fraud challenge
    ///         defeat timeout notification the fraud challenge is marked as
    ///         resolved, the stake of each operator is slashed, the ether
    ///         deposited is returned to the challenger and the challenger is
    ///         rewarded.
    /// @param walletPublicKey The public key of the wallet in the uncompressed
    ///        and unprefixed format (64 bytes)
    /// @param sighash The hash that was used to produce the ECDSA signature
    ///        that is the subject of the fraud claim. This hash is constructed
    ///        by applying double SHA-256 over a serialized subset of the
    ///        transaction. The exact subset used as hash preimage depends on
    ///        the transaction input the signature is produced for. See BIP-143
    ///        for reference
    /// @dev Requirements:
    ///      - `walletPublicKey`and `sighash` must identify an open fraud
    ///        challenge
    ///      - the amount of time indicated by `challengeDefeatTimeout` must
    ///        pass after the challenge was reported
    function notifyFraudChallengeDefeatTimeout(
        bytes calldata walletPublicKey,
        bytes32 sighash
    ) external {
        frauds.notifyChallengeDefeatTimeout(walletPublicKey, sighash);
    }

    /// @notice Returns parameters used by the `Frauds` library.
    /// @return slashingAmount Value of the slashing amount
    /// @return notifierRewardMultiplier Value of the notifier reward multiplier
    /// @return challengeDefeatTimeout Value of the challenge defeat timeout
    /// @return challengeDepositAmount Value of the challenge deposit amount
    function getFraudParameters()
        external
        view
        returns (
            uint256 slashingAmount,
            uint256 notifierRewardMultiplier,
            uint256 challengeDefeatTimeout,
            uint256 challengeDepositAmount
        )
    {
        slashingAmount = frauds.slashingAmount;
        notifierRewardMultiplier = frauds.notifierRewardMultiplier;
        challengeDefeatTimeout = frauds.challengeDefeatTimeout;
        challengeDepositAmount = frauds.challengeDepositAmount;

        return (
            slashingAmount,
            notifierRewardMultiplier,
            challengeDefeatTimeout,
            challengeDepositAmount
        );
    }

    /// @notice Returns the fraud challenge identified by the given key built
    ///         as keccak256(walletPublicKey|sighash).
    function fraudChallenges(uint256 challengeKey)
        external
        view
        returns (Frauds.FraudChallenge memory)
    {
        return frauds.challenges[challengeKey];
    }

    /// @notice Requests redemption of the given amount from the specified
    ///         wallet to the redeemer Bitcoin output script.
    /// @param walletPubKeyHash The 20-byte wallet public key hash (computed
    ///        using Bitcoin HASH160 over the compressed ECDSA public key)
    /// @param mainUtxo Data of the wallet's main UTXO, as currently known on
    ///        the Ethereum chain
    /// @param redeemerOutputScript The redeemer's length-prefixed output
    ///        script (P2PKH, P2WPKH, P2SH or P2WSH) that will be used to lock
    ///        redeemed BTC
    /// @param amount Requested amount in satoshi. This is also the TBTC amount
    ///        that is taken from redeemer's balance in the Bank upon request.
    ///        Once the request is handled, the actual amount of BTC locked
    ///        on the redeemer output script will be always lower than this value
    ///        since the treasury and Bitcoin transaction fees must be incurred.
    ///        The minimal amount satisfying the request can be computed as:
    ///        `amount - (amount / redemptionTreasuryFeeDivisor) - redemptionTxMaxFee`.
    ///        Fees values are taken at the moment of request creation.
    /// @dev Requirements:
    ///      - Wallet behind `walletPubKeyHash` must be live
    ///      - `mainUtxo` components must point to the recent main UTXO
    ///        of the given wallet, as currently known on the Ethereum chain.
    ///      - `redeemerOutputScript` must be a proper Bitcoin script
    ///      - `redeemerOutputScript` cannot have wallet PKH as payload
    ///      - `amount` must be above or equal the `redemptionDustThreshold`
    ///      - Given `walletPubKeyHash` and `redeemerOutputScript` pair can be
    ///        used for only one pending request at the same time
    ///      - Wallet must have enough Bitcoin balance to proceed the request
    ///      - Redeemer must make an allowance in the Bank that the Bridge
    ///        contract can spend the given `amount`.
    function requestRedemption(
        bytes20 walletPubKeyHash,
        BitcoinTx.UTXO calldata mainUtxo,
        bytes calldata redeemerOutputScript,
        uint64 amount
    ) external {
        Wallets.Wallet storage wallet = wallets.registeredWallets[
            walletPubKeyHash
        ];

        require(
            wallet.state == Wallets.WalletState.Live,
            "Wallet must be in Live state"
        );

        bytes32 mainUtxoHash = wallet.mainUtxoHash;
        require(
            mainUtxoHash != bytes32(0),
            "No main UTXO for the given wallet"
        );
        require(
            keccak256(
                abi.encodePacked(
                    mainUtxo.txHash,
                    mainUtxo.txOutputIndex,
                    mainUtxo.txOutputValue
                )
            ) == mainUtxoHash,
            "Invalid main UTXO data"
        );

        // TODO: Confirm if `walletPubKeyHash` should be validated by checking
        //       if it is the oldest one who can handle the request. This will
        //       be suggested by the dApp but may not be respected by users who
        //       interact directly with the contract. Do we need to enforce it
        //       here? One option is not to enforce it, to save on gas, but if
        //       we see this rule is not respected, upgrade Bridge contract to
        //       require it.

        // Validate if redeemer output script is a correct standard type
        // (P2PKH, P2WPKH, P2SH or P2WSH). This is done by building a stub
        // output with 0 as value and using `BTCUtils.extractHash` on it. Such
        // a function extracts the payload properly only from standard outputs
        // so if it succeeds, we have a guarantee the redeemer output script
        // is proper. Worth to note `extractHash` ignores the value at all
        // so this is why we can use 0 safely. This way of validation is the
        // same as in tBTC v1.
        bytes memory redeemerOutputScriptPayload = abi
            .encodePacked(bytes8(0), redeemerOutputScript)
            .extractHash();
        require(
            redeemerOutputScriptPayload.length > 0,
            "Redeemer output script must be a standard type"
        );
        // Check if the redeemer output script payload does not point to the
        // wallet public key hash.
        require(
            keccak256(abi.encodePacked(walletPubKeyHash)) !=
                keccak256(redeemerOutputScriptPayload),
            "Redeemer output script must not point to the wallet PKH"
        );

        require(
            amount >= redemptionDustThreshold,
            "Redemption amount too small"
        );

        // The redemption key is built on top of the wallet public key hash
        // and redeemer output script pair. That means there can be only one
        // request asking for redemption from the given wallet to the given
        // BTC script at the same time.
        uint256 redemptionKey = uint256(
            keccak256(abi.encodePacked(walletPubKeyHash, redeemerOutputScript))
        );

        // Check if given redemption key is not used by a pending redemption.
        // There is no need to check for existence in `timedOutRedemptions`
        // since the wallet's state is changed to other than Live after
        // first time out is reported so making new requests is not possible.
        // slither-disable-next-line incorrect-equality
        require(
            pendingRedemptions[redemptionKey].requestedAt == 0,
            "There is a pending redemption request from this wallet to the same address"
        );

        // No need to check whether `amount - treasuryFee - txMaxFee > 0`
        // since the `redemptionDustThreshold` should force that condition
        // to be always true.
        uint64 treasuryFee = redemptionTreasuryFeeDivisor > 0
            ? amount / redemptionTreasuryFeeDivisor
            : 0;
        uint64 txMaxFee = redemptionTxMaxFee;

        // The main wallet UTXO's value doesn't include all pending redemptions.
        // To determine if the requested redemption can be performed by the
        // wallet we need to subtract the total value of all pending redemptions
        // from that wallet's main UTXO value. Given that the treasury fee is
        // not redeemed from the wallet, we are subtracting it.
        wallet.pendingRedemptionsValue += amount - treasuryFee;
        require(
            mainUtxo.txOutputValue >= wallet.pendingRedemptionsValue,
            "Insufficient wallet funds"
        );

        pendingRedemptions[redemptionKey] = RedemptionRequest(
            msg.sender,
            amount,
            treasuryFee,
            txMaxFee,
            /* solhint-disable-next-line not-rely-on-time */
            uint32(block.timestamp)
        );

        emit RedemptionRequested(
            walletPubKeyHash,
            redeemerOutputScript,
            msg.sender,
            amount,
            treasuryFee,
            txMaxFee
        );

        self.bank.transferBalanceFrom(msg.sender, address(this), amount);
    }

    /// @notice Used by the wallet to prove the BTC redemption transaction
    ///         and to make the necessary bookkeeping. Redemption is only
    ///         accepted if it satisfies SPV proof.
    ///
    ///         The function is performing Bank balance updates by burning
    ///         the total redeemed Bitcoin amount from Bridge balance and
    ///         transferring the treasury fee sum to the treasury address.
    ///
    ///         It is possible to prove the given redemption only one time.
    /// @param redemptionTx Bitcoin redemption transaction data
    /// @param redemptionProof Bitcoin redemption proof data
    /// @param mainUtxo Data of the wallet's main UTXO, as currently known on
    ///        the Ethereum chain
    /// @param walletPubKeyHash 20-byte public key hash (computed using Bitcoin
    ///        HASH160 over the compressed ECDSA public key) of the wallet which
    ///        performed the redemption transaction
    /// @dev Requirements:
    ///      - `redemptionTx` components must match the expected structure. See
    ///        `BitcoinTx.Info` docs for reference. Their values must exactly
    ///        correspond to appropriate Bitcoin transaction fields to produce
    ///        a provable transaction hash.
    ///      - The `redemptionTx` should represent a Bitcoin transaction with
    ///        exactly 1 input that refers to the wallet's main UTXO. That
    ///        transaction should have 1..n outputs handling existing pending
    ///        redemption requests or pointing to reported timed out requests.
    ///        There can be also 1 optional output representing the
    ///        change and pointing back to the 20-byte wallet public key hash.
    ///        The change should be always present if the redeemed value sum
    ///        is lower than the total wallet's BTC balance.
    ///      - `redemptionProof` components must match the expected structure.
    ///        See `BitcoinTx.Proof` docs for reference. The `bitcoinHeaders`
    ///        field must contain a valid number of block headers, not less
    ///        than the `txProofDifficultyFactor` contract constant.
    ///      - `mainUtxo` components must point to the recent main UTXO
    ///        of the given wallet, as currently known on the Ethereum chain.
    ///        Additionally, the recent main UTXO on Ethereum must be set.
    ///      - `walletPubKeyHash` must be connected with the main UTXO used
    ///        as transaction single input.
    ///      Other remarks:
    ///      - Putting the change output as the first transaction output can
    ///        save some gas because the output processing loop begins each
    ///        iteration by checking whether the given output is the change
    ///        thus uses some gas for making the comparison. Once the change
    ///        is identified, that check is omitted in further iterations.
    function submitRedemptionProof(
        BitcoinTx.Info calldata redemptionTx,
        BitcoinTx.Proof calldata redemptionProof,
        BitcoinTx.UTXO calldata mainUtxo,
        bytes20 walletPubKeyHash
    ) external {
        // TODO: Just as for `submitSweepProof`, fail early if the function
        //       call gets frontrunned. See discussion:
        //       https://github.com/keep-network/tbtc-v2/pull/106#discussion_r801745204

        // The actual transaction proof is performed here. After that point, we
        // can assume the transaction happened on Bitcoin chain and has
        // a sufficient number of confirmations as determined by
        // `txProofDifficultyFactor` constant.
        bytes32 redemptionTxHash = BitcoinTx.validateProof(
            redemptionTx,
            redemptionProof,
            self.proofDifficultyContext()
        );

        // Process the redemption transaction input. Specifically, check if it
        // refers to the expected wallet's main UTXO.
        processWalletOutboundTxInput(
            redemptionTx.inputVector,
            mainUtxo,
            walletPubKeyHash
        );

        Wallets.Wallet storage wallet = wallets.registeredWallets[
            walletPubKeyHash
        ];

        Wallets.WalletState walletState = wallet.state;
        require(
            walletState == Wallets.WalletState.Live ||
                walletState == Wallets.WalletState.MovingFunds,
            "Wallet must be in Live or MovingFuds state"
        );

        // Process redemption transaction outputs to extract some info required
        // for further processing.
        RedemptionTxOutputsInfo memory outputsInfo = processRedemptionTxOutputs(
            redemptionTx.outputVector,
            walletPubKeyHash
        );

        if (outputsInfo.changeValue > 0) {
            // If the change value is grater than zero, it means the change
            // output exists and can be used as new wallet's main UTXO.
            wallet.mainUtxoHash = keccak256(
                abi.encodePacked(
                    redemptionTxHash,
                    outputsInfo.changeIndex,
                    outputsInfo.changeValue
                )
            );
        } else {
            // If the change value is zero, it means the change output doesn't
            // exists and no funds left on the wallet. Delete the main UTXO
            // for that wallet to represent that state in a proper way.
            delete wallet.mainUtxoHash;
        }

        wallet.pendingRedemptionsValue -= outputsInfo.totalBurnableValue;

        emit RedemptionsCompleted(walletPubKeyHash, redemptionTxHash);

        self.bank.decreaseBalance(outputsInfo.totalBurnableValue);
        self.bank.transferBalance(self.treasury, outputsInfo.totalTreasuryFee);
    }

    /// @notice Checks whether an outbound Bitcoin transaction performed from
    ///         the given wallet has an input vector that contains a single
    ///         input referring to the wallet's main UTXO. Marks that main UTXO
    ///         as correctly spent if the validation succeeds. Reverts otherwise.
    ///         There are two outbound transactions from a wallet possible: a
    ///         redemption transaction or a moving funds to another wallet
    ///         transaction.
    /// @param walletOutboundTxInputVector Bitcoin outbound transaction's input
    ///        vector. This function assumes vector's structure is valid so it
    ///        must be validated using e.g. `BTCUtils.validateVin` function
    ///        before it is passed here
    /// @param mainUtxo Data of the wallet's main UTXO, as currently known on
    ///        the Ethereum chain.
    /// @param walletPubKeyHash 20-byte public key hash (computed using Bitcoin
    //         HASH160 over the compressed ECDSA public key) of the wallet which
    ///        performed the outbound transaction.
    function processWalletOutboundTxInput(
        bytes memory walletOutboundTxInputVector,
        BitcoinTx.UTXO calldata mainUtxo,
        bytes20 walletPubKeyHash
    ) internal {
        // Assert that main UTXO for passed wallet exists in storage.
        bytes32 mainUtxoHash = wallets
            .registeredWallets[walletPubKeyHash]
            .mainUtxoHash;
        require(mainUtxoHash != bytes32(0), "No main UTXO for given wallet");

        // Assert that passed main UTXO parameter is the same as in storage and
        // can be used for further processing.
        require(
            keccak256(
                abi.encodePacked(
                    mainUtxo.txHash,
                    mainUtxo.txOutputIndex,
                    mainUtxo.txOutputValue
                )
            ) == mainUtxoHash,
            "Invalid main UTXO data"
        );

        // Assert that the single outbound transaction input actually
        // refers to the wallet's main UTXO.
        (
            bytes32 outpointTxHash,
            uint32 outpointIndex
        ) = parseWalletOutboundTxInput(walletOutboundTxInputVector);
        require(
            mainUtxo.txHash == outpointTxHash &&
                mainUtxo.txOutputIndex == outpointIndex,
            "Outbound transaction input must point to the wallet's main UTXO"
        );

        // Main UTXO used as an input, mark it as spent.
        self.spentMainUTXOs[
            uint256(
                keccak256(
                    abi.encodePacked(mainUtxo.txHash, mainUtxo.txOutputIndex)
                )
            )
        ] = true;
    }

    /// @notice Parses the input vector of an outbound Bitcoin transaction
    ///         performed from the given wallet. It extracts the single input
    ///         then the transaction hash and output index from its outpoint.
    ///         There are two outbound transactions from a wallet possible: a
    ///         redemption transaction or a moving funds to another wallet
    ///         transaction.
    /// @param walletOutboundTxInputVector Bitcoin outbound transaction input
    ///        vector. This function assumes vector's structure is valid so it
    ///        must be validated using e.g. `BTCUtils.validateVin` function
    ///        before it is passed here
    /// @return outpointTxHash 32-byte hash of the Bitcoin transaction which is
    ///         pointed in the input's outpoint.
    /// @return outpointIndex 4-byte index of the Bitcoin transaction output
    ///         which is pointed in the input's outpoint.
    function parseWalletOutboundTxInput(
        bytes memory walletOutboundTxInputVector
    ) internal pure returns (bytes32 outpointTxHash, uint32 outpointIndex) {
        // To determine the total number of Bitcoin transaction inputs,
        // we need to parse the compactSize uint (VarInt) the input vector is
        // prepended by. That compactSize uint encodes the number of vector
        // elements using the format presented in:
        // https://developer.bitcoin.org/reference/transactions.html#compactsize-unsigned-integers
        // We don't need asserting the compactSize uint is parseable since it
        // was already checked during `validateVin` validation.
        // See `BitcoinTx.inputVector` docs for more details.
        (, uint256 inputsCount) = walletOutboundTxInputVector.parseVarInt();
        require(
            inputsCount == 1,
            "Outbound transaction must have a single input"
        );

        bytes memory input = walletOutboundTxInputVector.extractInputAtIndex(0);

        outpointTxHash = input.extractInputTxIdLE();

        outpointIndex = BTCUtils.reverseUint32(
            uint32(input.extractTxIndexLE())
        );

        // There is only one input in the transaction. Input has an outpoint
        // field that is a reference to the transaction being spent (see
        // `BitcoinTx` docs). The outpoint contains the hash of the transaction
        // to spend (`outpointTxHash`) and the index of the specific output
        // from that transaction (`outpointIndex`).
        return (outpointTxHash, outpointIndex);
    }

    /// @notice Processes the Bitcoin redemption transaction output vector.
    ///         It extracts each output and tries to identify it as a pending
    ///         redemption request, reported timed out request, or change.
    ///         Reverts if one of the outputs cannot be recognized properly.
    ///         This function also marks each request as processed by removing
    ///         them from `pendingRedemptions` mapping.
    /// @param redemptionTxOutputVector Bitcoin redemption transaction output
    ///        vector. This function assumes vector's structure is valid so it
    ///        must be validated using e.g. `BTCUtils.validateVout` function
    ///        before it is passed here
    /// @param walletPubKeyHash 20-byte public key hash (computed using Bitcoin
    //         HASH160 over the compressed ECDSA public key) of the wallet which
    ///        performed the redemption transaction.
    /// @return info Outcomes of the processing.
    function processRedemptionTxOutputs(
        bytes memory redemptionTxOutputVector,
        bytes20 walletPubKeyHash
    ) internal returns (RedemptionTxOutputsInfo memory info) {
        // Determining the total number of redemption transaction outputs in
        // the same way as for number of inputs. See `BitcoinTx.outputVector`
        // docs for more details.
        (
            uint256 outputsCompactSizeUintLength,
            uint256 outputsCount
        ) = redemptionTxOutputVector.parseVarInt();

        // To determine the first output starting index, we must jump over
        // the compactSize uint which prepends the output vector. One byte
        // must be added because `BtcUtils.parseVarInt` does not include
        // compactSize uint tag in the returned length.
        //
        // For >= 0 && <= 252, `BTCUtils.determineVarIntDataLengthAt`
        // returns `0`, so we jump over one byte of compactSize uint.
        //
        // For >= 253 && <= 0xffff there is `0xfd` tag,
        // `BTCUtils.determineVarIntDataLengthAt` returns `2` (no
        // tag byte included) so we need to jump over 1+2 bytes of
        // compactSize uint.
        //
        // Please refer `BTCUtils` library and compactSize uint
        // docs in `BitcoinTx` library for more details.
        uint256 outputStartingIndex = 1 + outputsCompactSizeUintLength;

        // Calculate the keccak256 for two possible wallet's P2PKH or P2WPKH
        // scripts that can be used to lock the change. This is done upfront to
        // save on gas. Both scripts have a strict format defined by Bitcoin.
        //
        // The P2PKH script has the byte format: <0x1976a914> <20-byte PKH> <0x88ac>.
        // According to https://en.bitcoin.it/wiki/Script#Opcodes this translates to:
        // - 0x19: Byte length of the entire script
        // - 0x76: OP_DUP
        // - 0xa9: OP_HASH160
        // - 0x14: Byte length of the public key hash
        // - 0x88: OP_EQUALVERIFY
        // - 0xac: OP_CHECKSIG
        // which matches the P2PKH structure as per:
        // https://en.bitcoin.it/wiki/Transaction#Pay-to-PubkeyHash
        bytes32 walletP2PKHScriptKeccak = keccak256(
            abi.encodePacked(hex"1976a914", walletPubKeyHash, hex"88ac")
        );
        // The P2WPKH script has the byte format: <0x160014> <20-byte PKH>.
        // According to https://en.bitcoin.it/wiki/Script#Opcodes this translates to:
        // - 0x16: Byte length of the entire script
        // - 0x00: OP_0
        // - 0x14: Byte length of the public key hash
        // which matches the P2WPKH structure as per:
        // https://github.com/bitcoin/bips/blob/master/bip-0141.mediawiki#P2WPKH
        bytes32 walletP2WPKHScriptKeccak = keccak256(
            abi.encodePacked(hex"160014", walletPubKeyHash)
        );

        return
            processRedemptionTxOutputs(
                redemptionTxOutputVector,
                walletPubKeyHash,
                RedemptionTxOutputsProcessingInfo(
                    outputStartingIndex,
                    outputsCount,
                    walletP2PKHScriptKeccak,
                    walletP2WPKHScriptKeccak
                )
            );
    }

    /// @notice Processes all outputs from the redemption transaction. Tries to
    ///         identify output as a change output, pending redemption request
    //          or reported redemption. Reverts if one of the outputs cannot be
    ///         recognized properly. Marks each request as processed by removing
    ///         them from `pendingRedemptions` mapping.
    /// @param redemptionTxOutputVector Bitcoin redemption transaction output
    ///        vector. This function assumes vector's structure is valid so it
    ///        must be validated using e.g. `BTCUtils.validateVout` function
    ///        before it is passed here
    /// @param walletPubKeyHash 20-byte public key hash (computed using Bitcoin
    //         HASH160 over the compressed ECDSA public key) of the wallet which
    ///        performed the redemption transaction.
    /// @param processInfo RedemptionTxOutputsProcessingInfo identifying output
    ///        starting index, the number of outputs and possible wallet change
    ///        P2PKH and P2WPKH scripts.
    function processRedemptionTxOutputs(
        bytes memory redemptionTxOutputVector,
        bytes20 walletPubKeyHash,
        RedemptionTxOutputsProcessingInfo memory processInfo
    ) internal returns (RedemptionTxOutputsInfo memory resultInfo) {
        // Helper variable that counts the number of processed redemption
        // outputs. Redemptions can be either pending or reported as timed out.
        // TODO: Revisit the approach with redemptions count according to
        //       https://github.com/keep-network/tbtc-v2/pull/128#discussion_r808237765
        uint256 processedRedemptionsCount = 0;

        // Outputs processing loop.
        for (uint256 i = 0; i < processInfo.outputsCount; i++) {
            // TODO: Check if we can optimize gas costs by adding
            //       `extractValueAt` and `extractHashAt` in `bitcoin-spv-sol`
            //       in order to avoid allocating bytes in memory.
            uint256 outputLength = redemptionTxOutputVector
                .determineOutputLengthAt(processInfo.outputStartingIndex);
            bytes memory output = redemptionTxOutputVector.slice(
                processInfo.outputStartingIndex,
                outputLength
            );

            // Extract the value from given output.
            uint64 outputValue = output.extractValue();
            // The output consists of an 8-byte value and a variable length
            // script. To extract that script we slice the output starting from
            // 9th byte until the end.
            bytes memory outputScript = output.slice(8, output.length - 8);

            if (
                resultInfo.changeValue == 0 &&
                (keccak256(outputScript) ==
                    processInfo.walletP2PKHScriptKeccak ||
                    keccak256(outputScript) ==
                    processInfo.walletP2WPKHScriptKeccak) &&
                outputValue > 0
            ) {
                // If we entered here, that means the change output with a
                // proper non-zero value was found.
                resultInfo.changeIndex = uint32(i);
                resultInfo.changeValue = outputValue;
            } else {
                // If we entered here, that the means the given output is
                // supposed to represent a redemption.
                (
                    uint64 burnableValue,
                    uint64 treasuryFee
                ) = processNonChangeRedemptionTxOutput(
                        walletPubKeyHash,
                        outputScript,
                        outputValue
                    );
                resultInfo.totalBurnableValue += burnableValue;
                resultInfo.totalTreasuryFee += treasuryFee;
                processedRedemptionsCount++;
            }

            // Make the `outputStartingIndex` pointing to the next output by
            // increasing it by current output's length.
            processInfo.outputStartingIndex += outputLength;
        }

        // Protect against the cases when there is only a single change output
        // referring back to the wallet PKH and just burning main UTXO value
        // for transaction fees.
        require(
            processedRedemptionsCount > 0,
            "Redemption transaction must process at least one redemption"
        );
    }

    /// @notice Processes a single redemption transaction output. Tries to
    ///         identify output as a pending redemption request or reported
    ///         redemption timeout. Output script passed to this function must
    ///         not be the change output. Such output needs to be identified
    ///         separately before calling this function.
    ///         Reverts if output is neither requested pending redemption nor
    ///         requested and reported timed-out redemption.
    ///         This function also marks each pending request as processed by 
    ///         removing it from `pendingRedemptions` mapping.
    /// @param walletPubKeyHash 20-byte public key hash (computed using Bitcoin
    //         HASH160 over the compressed ECDSA public key) of the wallet which
    ///        performed the redemption transaction.
    /// @param outputScript Non-change output script to be processed
    /// @param outputValue Value of the output being processed
    /// @return burnableValue The value burnable as a result of processing this
    ///         single redemption output. This value needs to be summed up with
    ///         burnable values of all other outputs to evaluate total burnable
    ///         value for the entire redemption transaction. This value is 0
    ///         for a timed-out redemption request.
    /// @return treasuryFee The treasury fee from this single redemption output.
    ///         This value needs to be summed up with treasury fees of all other
    ///         outputs to evaluate the total treasury fee for the entire 
    ///         redemption transaction. This value is 0 for a timed-out
    ///         redemption request.
    function processNonChangeRedemptionTxOutput(
        bytes20 walletPubKeyHash,
        bytes memory outputScript,
        uint64 outputValue
    ) internal returns (uint64 burnableValue, uint64 treasuryFee) {
        // This function should be called only if the given output is
        // supposed to represent a redemption. Build the redemption key
        // to perform that check.
        uint256 redemptionKey = uint256(
            keccak256(abi.encodePacked(walletPubKeyHash, outputScript))
        );

        if (pendingRedemptions[redemptionKey].requestedAt != 0) {
            // If we entered here, that means the output was identified
            // as a pending redemption request.
            RedemptionRequest storage request = pendingRedemptions[
                redemptionKey
            ];
            // Compute the request's redeemable amount as the requested
            // amount reduced by the treasury fee. The request's
            // minimal amount is then the redeemable amount reduced by
            // the maximum transaction fee.
            uint64 redeemableAmount = request.requestedAmount -
                request.treasuryFee;
            // Output value must fit between the request's redeemable
            // and minimal amounts to be deemed valid.
            require(
                redeemableAmount - request.txMaxFee <= outputValue &&
                    outputValue <= redeemableAmount,
                "Output value is not within the acceptable range of the pending request"
            );
            // Add the redeemable amount to the total burnable value
            // the Bridge will use to decrease its balance in the Bank.
            burnableValue = redeemableAmount;
            // Add the request's treasury fee to the total treasury fee
            // value the Bridge will transfer to the treasury.
            treasuryFee = request.treasuryFee;
            // Request was properly handled so remove its redemption
            // key from the mapping to make it reusable for further
            // requests.
            delete pendingRedemptions[redemptionKey];
        } else {
            // If we entered here, the output is not a redemption
            // request but there is still a chance the given output is
            // related to a reported timed out redemption request.
            // If so, check if the output value matches the request
            // amount to confirm this is an overdue request fulfillment
            // then bypass this output and process the subsequent
            // ones. That also means the wallet was already punished
            // for the inactivity. Otherwise, just revert.
            RedemptionRequest storage request = timedOutRedemptions[
                redemptionKey
            ];

            require(
                request.requestedAt != 0,
                "Output is a non-requested redemption"
            );

            uint64 redeemableAmount = request.requestedAmount -
                request.treasuryFee;

            require(
                redeemableAmount - request.txMaxFee <= outputValue &&
                    outputValue <= redeemableAmount,
                "Output value is not within the acceptable range of the timed out request"
            );
        }
    }

    /// @notice Notifies that there is a pending redemption request associated
    ///         with the given wallet, that has timed out. The redemption
    ///         request is identified by the key built as
    ///         `keccak256(walletPubKeyHash | redeemerOutputScript)`.
    ///         The results of calling this function: the pending redemptions
    ///         value for the wallet will be decreased by the requested amount
    ///         (minus treasury fee), the tokens taken from the redeemer on
    ///         redemption request will be returned to the redeemer, the request
    ///         will be moved from pending redemptions to timed-out redemptions.
    ///         If the state of the wallet is `Live` or `MovingFunds`, the
    ///         wallet operators will be slashed.
    ///         Additionally, if the state of wallet is `Live`, the wallet will
    ///         be closed or marked as `MovingFunds` (depending on the presence
    ///         or absence of the wallet's main UTXO) and the wallet will no
    ///         longer be marked as the active wallet (if it was marked as such).
    /// @param walletPubKeyHash 20-byte public key hash of the wallet
    /// @param redeemerOutputScript  The redeemer's length-prefixed output
    ///        script (P2PKH, P2WPKH, P2SH or P2WSH)
    /// @dev Requirements:
    ///      - The redemption request identified by `walletPubKeyHash` and
    ///        `redeemerOutputScript` must exist
    ///      - The amount of time defined by `redemptionTimeout` must have
    ///        passed since the redemption was requested (the request must be
    ///        timed-out).
    function notifyRedemptionTimeout(
        bytes20 walletPubKeyHash,
        bytes calldata redeemerOutputScript
    ) external {
        uint256 redemptionKey = uint256(
            keccak256(abi.encodePacked(walletPubKeyHash, redeemerOutputScript))
        );
        RedemptionRequest memory request = pendingRedemptions[redemptionKey];

        require(request.requestedAt > 0, "Redemption request does not exist");
        require(
            /* solhint-disable-next-line not-rely-on-time */
            request.requestedAt + redemptionTimeout < block.timestamp,
            "Redemption request has not timed out"
        );

        // Update the wallet's pending redemptions value
        Wallets.Wallet storage wallet = wallets.registeredWallets[
            walletPubKeyHash
        ];
        wallet.pendingRedemptionsValue -=
            request.requestedAmount -
            request.treasuryFee;

        require(
            // TODO: Allow the wallets in `Closing` state when the state is added
            wallet.state == Wallets.WalletState.Live ||
                wallet.state == Wallets.WalletState.MovingFunds ||
                wallet.state == Wallets.WalletState.Terminated,
            "The wallet must be in Live, MovingFunds or Terminated state"
        );

        // It is worth noting that there is no need to check if
        // `timedOutRedemption` mapping already contains the given redemption
        // key. There is no possibility to re-use a key of a reported timed-out
        // redemption because the wallet responsible for causing the timeout is
        // moved to a state that prevents it to receive new redemption requests.

        // Move the redemption from pending redemptions to timed-out redemptions
        timedOutRedemptions[redemptionKey] = request;
        delete pendingRedemptions[redemptionKey];

        if (
            wallet.state == Wallets.WalletState.Live ||
            wallet.state == Wallets.WalletState.MovingFunds
        ) {
            // Propagate timeout consequences to the wallet
            wallets.notifyRedemptionTimedOut(walletPubKeyHash);
        }

        emit RedemptionTimedOut(walletPubKeyHash, redeemerOutputScript);

        // Return the requested amount of tokens to the redeemer
        self.bank.transferBalance(request.redeemer, request.requestedAmount);
    }

    /// @notice Used by the wallet to prove the BTC moving funds transaction
    ///         and to make the necessary state changes. Moving funds is only
    ///         accepted if it satisfies SPV proof.
    ///
    ///         The function validates the moving funds transaction structure
    ///         by checking if it actually spends the main UTXO of the declared
    ///         wallet and locks the value on the pre-committed target wallets
    ///         using a reasonable transaction fee. If all preconditions are
    ///         met, this functions closes the source wallet.
    ///
    ///         It is possible to prove the given moving funds transaction only
    ///         one time.
    /// @param movingFundsTx Bitcoin moving funds transaction data
    /// @param movingFundsProof Bitcoin moving funds proof data
    /// @param mainUtxo Data of the wallet's main UTXO, as currently known on
    ///        the Ethereum chain
    /// @param walletPubKeyHash 20-byte public key hash (computed using Bitcoin
    ///        HASH160 over the compressed ECDSA public key) of the wallet
    ///        which performed the moving funds transaction
    /// @dev Requirements:
    ///      - `movingFundsTx` components must match the expected structure. See
    ///        `BitcoinTx.Info` docs for reference. Their values must exactly
    ///        correspond to appropriate Bitcoin transaction fields to produce
    ///        a provable transaction hash.
    ///      - The `movingFundsTx` should represent a Bitcoin transaction with
    ///        exactly 1 input that refers to the wallet's main UTXO. That
    ///        transaction should have 1..n outputs corresponding to the
    ///        pre-committed target wallets. Outputs must be ordered in the
    ///        same way as their corresponding target wallets are ordered
    ///        within the target wallets commitment.
    ///      - `movingFundsProof` components must match the expected structure.
    ///        See `BitcoinTx.Proof` docs for reference. The `bitcoinHeaders`
    ///        field must contain a valid number of block headers, not less
    ///        than the `txProofDifficultyFactor` contract constant.
    ///      - `mainUtxo` components must point to the recent main UTXO
    ///        of the given wallet, as currently known on the Ethereum chain.
    ///        Additionally, the recent main UTXO on Ethereum must be set.
    ///      - `walletPubKeyHash` must be connected with the main UTXO used
    ///        as transaction single input.
    ///      - The wallet that `walletPubKeyHash` points to must be in the
    ///        MovingFunds state.
    ///      - The target wallets commitment must be submitted by the wallet
    ///        that `walletPubKeyHash` points to.
    ///      - The total Bitcoin transaction fee must be lesser or equal
    ///        to `movingFundsTxMaxTotalFee` governable parameter.
    function submitMovingFundsProof(
        BitcoinTx.Info calldata movingFundsTx,
        BitcoinTx.Proof calldata movingFundsProof,
        BitcoinTx.UTXO calldata mainUtxo,
        bytes20 walletPubKeyHash
    ) external {
        // The actual transaction proof is performed here. After that point, we
        // can assume the transaction happened on Bitcoin chain and has
        // a sufficient number of confirmations as determined by
        // `txProofDifficultyFactor` constant.
        bytes32 movingFundsTxHash = BitcoinTx.validateProof(
            movingFundsTx,
            movingFundsProof,
            self.proofDifficultyContext()
        );

        // Process the moving funds transaction input. Specifically, check if
        // it refers to the expected wallet's main UTXO.
        processWalletOutboundTxInput(
            movingFundsTx.inputVector,
            mainUtxo,
            walletPubKeyHash
        );

        (
            bytes32 targetWalletsHash,
            uint256 outputsTotalValue
        ) = processMovingFundsTxOutputs(movingFundsTx.outputVector);

        require(
            mainUtxo.txOutputValue - outputsTotalValue <=
                movingFundsTxMaxTotalFee,
            "Transaction fee is too high"
        );

        wallets.notifyFundsMoved(walletPubKeyHash, targetWalletsHash);

        emit MovingFundsCompleted(walletPubKeyHash, movingFundsTxHash);
    }

    /// @notice Processes the moving funds Bitcoin transaction output vector
    ///         and extracts information required for further processing.
    /// @param movingFundsTxOutputVector Bitcoin moving funds transaction output
    ///        vector. This function assumes vector's structure is valid so it
    ///        must be validated using e.g. `BTCUtils.validateVout` function
    ///        before it is passed here
    /// @return targetWalletsHash keccak256 hash over the list of actual
    ///         target wallets used in the transaction.
    /// @return outputsTotalValue Sum of all outputs values.
    /// @dev Requirements:
    ///      - The `movingFundsTxOutputVector` must be parseable, i.e. must
    ///        be validated by the caller as stated in their parameter doc.
    ///      - Each output must refer to a 20-byte public key hash.
    ///      - The total outputs value must be evenly divided over all outputs.
    function processMovingFundsTxOutputs(bytes memory movingFundsTxOutputVector)
        internal
        view
        returns (bytes32 targetWalletsHash, uint256 outputsTotalValue)
    {
        // Determining the total number of Bitcoin transaction outputs in
        // the same way as for number of inputs. See `BitcoinTx.outputVector`
        // docs for more details.
        (
            uint256 outputsCompactSizeUintLength,
            uint256 outputsCount
        ) = movingFundsTxOutputVector.parseVarInt();

        // To determine the first output starting index, we must jump over
        // the compactSize uint which prepends the output vector. One byte
        // must be added because `BtcUtils.parseVarInt` does not include
        // compactSize uint tag in the returned length.
        //
        // For >= 0 && <= 252, `BTCUtils.determineVarIntDataLengthAt`
        // returns `0`, so we jump over one byte of compactSize uint.
        //
        // For >= 253 && <= 0xffff there is `0xfd` tag,
        // `BTCUtils.determineVarIntDataLengthAt` returns `2` (no
        // tag byte included) so we need to jump over 1+2 bytes of
        // compactSize uint.
        //
        // Please refer `BTCUtils` library and compactSize uint
        // docs in `BitcoinTx` library for more details.
        uint256 outputStartingIndex = 1 + outputsCompactSizeUintLength;

        bytes20[] memory targetWallets = new bytes20[](outputsCount);
        uint64[] memory outputsValues = new uint64[](outputsCount);

        // Outputs processing loop.
        for (uint256 i = 0; i < outputsCount; i++) {
            uint256 outputLength = movingFundsTxOutputVector
                .determineOutputLengthAt(outputStartingIndex);

            bytes memory output = movingFundsTxOutputVector.slice(
                outputStartingIndex,
                outputLength
            );

            // Extract the output script payload.
            bytes memory targetWalletPubKeyHashBytes = output.extractHash();
            // Output script payload must refer to a known wallet public key
            // hash which is always 20-byte.
            require(
                targetWalletPubKeyHashBytes.length == 20,
                "Target wallet public key hash must have 20 bytes"
            );

            bytes20 targetWalletPubKeyHash = targetWalletPubKeyHashBytes
                .slice20(0);

            // The next step is making sure that the 20-byte public key hash
            // is actually used in the right context of a P2PKH or P2WPKH
            // output. To do so, we must extract the full script from the output
            // and compare with the expected P2PKH and P2WPKH scripts
            // referring to that 20-byte public key hash. The output consists
            // of an 8-byte value and a variable length script. To extract the
            // script we slice the output starting from 9th byte until the end.
            bytes32 outputScriptKeccak = keccak256(
                output.slice(8, output.length - 8)
            );
            // Build the expected P2PKH script which has the following byte
            // format: <0x1976a914> <20-byte PKH> <0x88ac>. According to
            // https://en.bitcoin.it/wiki/Script#Opcodes this translates to:
            // - 0x19: Byte length of the entire script
            // - 0x76: OP_DUP
            // - 0xa9: OP_HASH160
            // - 0x14: Byte length of the public key hash
            // - 0x88: OP_EQUALVERIFY
            // - 0xac: OP_CHECKSIG
            // which matches the P2PKH structure as per:
            // https://en.bitcoin.it/wiki/Transaction#Pay-to-PubkeyHash
            bytes32 targetWalletP2PKHScriptKeccak = keccak256(
                abi.encodePacked(
                    hex"1976a914",
                    targetWalletPubKeyHash,
                    hex"88ac"
                )
            );
            // Build the expected P2WPKH script which has the following format:
            // <0x160014> <20-byte PKH>. According to
            // https://en.bitcoin.it/wiki/Script#Opcodes this translates to:
            // - 0x16: Byte length of the entire script
            // - 0x00: OP_0
            // - 0x14: Byte length of the public key hash
            // which matches the P2WPKH structure as per:
            // https://github.com/bitcoin/bips/blob/master/bip-0141.mediawiki#P2WPKH
            bytes32 targetWalletP2WPKHScriptKeccak = keccak256(
                abi.encodePacked(hex"160014", targetWalletPubKeyHash)
            );
            // Make sure the actual output script matches either the P2PKH
            // or P2WPKH format.
            require(
                outputScriptKeccak == targetWalletP2PKHScriptKeccak ||
                    outputScriptKeccak == targetWalletP2WPKHScriptKeccak,
                "Output must be P2PKH or P2WPKH"
            );

            // Add the wallet public key hash to the list that will be used
            // to build the result list hash. There is no need to check if
            // given output is a change here because the actual target wallet
            // list must be exactly the same as the pre-committed target wallet
            // list which is guaranteed to be valid.
            targetWallets[i] = targetWalletPubKeyHash;

            // Extract the value from given output.
            outputsValues[i] = output.extractValue();
            outputsTotalValue += outputsValues[i];

            // Make the `outputStartingIndex` pointing to the next output by
            // increasing it by current output's length.
            outputStartingIndex += outputLength;
        }

        // Compute the indivisible remainder that remains after dividing the
        // outputs total value over all outputs evenly.
        uint256 outputsTotalValueRemainder = outputsTotalValue % outputsCount;
        // Compute the minimum allowed output value by dividing the outputs
        // total value (reduced by the remainder) by the number of outputs.
        uint256 minOutputValue = (outputsTotalValue -
            outputsTotalValueRemainder) / outputsCount;
        // Maximum possible value is the minimum value with the remainder included.
        uint256 maxOutputValue = minOutputValue + outputsTotalValueRemainder;

        for (uint256 i = 0; i < outputsCount; i++) {
            require(
                minOutputValue <= outputsValues[i] &&
                    outputsValues[i] <= maxOutputValue,
                "Transaction amount is not distributed evenly"
            );
        }

        targetWalletsHash = keccak256(abi.encodePacked(targetWallets));

        return (targetWalletsHash, outputsTotalValue);
    }

    /// @return bank Address of the Bank the Bridge belongs to.
    /// @return relay Address of the Bitcoin relay providing the current Bitcoin
    ///         network difficulty.
    function getContracts() external view returns (Bank bank, IRelay relay) {
        bank = self.bank;
        relay = self.relay;
    }

    /// @notice Returns the current values of Bridge deposit parameters.
    /// @return depositDustThreshold The minimal amount that can be requested
    ///         to deposit. Value of this parameter must take into account the
    ///         value of `depositTreasuryFeeDivisor` and `depositTxMaxFee`
    ///         parameters in order to make requests that can incur the
    ///         treasury and transaction fee and still satisfy the depositor.
    /// @return depositTreasuryFeeDivisor Divisor used to compute the treasury
    ///         fee taken from each deposit and transferred to the treasury upon
    ///         sweep proof submission. That fee is computed as follows:
    ///         `treasuryFee = depositedAmount / depositTreasuryFeeDivisor`
    ///         For example, if the treasury fee needs to be 2% of each deposit,
    ///         the `depositTreasuryFeeDivisor` should be set to `50`
    ///         because `1/50 = 0.02 = 2%`.
    /// @return depositTxMaxFee Maximum amount of BTC transaction fee that can
    ///         be incurred by each swept deposit being part of the given sweep
    ///         transaction. If the maximum BTC transaction fee is exceeded,
    ///         such transaction is considered a fraud.
    /// @return treasury Address where the deposit treasury fees will be
    ///         sent to. Treasury takes part in the operators rewarding process.
    /// @return txProofDifficultyFactor The number of confirmations on the
    ///         Bitcoin chain required to successfully evaluate an SPV proof.
    function depositParameters()
        external
        view
        returns (
            uint64 depositDustThreshold,
            uint64 depositTreasuryFeeDivisor,
            uint64 depositTxMaxFee,
            address treasury,
            uint256 txProofDifficultyFactor
        )
    {
        depositDustThreshold = self.depositDustThreshold;
        depositTreasuryFeeDivisor = self.depositTreasuryFeeDivisor;
        depositTxMaxFee = self.depositTxMaxFee;
        treasury = self.treasury;
        txProofDifficultyFactor = self.txProofDifficultyFactor;
    }

    /// @notice Indicates if the vault with the given address is trusted or not.
    ///         Depositors can route their revealed deposits only to trusted
    ///         vaults and have trusted vaults notified about new deposits as
    ///         soon as these deposits get swept. Vaults not trusted by the
    ///         Bridge can still be used by Bank balance owners on their own
    ///         responsibility - anyone can approve their Bank balance to any
    ///         address.
    function isVaultTrusted(address vault) external view returns (bool) {
        return self.isVaultTrusted[vault];
    }

    /// @notice Collection of all revealed deposits indexed by
    ///         keccak256(fundingTxHash | fundingOutputIndex).
    ///         The fundingTxHash is bytes32 (ordered as in Bitcoin internally)
    ///         and fundingOutputIndex an uint32. This mapping may contain valid
    ///         and invalid deposits and the wallet is responsible for
    ///         validating them before attempting to execute a sweep.
    function deposits(uint256 depositKey)
        external
        view
        returns (Deposit.Request memory)
    {
        // TODO: rename to getDeposit?
        return self.deposits[depositKey];
    }

    /// @notice Collection of main UTXOs that are honestly spent indexed by
    ///         keccak256(fundingTxHash | fundingOutputIndex). The fundingTxHash
    ///         is bytes32 (ordered as in Bitcoin internally) and
    ///         fundingOutputIndex an uint32. A main UTXO is considered honestly
    ///         spent if it was used as an input of a transaction that have been
    ///         proven in the Bridge.
    function spentMainUTXOs(uint256 utxoKey) external view returns (bool) {
        return self.spentMainUTXOs[utxoKey];
    }
}

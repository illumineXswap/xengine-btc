# Private Bitcoin Wallet integration into illumineX V2
xEngine is implementing a lightweight Bitcoin node and 2/2 multisig wallet inside Oasis Sapphire smart contract.

Every deposit (Bitcoin input for outgoing withdrawal transaction) is a P2SH vault which must be signed by the smart contract (private key is unique for every deposit and stored in the confidential state) and the off-chain signer. This dual system is required to avoid SGX-related risks but at the same time not allow the off-chain signer to have enough control over the vaults.

There are two main contracts - **BitcoinProver** and **VaultBitcoinWallet**.

BitcoinProver confirms Bitcoin blocks and transactions inclusions, and passing confirmed tx output details to the VaultBitcoinWallet after.

VaultBitcoinWallet checks if this output is looking like an acceptable deposit, and if so stores a secret inside its confidential storage, as well as off chain signer’s public key, and minting BTC tokens to a user.

Special hook will convert newly minted BTC tokens into private BTC tokens.

When user wants to withdraw they submit request to the wallet contract then it puts the request into the queue (first in first out), and batching outgoing transfers requests into a single BTC transaction which is serialising and signing in multiple phases using TxSerializer (done this way to not get a block gas limit bottle neck).

TxSerializer is deployed from a factory and is responsible for multi-phase outgoing tx building including:
- sighash formation
- signing
- validating off chain signature
- serialising into raw data which is double hashed and emits via the event which is a cheap operation in terms of gas costs

Without TxSerializer the potential bottleneck is amount of inputs in the outgoing transaction which can be theoretically uncontrollable (one large withdrawal with many small-value inputs), and each input sighashig, signing, etc. are quite gas costly actions.

**General components diagram:**

<img src="./docs/out/components/Component%20diagram.png" />

**Anchor block sync flow diagram:**

<img src="./docs/out/anchor_block_tracking/Anchor%20block%20tracking.png" />

**User deposit diagram:**

<img src="./docs/out/deposit_flow/Deposit%20flow.png" />

**User withdrawal diagram:**

<img src="./docs/out/withdraw_flow/Withdraw%20flow.png" />

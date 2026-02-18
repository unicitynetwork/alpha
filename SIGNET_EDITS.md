# Alpha Signet Fork: Comprehensive Code Modification Report

## Table of Contents

1. [Overview](#overview)
2. [Architecture of the Three Simultaneous Consensus Changes](#architecture-of-the-three-simultaneous-consensus-changes)
3. [File-by-File Modification Guide](#file-by-file-modification-guide)
   - [src/consensus/params.h](#srcconsensusparamsh)
   - [src/kernel/chainparams.cpp](#srckernelchainparamscpp)
   - [src/signet.h](#srcsigneth)
   - [src/signet.cpp](#srcsignetcpp)
   - [src/node/miner.h](#srcnodeminerh)
   - [src/node/miner.cpp](#srcnodeminer-cpp)
   - [src/pow.cpp](#srcpowcpp)
   - [src/validation.cpp](#srcvalidationcpp)
   - [src/rpc/mining.cpp](#srcrpcminingcpp)
   - [src/init.cpp](#srcinitcpp)
4. [Execution Flow](#execution-flow)
5. [Configuration Guide](#configuration-guide)
6. [Deployment Notes](#deployment-notes)
7. [Testing Strategy](#testing-strategy)
8. [Appendix: Script Encoding Reference](#appendix-script-encoding-reference)

---

## Overview

At block height 450,000, the Alpha mainnet undergoes a programmatic hard fork that transitions the chain from open RandomX proof-of-work mining to a federation-based block production model. This is one of Alpha's scheduled "programmatic hard forks" (the pattern established in the CLAUDE.md as occurring every 50,000 blocks from 400,000 onward).

The fork implements three simultaneous consensus rule changes that activate atomically at block 450,000:

1. **Zero block subsidy** -- The block reward drops from 5 ALPHA (post-halving from the 400,000-block halving) to 0. Block producers are compensated only by transaction fees. This eliminates the economic incentive for unauthorized miners to extend the chain.

2. **Difficulty reset** -- The difficulty for block 450,000 is forced to `powLimit` (minimum difficulty), preventing a chain stall. After block 450,000, the existing ASERT anchor from block 70,232 continues to govern difficulty adjustment. Since the chain has maintained ~2-minute blocks, ASERT naturally computes a difficulty near `powLimit` for post-fork blocks.

3. **Signet-style block authorization** -- Every block at height >= 450,000 must carry a valid signature from one of five authorized keys, embedded in the coinbase witness commitment using the BIP325 signet mechanism. Blocks lacking a valid signature are rejected by all consensus rules.

In addition to the three consensus changes, four supporting infrastructure changes enable authorized nodes to produce valid blocks:

4. **Startup key validation** -- On nodes running in template-serving mode (`-server`), the new `-signetblockkey` parameter is parsed, decoded from WIF, and validated against the authorized public keys in the challenge script. The node logs a warning if the fork is active and no valid key is configured, but continues to run normally as a non-mining full node.

5. **Template signing** -- `CreateNewBlock()` automatically appends the SIGNET_HEADER and serialized signature to the coinbase witness commitment output of every block template it produces for heights >= 450,000. The Merkle root is recomputed after this modification.

6. **New config parameter** -- `-signetblockkey=<WIF>` is registered as a `SENSITIVE` argument in the `BLOCK_CREATION` category.

7. **RPC advertising** -- The `getblocktemplate` RPC response includes `alpha_signet_challenge` and `alpha_signet_active` fields when the fork is active, so external mining infrastructure can detect the transition.

The approach deliberately reuses Bitcoin Core's existing `signet.cpp` / `SignetTxs` infrastructure rather than reimplementing the signing and verification logic from scratch. The only new code is the height-gated wrapper that activates the signet check at a specific block height on the Alpha mainnet, instead of being chain-wide as in Bitcoin's signet.

---

## Architecture of the Three Simultaneous Consensus Changes

```
Block 449,999 (last PoW block)
     |
     v
Block 450,000 (first fork block)
     |
     +--- Subsidy check: GetBlockSubsidy(450000) returns 0
     |     Coinbase value must be <= nFees only
     |
     +--- Difficulty: GetNextWorkRequired() returns nProofOfWorkLimit
     |     (minimum difficulty, so the block is trivially solvable)
     |     Future blocks: existing ASERT anchor naturally returns ~powLimit
     |
     +--- Authorization: CheckSignetBlockSolution(block, params, 450000)
           Must find SIGNET_HEADER in coinbase witness commitment
           Signature must satisfy 1-of-5 multisig challenge script
```

The three changes interact in a specific order within the validation pipeline. Difficulty is checked at the header level during `CheckProofOfWork`. The subsidy check and signet authorization check both occur during full block connection in `ConnectBlock`. The subsidy check happens after the signet check, so an unauthorized block fails authorization before the coinbase amount is ever evaluated.

---

## File-by-File Modification Guide

### src/consensus/params.h

**Role:** Defines the `Consensus::Params` struct that holds all consensus-critical parameters for a chain. This is the data structure passed throughout the codebase to make consensus decisions. Adding fields here is the first step in introducing any new consensus rule.

**Full path:** `/home/vrogojin/alpha/src/consensus/params.h`

```diff
@@ -180,6 +180,12 @@ struct Params {
     uint32_t RandomX_DiffMult;
     // !ALPHA END
 
+    // !ALPHA SIGNET FORK
+    int nSignetActivationHeight{0};              // Height at which signet authorization activates (0 = never)
+    std::vector<uint8_t> signet_challenge_alpha;  // Challenge script for height-gated signet (separate from signet_challenge)
+    // !ALPHA SIGNET FORK END
+
     // !SCASH END
 };
```

**Line-by-line explanation:**

- `int nSignetActivationHeight{0}` -- The block height at which the three consensus changes activate. The in-class initializer `{0}` means that if a chain (such as the original Bitcoin mainnet or signet) does not configure this field, the fork is permanently disabled. The value `0` is treated as "never" by every guard throughout the codebase (all guards test `> 0` before taking any action). On the Alpha mainnet this is set to `450000`; on testnet and regtest it is set to `200` for testing purposes.

- `std::vector<uint8_t> signet_challenge_alpha` -- The serialized Script that authorized block producers must satisfy. The name deliberately differs from the existing `signet_challenge` field (which belongs to the `signet_blocks` BIP325 chain-wide signet mechanism) to avoid any risk of confusion or accidental cross-activation. The type matches `signet_challenge` exactly so the same `CScript` construction idiom works: `CScript(signet_challenge_alpha.begin(), signet_challenge_alpha.end())`.

**Cross-references:** Every other modified file reads these two fields. The initializers here ensure backward compatibility: code compiled without any chain configuration will have `nSignetActivationHeight == 0` and all guards will silently pass.

**Security implications:** Placing `nSignetActivationHeight{0}` in the struct definition rather than relying on absence of a configuration is a defensive choice. It guarantees that a new chain type inadvertently omitting this field cannot accidentally activate the fork, because the value defaults to "never active."

---

### src/kernel/chainparams.cpp

**Role:** Instantiates the `Consensus::Params` struct for each chain type (mainnet `CMainParams`, testnet `CTestNetParams`, regtest `CRegTestParams`). This is where the concrete values determined by the fork design are hardcoded.

**Full path:** `/home/vrogojin/alpha/src/kernel/chainparams.cpp`

#### Mainnet (CMainParams) changes

```diff
+        // !ALPHA SIGNET FORK
+        consensus.nSignetActivationHeight = 450000;
+
+        // 1-of-5 bare multisig challenge: OP_1 <pk1> <pk2> <pk3> <pk4> <pk5> OP_5 OP_CHECKMULTISIG
+        // Replace placeholder pubkeys with actual 33-byte compressed pubkeys before deployment
+        consensus.signet_challenge_alpha = ParseHex(
+            "51"                                                              // OP_1
+            "21" "PLACEHOLDER_PUBKEY_1_33_BYTES_HEX_66_CHARS_HERE_0000000001"  // push 33 bytes + pubkey 1
+            "21" "PLACEHOLDER_PUBKEY_2_33_BYTES_HEX_66_CHARS_HERE_0000000002"  // push 33 bytes + pubkey 2
+            "21" "PLACEHOLDER_PUBKEY_3_33_BYTES_HEX_66_CHARS_HERE_0000000003"  // push 33 bytes + pubkey 3
+            "21" "PLACEHOLDER_PUBKEY_4_33_BYTES_HEX_66_CHARS_HERE_0000000004"  // push 33 bytes + pubkey 4
+            "21" "PLACEHOLDER_PUBKEY_5_33_BYTES_HEX_66_CHARS_HERE_0000000005"  // push 33 bytes + pubkey 5
+            "55"                                                              // OP_5
+            "ae"                                                              // OP_CHECKMULTISIG
+        );
+        // !ALPHA SIGNET FORK END
```

**Line-by-line explanation:**

- `consensus.nSignetActivationHeight = 450000` -- Sets the fork activation height. This is the first block that must comply with all three new consensus rules.

- `consensus.signet_challenge_alpha = ParseHex(...)` -- The challenge script is a 1-of-5 bare multisig in standard Script. The byte encoding is:
  - `0x51` = `OP_1` (minimum signature count required)
  - `0x21` = push 33 bytes (compressed public key length)
  - 66 hex characters = 33 bytes of compressed public key (one for each of the 5 authorized signers)
  - `0x55` = `OP_5` (total number of keys)
  - `0xae` = `OP_CHECKMULTISIG`

  The current placeholder strings (e.g., `PLACEHOLDER_PUBKEY_1_33_BYTES_HEX_66_CHARS_HERE_0000000001`) are not valid compressed public keys. They must be replaced with actual 33-byte compressed secp256k1 public keys before the binary is deployed. See the [Deployment Notes](#deployment-notes) section.

  The choice of bare multisig (rather than P2SH or P2WSH wrapping) is consistent with the Bitcoin signet design, where the challenge is placed directly as the scriptPubKey of the `m_to_spend` output in the synthetic signing transaction pair. Bare multisig scripts can be verified by `VerifyScript` without any additional wrapping.

#### Testnet / Regtest (CAlphaTestNetParams / CAlphaRegTestParams) changes

The testnet and regtest constructors now accept `AlphaSignetForkOptions` alongside the existing `RegTestOptions`. The signet fork is **disabled by default** (height=0, empty challenge) unless the operator provides CLI args:

```
-signetforkheight=<n> -signetforkpubkeys=<hex1>,<hex2>,...
```

When provided, `BuildSignetChallenge()` constructs a 1-of-N bare multisig from the supplied compressed pubkeys. This replaces the previous hardcoded `OP_TRUE` challenge, which allowed any block to pass post-fork validation -- making it impossible to test the actual signing/verification flow.

The `BuildSignetChallenge` helper (file-scope static in `kernel/chainparams.cpp`) uses `GetScriptForMultisig(1, pubkeys)` to produce the same script format as mainnet.

After initialization, the exact same `CheckSignetBlockSolution` code path runs for all chain types.

**Cross-references:**
- The `nSignetActivationHeight` value is read by `validation.cpp`, `pow.cpp`, `signet.cpp`, `node/miner.cpp`, `rpc/mining.cpp`, and `init.cpp`.
- The `signet_challenge_alpha` bytes are read by `signet.cpp` (validation), `node/miner.cpp` (signing), and `init.cpp` (key validation at startup).

---

### src/signet.h

**Role:** Public header declaring the `CheckSignetBlockSolution` function and the `SignetTxs` class. The `SignetTxs` class encapsulates the BIP325 synthetic transaction pair used both for signing (in `miner.cpp`) and for verification (in `signet.cpp` and `validation.cpp`).

**Full path:** `/home/vrogojin/alpha/src/signet.h`

```diff
@@ -16,6 +16,14 @@
  */
 bool CheckSignetBlockSolution(const CBlock& block, const Consensus::Params& consensusParams);
 
+// !ALPHA SIGNET FORK
+/**
+ * Height-gated variant: check signet block solution only if height >= activation height.
+ * Uses signet_challenge_alpha (not signet_challenge) from consensus params.
+ */
+bool CheckSignetBlockSolution(const CBlock& block, const Consensus::Params& consensusParams, int nHeight);
+// !ALPHA SIGNET FORK END
+
 /**
  * Generate the signet tx corresponding to the given block
```

**Line-by-line explanation:**

A second overload of `CheckSignetBlockSolution` is declared, adding an `int nHeight` parameter. This overload is what every Alpha-specific call site uses. The original two-parameter version is left untouched to preserve compatibility with Bitcoin's signet chain type (the original version is called in `validation.cpp` for `signet_blocks` chains).

The two-parameter distinction is critical: calling the wrong overload would either always enforce signet (if the original is called with the Alpha challenge) or never enforce it height-gating (if the new one is called without passing the block height). By making the height a required parameter of the new overload, call sites cannot accidentally omit it.

**Cross-references:**
- Implemented in `src/signet.cpp` (the new body added at the bottom of the file).
- Called in `src/validation.cpp` at two distinct call sites (in `ContextualCheckBlock` and in `ConnectBlock`).

---

### src/signet.cpp

**Role:** Implements the BIP325 signet transaction pair construction (`SignetTxs::Create`) and the block solution checker. The new overload added here is the enforcement function that every validation path for Alpha blocks calls.

**Full path:** `/home/vrogojin/alpha/src/signet.cpp`

```diff
+// !ALPHA SIGNET FORK
+bool CheckSignetBlockSolution(const CBlock& block, const Consensus::Params& consensusParams, int nHeight)
+{
+    // Only enforce after activation height
+    if (consensusParams.nSignetActivationHeight <= 0 || nHeight < consensusParams.nSignetActivationHeight) {
+        return true;  // Pre-fork: no authorization required
+    }
+
+    // Use the Alpha-specific challenge script
+    const CScript challenge(consensusParams.signet_challenge_alpha.begin(), consensusParams.signet_challenge_alpha.end());
+    const std::optional<SignetTxs> signet_txs = SignetTxs::Create(block, challenge);
+
+    if (!signet_txs) {
+        LogPrint(BCLog::VALIDATION, "CheckSignetBlockSolution (Alpha fork): block solution parse failure at height %d\n", nHeight);
+        return false;
+    }
+
+    const CScript& scriptSig = signet_txs->m_to_sign.vin[0].scriptSig;
+    const CScriptWitness& witness = signet_txs->m_to_sign.vin[0].scriptWitness;
+
+    PrecomputedTransactionData txdata;
+    txdata.Init(signet_txs->m_to_sign, {signet_txs->m_to_spend.vout[0]});
+    TransactionSignatureChecker sigcheck(&signet_txs->m_to_sign, /*nInIn=*/ 0, /*amountIn=*/ signet_txs->m_to_spend.vout[0].nValue, txdata, MissingDataBehavior::ASSERT_FAIL);
+
+    if (!VerifyScript(scriptSig, signet_txs->m_to_spend.vout[0].scriptPubKey, &witness, BLOCK_SCRIPT_VERIFY_FLAGS, sigcheck)) {
+        LogPrint(BCLog::VALIDATION, "CheckSignetBlockSolution (Alpha fork): invalid block solution at height %d\n", nHeight);
+        return false;
+    }
+    return true;
+}
+// !ALPHA SIGNET FORK END
```

**Line-by-line explanation:**

- **Height guard** (`nSignetActivationHeight <= 0 || nHeight < nSignetActivationHeight`) -- Returns `true` immediately for any block before the fork height. This is the single gate that makes the entire mechanism height-conditional. On chains where `nSignetActivationHeight` is zero (all non-Alpha chains), this always short-circuits.

- **Empty challenge guard** -- If `signet_challenge_alpha` is empty (fork disabled or not configured), returns `false` with a log message. This prevents silent pass-through.

- **Explicit SIGNET_HEADER check** -- Before calling `SignetTxs::Create`, the function now independently verifies that the coinbase witness commitment contains the `SIGNET_HEADER` magic bytes (`{0xec, 0xc7, 0xda, 0xa2}`). This closes the fragile implicit rejection path: previously, blocks missing the header relied on `VerifyScript` failing against a real multisig challenge (empty scriptSig fails multisig). The explicit check uses `FetchAndClearCommitmentSection` on a copy of the commitment script and rejects immediately if the header is absent, with a "missing SIGNET_HEADER" log message.

- **`ExtractPubkeysFromChallenge`** -- New shared helper function (declared in `signet.h`, implemented in `signet.cpp`) that extracts all valid 33-byte compressed pubkeys from a challenge script by iterating its opcodes. Used by both `init.cpp` (startup key validation, startup logging) to avoid code duplication.

- **`SignetTxs::Create(block, challenge)`** -- Calls the existing BIP325 transaction pair factory. This function:
  1. Creates a synthetic "to_spend" transaction with a single output whose `scriptPubKey` is the challenge script.
  2. Finds the witness commitment in the coinbase output.
  3. Searches the witness commitment for the `SIGNET_HEADER` (`{0xec, 0xc7, 0xda, 0xa2}`).
  4. Extracts and removes the signet solution bytes from the commitment.
  5. Deserializes those bytes as a `scriptSig` and witness stack into the "to_sign" spending transaction.
  6. Computes a modified Merkle root using the coinbase without the signet solution, and commits that root into the "to_spend" output's scriptSig.
  
  If any step fails (no witness commitment, extraneous data after the solution, deserialization error), `SignetTxs::Create` returns `std::nullopt` and the function returns `false`. Note: `SignetTxs::Create` itself does not require `SIGNET_HEADER` to be present — but this is now irrelevant because the explicit `SIGNET_HEADER` check added before the `SignetTxs::Create` call rejects any block missing the header before it reaches this point. All post-fork blocks on all chain types must contain the `SIGNET_HEADER` in the coinbase witness commitment.

- **`VerifyScript` call** -- Runs the Script interpreter against the extracted `scriptSig` and witness using `BLOCK_SCRIPT_VERIFY_FLAGS`. These flags (defined at the top of `signet.cpp` as `SCRIPT_VERIFY_P2SH | SCRIPT_VERIFY_WITNESS | SCRIPT_VERIFY_DERSIG | SCRIPT_VERIFY_NULLDUMMY`) are the same flags used by the original `CheckSignetBlockSolution`. For the 1-of-5 bare multisig, the interpreter evaluates the `scriptSig` (which contains the signature) against the `scriptPubKey` (which is the challenge). The `SCRIPT_VERIFY_NULLDUMMY` flag enforces the BIP147 rule that the mandatory dummy element in `OP_CHECKMULTISIG` must be an empty byte vector.

- **Logging** -- Uses `LogPrint(BCLog::VALIDATION, ...)` which only emits output when the `validation` debug category is enabled (`-debug=validation`). This matches the logging pattern in the original `CheckSignetBlockSolution` and avoids noisy output on nodes that are not actively debugging validation.

**Security implications:**

The new function is structurally identical to the original `CheckSignetBlockSolution`, differing only in:
1. The height gate at the top.
2. Reading `signet_challenge_alpha` instead of `signet_challenge`.
3. Including `nHeight` in log messages for better diagnostics.

By reusing `SignetTxs::Create` and `VerifyScript` without modification, the implementation inherits all the security properties of the original signet implementation, including protection against malleability (the modified Merkle root commits to the block contents without the signature, so signing happens over a canonical form of the block).

**Cross-references:**
- `SignetTxs::Create` is also called in `src/node/miner.cpp` during block template creation.
- The `SIGNET_HEADER` constant (`{0xec, 0xc7, 0xda, 0xa2}`) is defined at the top of `signet.cpp` (line 26) and reused as a local definition in `miner.cpp`.

---

### src/node/miner.h

**Role:** Public header for the block assembler. Declares the `BlockAssembler` class and supporting types. The change adds a global variable declaration for the signing key.

**Full path:** `/home/vrogojin/alpha/src/node/miner.h`

```diff
+#include <key.h>
 #include <policy/policy.h>
 
+// !ALPHA SIGNET FORK
+/** Global signing key for post-fork authorized block production.
+ *  Set during AppInitMain from -signetblockkey config parameter.
+ *  Only valid when the node is in template-serving mode.
+ */
+extern CKey g_alpha_signet_key;
+// !ALPHA SIGNET FORK END
```

**Line-by-line explanation:**

- `#include <key.h>` -- `CKey` is defined in `<key.h>`. This include was not previously in `miner.h`.

- `extern CKey g_alpha_signet_key` -- Declares a global `CKey` object defined in `miner.cpp`. The `extern` declaration makes it accessible to `init.cpp` (which sets it during startup) and to `miner.cpp` itself (which uses it during block assembly). The global is declared in `miner.h` rather than a dedicated header because the miner is the primary consumer of the key, and `init.cpp` already includes `miner.h` (indirectly via the mining RPC headers).

**Design considerations:**

The use of a global variable for the signing key is a pragmatic choice that mirrors how other global node state is managed in Bitcoin Core (for example, `g_isAlpha` follows the same pattern). A more architecturally pure approach would inject the key through `BlockAssembler::Options`, but that would require touching the `Options` struct, `ApplyArgsManOptions`, and all call sites of `CreateNewBlock`. The global is safe here because:
- It is set exactly once, during `AppInitMain`, before any block assembly thread runs.
- It is only read (never written) during block assembly.
- `CKey` is not modified after initialization, so there are no data races.

**Security implications:** The `CKey` object holds the raw 32-byte private key scalar. It resides in process memory for the lifetime of the node. Callers of `CreateNewBlock` cannot retrieve the key from the signing provider once it is placed in the `FlatSigningProvider` (the `FlatSigningProvider` is a local stack variable). The key is never serialized or logged (only the public key hex is logged, and only the first 16 characters of that).

---

### src/node/miner.cpp

**Role:** Implements `BlockAssembler::CreateNewBlock`, the function that constructs complete block templates ready for proof-of-work. The change adds the signing step that occurs after the block template is otherwise complete.

**Full path:** `/home/vrogojin/alpha/src/node/miner.cpp`

```diff
+#include <script/sign.h>
+#include <script/signingprovider.h>
+#include <signet.h>
+#include <streams.h>
```

Four new includes are required:
- `<script/sign.h>` -- Provides `ProduceSignature`, `MutableTransactionSignatureCreator`, `SignatureData`, and `UpdateInput`.
- `<script/signingprovider.h>` -- Provides `FlatSigningProvider`, the in-memory key store used during signing.
- `<signet.h>` -- Provides `SignetTxs::Create` and `GetWitnessCommitmentIndex`.
- `<streams.h>` -- Provides `VectorWriter`, used to serialize the signet solution into a byte vector.

```diff
+// !ALPHA SIGNET FORK
+CKey g_alpha_signet_key;
+// !ALPHA SIGNET FORK END
```

The global variable definition (corresponding to the `extern` declaration in `miner.h`). `CKey` has a default constructor that leaves the key in an invalid state (`IsValid()` returns `false`), so this initial state correctly represents "no key configured."

```diff
+    // !ALPHA SIGNET FORK - Sign block template for post-fork authorization
+    if (g_isAlpha && chainparams.GetConsensus().nSignetActivationHeight > 0
+        && nHeight >= chainparams.GetConsensus().nSignetActivationHeight) {
+
+        if (!g_alpha_signet_key.IsValid()) {
+            throw std::runtime_error("No signing key configured. Set -signetblockkey in alpha.conf to produce blocks.");
+        }
+
+        const Consensus::Params& cparams = chainparams.GetConsensus();
+        const CScript challenge(cparams.signet_challenge_alpha.begin(),
+                               cparams.signet_challenge_alpha.end());
+
+        // Create the signet signing transaction pair
+        const std::optional<SignetTxs> signet_txs = SignetTxs::Create(*pblock, challenge);
+        if (!signet_txs) {
+            throw std::runtime_error(...);
+        }
+
+        // Sign the spending transaction using the configured key
+        CMutableTransaction tx_signing(signet_txs->m_to_sign);
+
+        FlatSigningProvider keystore;
+        CKeyID keyid = g_alpha_signet_key.GetPubKey().GetID();
+        keystore.keys[keyid] = g_alpha_signet_key;
+        keystore.pubkeys[keyid] = g_alpha_signet_key.GetPubKey();
+
+        SignatureData sigdata;
+        bool signed_ok = ProduceSignature(keystore,
+            MutableTransactionSignatureCreator(tx_signing, /*nIn=*/0,
+                /*amount=*/signet_txs->m_to_spend.vout[0].nValue, SIGHASH_ALL),
+            challenge, sigdata);
+
+        if (!signed_ok) {
+            throw std::runtime_error(...);
+        }
+        UpdateInput(tx_signing.vin[0], sigdata);
+
+        // Serialize the signet solution: scriptSig || witness stack
+        std::vector<unsigned char> signet_solution;
+        VectorWriter writer{signet_solution, 0};
+        writer << tx_signing.vin[0].scriptSig;
+        writer << tx_signing.vin[0].scriptWitness.stack;
+
+        // Append SIGNET_HEADER + solution to witness commitment output
+        static constexpr uint8_t SIGNET_HEADER[4] = {0xec, 0xc7, 0xda, 0xa2};
+        int commitpos = GetWitnessCommitmentIndex(*pblock);
+        if (commitpos == NO_WITNESS_COMMITMENT) {
+            throw std::runtime_error(...);
+        }
+
+        CMutableTransaction mtx_coinbase(*pblock->vtx[0]);
+        std::vector<uint8_t> pushdata;
+        pushdata.insert(pushdata.end(), std::begin(SIGNET_HEADER), std::end(SIGNET_HEADER));
+        pushdata.insert(pushdata.end(), signet_solution.begin(), signet_solution.end());
+        mtx_coinbase.vout[commitpos].scriptPubKey << pushdata;
+        pblock->vtx[0] = MakeTransactionRef(std::move(mtx_coinbase));
+
+        // Recompute merkle root after modifying coinbase
+        pblock->hashMerkleRoot = BlockMerkleRoot(*pblock);
+
+        LogPrintf("CreateNewBlock(): signed block template for height %d\n", nHeight);
+    }
+    // !ALPHA SIGNET FORK END
```

**Line-by-line explanation of the signing procedure:**

The placement of this block is significant. It occurs after:
- All transactions have been selected and added to the block.
- The coinbase transaction has been constructed with the witness commitment output.
- The block header fields (`nBits`, `hashPrevBlock`, `nTime`, `nNonce`) have been set.

This ordering is required because `SignetTxs::Create` reads the block's witness commitment to find the signing point, and the commitment must be present before signing begins.

1. **Guard check** -- `g_alpha_signet_key.IsValid()` is checked to catch calls from nodes that started without a signing key configured. Since the startup validation only logs a warning (rather than refusing to start) when the fork is active and no key is present, this guard ensures that any RPC caller requesting a block template receives a clear error message rather than producing an invalid block.

2. **`SignetTxs::Create(*pblock, challenge)`** -- When called during signing, the block's coinbase will have a witness commitment but no `SIGNET_HEADER` section yet. In this case `FetchAndClearCommitmentSection` does not find the header, `signet_solution` remains empty, and `tx_spending.vin[0].scriptSig` and `witness.stack` are both empty. The signing transaction pair is constructed with an empty spending input, which is what will be signed.

3. **`FlatSigningProvider` setup** -- A minimal in-memory key store is constructed containing only the signing key. This is the correct approach because `ProduceSignature` is a generic signing function that works with any `SigningProvider`; using `FlatSigningProvider` with a single key avoids any wallet dependency.

4. **`ProduceSignature`** -- Generates a DER-encoded ECDSA signature using `SIGHASH_ALL`. For a 1-of-5 multisig challenge, `ProduceSignature` will construct a `scriptSig` of the form `OP_0 <sig>` (with the mandatory null dummy for `OP_CHECKMULTISIG`). The signature commits to the hash of the synthetic spending transaction, which itself commits to the modified Merkle root (block contents without the signet solution).

5. **`UpdateInput`** -- Applies the generated `sigdata` back to `tx_signing.vin[0]`, populating `scriptSig` and `scriptWitness.stack`.

6. **Serialization** -- The signet solution format is: Bitcoin-serialized `scriptSig` followed by Bitcoin-serialized `scriptWitness.stack` (as a vector of vectors). Both are written using `VectorWriter` which produces the same wire encoding that `SpanReader` in `SignetTxs::Create` expects to read back during validation.

7. **Embedding into the coinbase** -- The `SIGNET_HEADER` (`{0xec, 0xc7, 0xda, 0xa2}`) is prepended to the solution bytes, and the combined byte array is appended as a push to the witness commitment output's `scriptPubKey`. The `<<` operator on `CScript` performs a minimal push, so the data will be pushed as a `OP_PUSHDATA` instruction of appropriate length. This is exactly the format that `FetchAndClearCommitmentSection` searches for: a push whose data begins with the 4-byte magic header.

8. **Merkle root recomputation** -- Modifying the coinbase transaction changes its hash, which changes the Merkle root. `BlockMerkleRoot(*pblock)` recomputes this. The nonce field is not re-initialized because the miner will overwrite it during PoW search anyway. The block template returned by `CreateNewBlock` still has `nNonce = 0`.

9. **`TestBlockValidity`** -- The existing call to `TestBlockValidity` at the end of `CreateNewBlock` (which runs after the signet block shown above) will now validate the signed template. This means `ContextualCheckBlock` (which calls `CheckSignetBlockSolution`) runs on the template before it is handed to the miner, providing early detection of any signing errors.

**Cross-references:**
- The `SIGNET_HEADER` constant is identical to the one defined at the top of `signet.cpp` (line 26). It is redeclared as a local `static constexpr` in `miner.cpp` to avoid introducing an unnecessary dependency on signet's internal translation unit.
- The witness commitment index is found using `GetWitnessCommitmentIndex` from `<consensus/merkle.h>` (already included transitively).

---

### src/pow.cpp

**Role:** Implements `GetNextWorkRequired`, the function that computes the required difficulty (`nBits`) for the next block. Two changes are added: an explicit difficulty reset at the fork height, and a post-fork ASERT anchor switch.

**Full path:** `/home/vrogojin/alpha/src/pow.cpp`

```diff
+    // !ALPHA SIGNET FORK - Reset difficulty to powLimit at fork activation
+    if (g_isAlpha && params.nSignetActivationHeight > 0 && (pindexLast->nHeight + 1 == params.nSignetActivationHeight)) {
+        return nProofOfWorkLimit;
+    }
+    // !ALPHA SIGNET FORK END
```

**Line-by-line explanation:**

This guard checks whether the block being computed (`pindexLast->nHeight + 1`) is exactly the activation height. When true, it returns `nProofOfWorkLimit` unconditionally. `nProofOfWorkLimit` is computed as `UintToArith256(params.powLimit).GetCompact()` at the start of `GetNextWorkRequired`. The `powLimit` for Alpha mainnet is `0x1d0fffff` (a very low difficulty).

Why a difficulty reset is necessary: In the weeks or months before block 450,000, mining activity on the Alpha mainnet is driven by economic incentive (the 5 ALPHA block subsidy). ASERT continuously adjusts difficulty to maintain the 2-minute target. At block 450,000, the subsidy drops to zero. If the only authorized block producers are the five keyholders and they are not running industrial mining equipment, they would be unable to find blocks at the difficulty level established by RandomX miners. The explicit reset to minimum difficulty ensures the first post-fork block can be produced essentially immediately, and ASERT then adjusts from there.

After the difficulty reset at block 450,000, blocks 450,001 onward continue to use the existing ASERT anchor from block 70,232 (`asertAnchorParams`). No new post-fork anchor is needed because the original anchor was set to `powLimit` when ASERT was activated at the SHA256-to-RandomX transition. Since ASERT has maintained approximately 2-minute blocks throughout the chain's history, the cumulative time drift from the anchor is minimal, and ASERT naturally computes a difficulty close to `powLimit` for post-fork blocks. This is the same pattern that worked successfully during the SHA256-to-RandomX mining transition.

---

### src/validation.cpp

**Role:** The core block validation engine. Two distinct changes are made: a zero-subsidy enforcement in `GetBlockSubsidy`, and two calls to `CheckSignetBlockSolution` in the block connection pipeline. Additionally, the old "timebomb" forced shutdown at block 450,000 is removed.

**Full path:** `/home/vrogojin/alpha/src/validation.cpp`

#### Change 1: Zero subsidy

```diff
+    // !ALPHA SIGNET FORK - Zero subsidy at activation height
+    if (g_isAlpha && nHeight >= consensusParams.nSignetActivationHeight && consensusParams.nSignetActivationHeight > 0)
+        return 0;
+    // !ALPHA SIGNET FORK END
```

This is inserted inside `GetBlockSubsidy` immediately after the `!ALPHA` block that sets the base `nSubsidy = 10 * COIN`. The guard returns `0` before any further subsidy calculation (halving logic, etc.) can apply.

The ordering is significant: the guard runs after the Alpha/non-Alpha branch sets `nSubsidy`, but before the halving branch. This means:

```
GetBlockSubsidy(450000):
  nSubsidy = 10 * COIN    // !ALPHA block
  if 450000 >= 450000: return 0  // !ALPHA SIGNET FORK block  <-- early return
  // halving at 400000 never reached for post-fork blocks
```

The coinbase can still collect transaction fees; the constraint is on the mined subsidy portion. The existing check in `ConnectBlock`:
```cpp
if (block.vtx[0]->GetValueOut() > blockReward)
```
where `blockReward = nFees + GetBlockSubsidy(nHeight)`, will allow coinbase outputs summing to at most `nFees` (since subsidy is 0).

#### Change 2: ContextualCheckBlock signet check

```diff
+    // !ALPHA SIGNET FORK - Height-gated signet authorization check
+    if (g_isAlpha) {
+        if (!CheckSignetBlockSolution(block, chainman.GetConsensus(), nHeight)) {
+            return state.Invalid(BlockValidationResult::BLOCK_CONSENSUS, "bad-alpha-blksig",
+                "Alpha fork: block authorization signature validation failure");
+        }
+    }
+    // !ALPHA SIGNET FORK END
```

`ContextualCheckBlock` is called during both initial block download (when a new block arrives) and during reorganization. It receives the block and its height (`nHeight`, derived from `pindexPrev->nHeight + 1`). This is the primary enforcement point for the authorization check on new blocks.

The rejection code `"bad-alpha-blksig"` and reason string `"Alpha fork: block authorization signature validation failure"` will appear in ban scores and in the debug log. The `BlockValidationResult::BLOCK_CONSENSUS` result means that peers sending invalid blocks are subject to the normal peer banning logic.

Placement within `ContextualCheckBlock`: the call occurs after witness malleation checks but before the block weight check. This ordering means the authentication check has priority, and invalid blocks are rejected without the overhead of the weight calculation.

#### Change 3: ConnectBlock signet check (belt-and-suspenders)

```diff
+    // !ALPHA SIGNET FORK - Signet authorization check (belt-and-suspenders with ContextualCheckBlock)
+    if (g_isAlpha) {
+        if (!CheckSignetBlockSolution(block, params.GetConsensus(), pindex->nHeight)) {
+            LogPrintf("ERROR: ConnectBlock(): Alpha fork signet authorization failed at height %d\n", pindex->nHeight);
+            return state.Invalid(BlockValidationResult::BLOCK_CONSENSUS, "bad-alpha-blksig",
+                "Alpha fork: block authorization signature validation failure");
+        }
+    }
+    // !ALPHA SIGNET FORK END
```

`ConnectBlock` is called when a block is being connected to the active chain, including during reindex. This check redundantly re-validates the signet solution at the point where the block is actually being committed to chain state. The comment "belt-and-suspenders" refers to defensive programming: even if `ContextualCheckBlock` were somehow bypassed (for example, during a reindex that loads pre-validated blocks from disk), this check ensures that only authorized blocks can reach the UTXO set.

The placement of this check (before the `blockReward` computation) means that an unauthorized block fails authorization before its coinbase amount is ever examined.

#### Change 4: Removal of the timebomb

```diff
-    //Shut down to force recompilation
-      if (nHeight == 450000)
-          return FatalError(m_chainman.GetNotifications(), state, "Forced shutdown at block 450,000. Get latest version");
```

This removes the old mechanism that forced node shutdown at block 450,000. That code existed to compel operators to upgrade their nodes before the fork. Now that the fork implementation is in the code, the timebomb is superseded. The node no longer self-terminates; instead it correctly processes block 450,000 under the new consensus rules.

**Security implications of the dual check:** `ContextualCheckBlock` is called in `ChainstateManager::ProcessNewBlock` for newly received blocks. `ConnectBlock` is called in `Chainstate::ConnectTip`. Blocks that bypass `ProcessNewBlock` (such as blocks loaded during initial sync from a trusted peer's block data, or blocks loaded during reindex) still pass through `ConnectBlock`. The dual enforcement ensures that no path through the validation code can commit an unauthorized block to chain state.

---

### src/rpc/mining.cpp

**Role:** Implements the `getblocktemplate` RPC. The change adds informational fields to the template response that allow external mining infrastructure to detect when the signet fork is active.

**Full path:** `/home/vrogojin/alpha/src/rpc/mining.cpp`

```diff
+    // !ALPHA SIGNET FORK
+    if (g_isAlpha && consensusParams.nSignetActivationHeight > 0 &&
+        (pindexPrev->nHeight + 1) >= consensusParams.nSignetActivationHeight) {
+        result.pushKV("alpha_signet_challenge", HexStr(consensusParams.signet_challenge_alpha));
+        result.pushKV("alpha_signet_active", true);
+    }
+    // !ALPHA SIGNET FORK END
```

**Line-by-line explanation:**

Two new JSON fields are added to the `getblocktemplate` response when the fork is active:

- `"alpha_signet_challenge"` -- The hex-encoded challenge script. External tools (custom mining pools, monitoring dashboards, block explorers) can use this to confirm which challenge is in effect and to independently verify that submitted blocks contain a valid solution. The format is the raw script bytes, identical to how `signet_challenge` is reported for BIP325 signet chains.

- `"alpha_signet_active"` -- A boolean flag. Its presence and `true` value signal to any client polling `getblocktemplate` that they are past the activation height and that block templates will have the signet solution pre-embedded. Clients that do not understand the Alpha fork can at least detect that something has changed.

Note that internal nodes (those with `-signetblockkey` configured) do not need to inspect these fields: `CreateNewBlock` already embeds the signature automatically. These fields are primarily for external monitoring and for any third-party mining software that might need to understand the chain's state.

**Cross-references:** This is a pure read-only change to the RPC output. No consensus rules are modified here.

---

### src/init.cpp

**Role:** Implements `AppInitMain`, the node startup function, and `SetupServerArgs`, which registers all command-line and config-file arguments. Two changes are made: registration of `-signetblockkey`, and startup validation of the configured key.

**Full path:** `/home/vrogojin/alpha/src/init.cpp`

#### New includes

```diff
+// !ALPHA SIGNET FORK
+#include <key.h>
+#include <key_io.h>
+#include <script/script.h>
+// !ALPHA SIGNET FORK END
```

- `<key.h>` -- For `CKey`, `CPubKey`, `CKeyID`.
- `<key_io.h>` -- For `DecodeSecret` (WIF decoder).
- `<script/script.h>` -- For `CScript`, `opcodetype`, and `GetOp`.

#### New argument registration

```diff
+    // !ALPHA SIGNET FORK
+    argsman.AddArg("-signetblockkey=<WIF>",
+        "WIF-encoded private key for signing blocks after fork activation height (Alpha mainnet only). "
+        "Required when -server is enabled and chain is at or near fork height. "
+        "MUST be set in alpha.conf, not on the command line.",
+        ArgsManager::ALLOW_ANY | ArgsManager::SENSITIVE, OptionsCategory::BLOCK_CREATION);
+    // !ALPHA SIGNET FORK END
```

**Key design decisions:**

- `ArgsManager::SENSITIVE` -- This flag causes the argument value to be redacted in the debug log and in RPC responses that dump the argument list (`logging`, `getinfo`). Private keys must never appear in logs. Without this flag, the WIF-encoded private key would be printed in plain text when the node starts up with high verbosity.

- `OptionsCategory::BLOCK_CREATION` -- Groups the argument with other mining-related parameters (`-blockminsize`, `-blockmaxweight`, etc.) in the help output.

- The comment "MUST be set in alpha.conf, not on the command line" is advisory documentation in the help text. It reflects the operational security concern that command-line arguments may appear in `ps` output or shell history on the server. The `ArgsManager` does not technically enforce this restriction, but the help text communicates the expectation to operators.

#### Startup key validation

```diff
+    // !ALPHA SIGNET FORK - Validate signing key at startup (template-serving mode only)
+    if (g_isAlpha) {
+        const Consensus::Params& forkParams = chainman.GetConsensus();
+        const bool isTemplateMode = args.GetBoolArg("-server", false);
+        const bool forkActive = (forkParams.nSignetActivationHeight > 0) &&
+            (chain_active_height >= forkParams.nSignetActivationHeight);
+
+        if (isTemplateMode && forkActive) {
+            // ... key validation logic ...
+        }
+    }
+    // !ALPHA SIGNET FORK END
```

**Line-by-line explanation:**

- `isTemplateMode` -- `true` when `-server` is passed, meaning this node accepts RPC connections and can serve block templates. Nodes not in server mode (e.g., plain peers, offline signers, block explorers) do not need a signing key and are not validated.

- `forkActive` -- `true` when the chain tip is at or past block 450,000. In this state, a server-mode node without a valid signing key logs a warning but continues to start normally. The node can sync the chain and serve as a full node; it just cannot produce signed block templates.

The key validation procedure when a key is provided:

1. **WIF decode** -- `DecodeSecret(strKey)` parses the WIF-encoded string into a `CKey` object. If the string is malformed (wrong checksum, wrong prefix, wrong length), `signingKey.IsValid()` returns `false` and startup fails with a descriptive error.

2. **Public key derivation** -- `signingKey.GetPubKey()` derives the compressed 33-byte public key. `VerifyPubKey(signingPubKey)` signs a test message and verifies it to confirm the key pair is internally consistent. This catches any implementation-level inconsistency.

3. **Allowlist check** -- The challenge script is decoded opcode by opcode using `CScript::GetOp`. The loop scans all push data elements of exactly 33 bytes (`CPubKey::COMPRESSED_SIZE`), treating each as a candidate compressed public key. If any candidate key matches `signingPubKey`, `keyAuthorized` is set to `true`. The loop uses `CPubKey::IsFullyValid()` to skip any 33-byte push that is not actually a valid secp256k1 point (this is defensive, since the challenge script should always contain valid keys). If no match is found, startup fails with an error message naming the derived public key hex and the count of authorized keys (hardcoded as 5 in the error message, consistent with the mainnet challenge).

4. **Key storage** -- `g_alpha_signet_key = signingKey` stores the validated key in the global variable declared in `miner.h`. This is the only place in the codebase where `g_alpha_signet_key` is written.

5. **Logging** -- The first 16 hex characters of the public key are logged (8 bytes = 16 hex chars), sufficient for an operator to identify which key was loaded without revealing a meaningful fraction of the key material.

**Security implications of the allowlist check:**

The allowlist check at startup serves two purposes. First, it prevents misconfiguration: an operator who accidentally configures the wrong private key will see an immediate error rather than silently producing blocks that peers reject. Second, it provides a lightweight audit: a node operator can independently verify that their key is authorized by comparing the logged public key against the challenge script in chainparams. The check iterates the challenge script without executing it, which avoids any Script interpreter complexity at startup.

**Cross-references:**
- `g_alpha_signet_key` is written here and read in `src/node/miner.cpp`.
- `chainman.GetConsensus()` returns the same `Consensus::Params` configured in `src/kernel/chainparams.cpp`.
- The `chain_active_height` variable is retrieved at the beginning of the block shown, via `WITH_LOCK(cs_main, return chainman.ActiveChain().Height())`.

---

## Execution Flow

### Block Template Creation Flow (post-fork)

```
RPC call: getblocktemplate
    |
    v
BlockAssembler::CreateNewBlock(scriptPubKeyIn)
    |
    +-- Select transactions from mempool
    +-- Build coinbase tx:
    |     - Output 0: scriptPubKeyIn (miner reward address, value = nFees + 0 subsidy)
    |     - Output 1: OP_RETURN + witness commitment (AA21A9ED...)
    +-- Set block header fields (nBits = nProofOfWorkLimit for block 450000)
    |
    v
    [ALPHA SIGNET FORK block - only if g_isAlpha && height >= 450000]
    |
    +-- Check g_alpha_signet_key.IsValid()
    +-- SignetTxs::Create(*pblock, challenge)
    |     Creates synthetic (to_spend, to_sign) pair
    |     to_spend.vout[0].scriptPubKey = challenge (1-of-5 multisig)
    |     to_sign.vin[0] is empty (no solution in coinbase yet)
    |
    +-- ProduceSignature(keystore, creator, challenge, sigdata)
    |     Signs over modified Merkle root
    |     Produces ECDSA signature in sigdata
    |
    +-- Serialize solution: scriptSig || witness.stack -> signet_solution bytes
    |
    +-- Embed in coinbase:
    |     coinbase.vout[commitpos].scriptPubKey << SIGNET_HEADER || signet_solution
    |
    +-- Recompute hashMerkleRoot
    |
    v
TestBlockValidity(block, pindexPrev, fCheckPOW=false)
    |
    +-- ContextualCheckBlock(block, state, nHeight=450000)
          |
          +-- CheckSignetBlockSolution(block, params, 450000)  [ALPHA SIGNET FORK]
                Returns true (solution just embedded)
```

### Block Validation Flow (new blocks arriving)

```
Peer sends block
    |
    v
ProcessNewBlock
    |
    v
CheckBlock (stateless)
    No signet check here
    |
    v
ContextualCheckBlock (with pindexPrev)
    |
    +-- CheckWitnessMalleation
    +-- [ALPHA SIGNET FORK]
    +-- CheckSignetBlockSolution(block, params, nHeight)
    |     if nHeight < 450000: return true (no-op)
    |     if nHeight >= 450000:
    |       Find SIGNET_HEADER in coinbase witness commitment
    |       Extract scriptSig and witness from solution bytes
    |       Build (to_spend, to_sign) pair with modified Merkle root
    |       VerifyScript(scriptSig, challenge, witness, flags, checker)
    |       Return true if 1-of-5 multisig passes
    +-- Check block weight
    |
    v
ConnectBlock (if block passes all checks)
    |
    +-- Execute all transactions
    +-- [ALPHA SIGNET FORK belt-and-suspenders]
    +-- CheckSignetBlockSolution(block, params, pindex->nHeight)
    +-- Check coinbase value <= nFees + GetBlockSubsidy(nHeight)
    |     GetBlockSubsidy returns 0 for nHeight >= 450000
    |     So coinbase value must be <= nFees
    +-- Update UTXO set
```

### Block Validation Flow (reindex)

During reindex, blocks are read from disk and re-validated. The path is:
```
LoadBlockFromDisk -> ConnectBlock
```

`ContextualCheckBlock` is also called during reindex as part of the `ChainstateManager::ProcessNewBlock` path when blocks are being reconnected after a reorganization. Both checks run, ensuring that even blocks that were stored before the fork implementation existed must pass validation under the new rules if they are at height >= 450,000.

In practice, blocks stored before the fork implementation were produced by the old timebomb code, which would have force-shut the node at block 450,000. Those blocks do not exist on the chain. The first block at height 450,000 will be produced after this implementation is deployed.

### Startup Initialization Flow

```
main() -> AppInit()
    |
    v
AppInitMain()
    |
    +-- Load chainparams (consensus.nSignetActivationHeight = 450000, etc.)
    +-- g_isAlpha = true
    |
    v
    [ALPHA SIGNET FORK startup logging]
    |
    +-- Log fork height + challenge script + authorized pubkeys
    |   (uses ExtractPubkeysFromChallenge shared helper)
    +-- If mainnet + CLI args set: log WARNING that they are ignored
    |
    +-- Load block index
    +-- chain_active_height = chainman.ActiveChain().Height()
    |
    v
    [ALPHA SIGNET FORK key validation]
    |
    +-- if not g_isAlpha: skip
    +-- if not -server: skip (non-template nodes don't need a key)
    +-- if chain_active_height < nSignetActivationHeight: skip (fork not active)
    +-- if chain_active_height >= activation height:
    |     if no -signetblockkey: log WARNING, continue (node runs as non-mining full node)
    |     if -signetblockkey provided: validate key against challenge
    |       (uses ExtractPubkeysFromChallenge, dynamic pubkey count in error msg)
    |
    v
    [if key validated]
    g_alpha_signet_key = signingKey
    LogPrintf("Alpha fork: signing key validated and loaded (pubkey: <first 16 hex chars>...)")
    |
    v
    Start RPC server, P2P network, etc.
```

---

## Configuration Guide

### The `-signetforkheight` and `-signetforkpubkeys` Parameters (testnet/regtest only)

These two parameters configure the signet fork on `alphatestnet` and `alpharegtest` chains. They are ignored on `alpha` (mainnet), which uses hardcoded values.

- `-signetforkheight=<n>` -- Activation height for the signet-style fork. Default: `0` (disabled). Must be a non-negative integer. When set to `> 0`, `-signetforkpubkeys` is required.

- `-signetforkpubkeys=<hex1>,<hex2>,...` -- Comma-separated list of compressed secp256k1 public keys (33 bytes each, 66 hex characters). These are combined into a 1-of-N bare multisig challenge script using `GetScriptForMultisig(1, pubkeys)`. Required when `-signetforkheight > 0`.

**Cross-validation:** The two parameters are validated together:
- If `-signetforkheight > 0` is set without `-signetforkpubkeys`, startup fails.
- If `-signetforkpubkeys` is set without `-signetforkheight > 0`, startup fails.
- Each pubkey is validated as a 33-byte hex string and a valid secp256k1 point.

**Example:**
```bash
alphad -chain=alpharegtest \
  -signetforkheight=10 \
  -signetforkpubkeys=02a1b2c3...,03d4e5f6... \
  -signetblockkey=KwDi... \
  -server
```

### The `-signetblockkey` Parameter

The new parameter accepts a WIF-encoded (Wallet Import Format) private key. WIF encoding is the standard Bitcoin format for private keys, using Base58Check encoding with a network-specific prefix.

**How to generate a key pair:**

On a trusted, air-gapped machine:
```
alpha-cli -chain=alpha getnewaddress
alpha-cli -chain=alpha dumpprivkey <address>
```

Or using the Bitcoin Core key generation tools:
```
bitcoin-cli -regtest getnewaddress
bitcoin-cli -regtest dumpprivkey <address>
```

The WIF key begins with a network-specific prefix byte. For Alpha mainnet, the `SECRET_KEY` prefix is `0x80` (same as Bitcoin mainnet), so WIF keys begin with `5` (uncompressed) or `K`/`L` (compressed). Compressed keys must be used because the challenge script contains 33-byte compressed public keys.

**Correct placement in alpha.conf:**

The parameter must be placed in `$HOME/.alpha/alpha.conf` (not passed on the command line):

```
# alpha.conf
chain=alpha
server=1
rpcuser=alpharpc
rpcpassword=<your-rpc-password>

# Signet fork signing key (SENSITIVE - keep this file private)
signetblockkey=KwDiBf89QgGbjEhKnhXJuH7LrciVrZi3qYjgd9M7rFfX3tRkvVt
```

**Access control:** The `alpha.conf` file should be owned by the node's service account and readable only by that account:
```
chmod 600 ~/.alpha/alpha.conf
```

**Key authorization:** The WIF key's corresponding public key must match one of the five public keys embedded in `consensus.signet_challenge_alpha` in `src/kernel/chainparams.cpp`. If it does not, the node refuses to start with the error:

```
Error: Configured -signetblockkey public key (<hex>) is NOT in the authorized allowlist.
The key must correspond to one of the 5 authorized pubkeys in the fork challenge script.
```

**Verification before deployment:** After configuring the key and before the fork is approaching, start the node and check the log for:

```
Alpha fork: signing key validated and loaded (pubkey: <first 16 chars>...)
```

Confirm that the 16-character prefix matches the expected public key of your authorized key.

---

## Deployment Notes

### What must happen before mainnet deployment

The current code contains placeholder public keys in `src/kernel/chainparams.cpp`. **These placeholders are not valid compressed public keys and the code will not compile correctly until they are replaced.** The following must be completed before the binary is released:

1. **Generate five key pairs.** Each of the five authorized block producers must generate a fresh key pair on a secure, isolated machine. The private key must be stored securely (hardware wallet, encrypted storage). The compressed public key (33 bytes, 66 hex characters) is the only value that needs to leave the secure environment.

2. **Replace placeholders in chainparams.cpp.** Each of the five `PLACEHOLDER_PUBKEY_N_33_BYTES_HEX_66_CHARS_HERE_000000000N` strings in the `signet_challenge_alpha` `ParseHex` call must be replaced with the actual 66-character hex encoding of the corresponding compressed public key. The format is:
   ```
   "21" "<66 hex chars of compressed pubkey>"
   ```
   The `0x21` prefix byte is a Script push opcode meaning "push 33 bytes." It must be retained.

3. **Verify the challenge script.** After replacement, decode the challenge script and verify that it correctly encodes a 1-of-5 bare multisig:
   ```python
   from bitcoin.core.script import CScript
   script = bytes.fromhex("51" + "21" + pubkey1 + "21" + pubkey2 + ... + "55" + "ae")
   print(CScript(script))  # should show: OP_1 <pk1> <pk2> <pk3> <pk4> <pk5> OP_5 OP_CHECKMULTISIG
   ```

4. **Distribute WIF private keys to authorized operators.** Each of the five operators receives their own WIF-encoded private key and configures it in their `alpha.conf`. They confirm startup by checking the log for their key's public key prefix.

5. **Coordinate the deployment timeline.** The binary must be deployed to all full nodes on the network before block 450,000. Any node running old code at block 450,000 will have its `FatalError` timebomb trigger, forcing it offline. Nodes running the new code will transition seamlessly.

6. **Signed binary distribution.** The binary should be signed by a trusted key (e.g., a project GPG key) and the signature published alongside the release. Node operators should verify the signature before deploying.

---

## Testing Strategy

### Regtest testing (CLI-based)

Regtest fork parameters are now configured via CLI flags instead of hardcoded values. By default, the fork is **disabled** on regtest (height=0).

**Enable fork on regtest with real keys:**
```bash
# Generate a test key pair first
alphad -chain=alpharegtest -server -rpcuser=test -rpcpassword=test -daemon
ADDR=$(alpha-cli -chain=alpharegtest getnewaddress)
WIF=$(alpha-cli -chain=alpharegtest dumpprivkey $ADDR)
PUBKEY=$(alpha-cli -chain=alpharegtest getaddressinfo $ADDR | jq -r '.pubkey')
alpha-cli -chain=alpharegtest stop

# Start with fork enabled at height 10
alphad -chain=alpharegtest \
  -signetforkheight=10 \
  -signetforkpubkeys=$PUBKEY \
  -signetblockkey=$WIF \
  -server -rpcuser=test -rpcpassword=test -daemon

# Confirm startup logs show fork height=10 and the pubkey
# Mine 9 blocks (pre-fork) — normal subsidy
alpha-cli -chain=alpharegtest generatetoaddress 9 $ADDR

# Mine block 10 — zero subsidy, signed template
alpha-cli -chain=alpharegtest generatetoaddress 1 $ADDR

# Confirm getblocktemplate returns alpha_signet_active: true
alpha-cli -chain=alpharegtest getblocktemplate '{"rules": ["segwit"]}'
```

**Regtest without fork (default):**
```bash
alphad -chain=alpharegtest -server -rpcuser=test -rpcpassword=test -daemon
# Confirm log says "Alpha signet fork: disabled"
# Mine blocks normally — no fork behavior
```

**Test that unsigned blocks are rejected:**
```bash
# Start a second regtest node with fork enabled but NO -signetblockkey
# Attempt to mine post-fork — should fail with missing SIGNET_HEADER
```

### Testnet testing

Testnet fork parameters are also configured via CLI. To test the full signing flow:
```bash
alphad -chain=alphatestnet \
  -signetforkheight=100 \
  -signetforkpubkeys=$PUBKEY1,$PUBKEY2 \
  -signetblockkey=$WIF_FOR_PUBKEY1 \
  -server
```

### Unit test considerations

The following unit tests should be written (if not already present):

1. **`GetBlockSubsidy` boundary test:** Verify that `GetBlockSubsidy(449999)` returns 5 COIN (post-halving at 400000, Alpha rate) and `GetBlockSubsidy(450000)` returns 0.

2. **`GetNextWorkRequired` fork boundary test:** Verify that calling `GetNextWorkRequired` with `pindexLast->nHeight = 449999` returns `nProofOfWorkLimit`.

3. **`CheckSignetBlockSolution` height gate test:** Verify that the three-argument overload returns `true` for blocks below the activation height without examining the block contents (using a block with no witness commitment as input).

4. **`CreateNewBlock` signing test:** On regtest with `-signetforkheight` and `-signetforkpubkeys` configured, verify that block templates at post-fork heights contain `SIGNET_HEADER` in the coinbase witness commitment output.

### Functional test considerations

A Python functional test in `test/functional/` should:

1. Start a regtest node with `-signetforkheight=10 -signetforkpubkeys=<hex> -signetblockkey=<WIF>`.
2. Mine 9 blocks and verify subsidy is nonzero.
3. Mine block 10 and verify subsidy is zero.
4. Verify that block 10's coinbase contains the `SIGNET_HEADER` and a valid signature.
5. Verify that `getblocktemplate` returns `alpha_signet_active: true` after block 10.
6. Start a second regtest node with the same fork params but no `-signetblockkey`, verify that unsigned blocks are rejected with "missing SIGNET_HEADER".

---

## Appendix: Script Encoding Reference

### The 1-of-5 Bare Multisig Challenge Script

The mainnet challenge script is a bare multisig in the following format:

```
Byte offset  Value    Meaning
0            0x51     OP_1 (minimum signatures required: 1)
1            0x21     Push 33 bytes (compressed public key length)
2..34        <pk1>    Compressed public key 1 (33 bytes)
35           0x21     Push 33 bytes
36..68       <pk2>    Compressed public key 2
69           0x21     Push 33 bytes
70..102      <pk3>    Compressed public key 3
103          0x21     Push 33 bytes
104..136     <pk4>    Compressed public key 4
137          0x21     Push 33 bytes
138..170     <pk5>    Compressed public key 5
171          0x55     OP_5 (total number of keys: 5)
172          0xae     OP_CHECKMULTISIG
```

Total script length: 173 bytes.

A valid `scriptSig` satisfying this challenge has the form:
```
OP_0 <DER-encoded signature (71-73 bytes) with SIGHASH_ALL (0x01) suffix>
```

The `OP_0` is the mandatory null dummy required by BIP147 (`SCRIPT_VERIFY_NULLDUMMY`).

### The SIGNET_HEADER Magic Bytes

```
0xec 0xc7 0xda 0xa2
```

These four bytes are the same magic used by Bitcoin's signet mechanism (`SIGNET_HEADER` in `signet.cpp`). The Alpha fork reuses this constant unchanged. The bytes have no inherent meaning beyond serving as a unique prefix that the parser searches for within OP_RETURN pushes in the witness commitment output.

### The Witness Commitment Output

The witness commitment output (identified by `GetWitnessCommitmentIndex`) is the last output in the coinbase whose `scriptPubKey` begins with the commitment header `{0xaa, 0x21, 0xa9, 0xed}`. After embedding the signet solution, the output's `scriptPubKey` contains:

```
OP_RETURN
<36-byte witness commitment: 0xaa 0x21 0xa9 0xed <32-byte hash>>
<N-byte push: 0xec 0xc7 0xda 0xa2 <scriptSig length-prefixed> <witness stack serialized>>
```

The witness commitment hash covers the witness data of all transactions. The signet solution is appended as an additional push data item, which is why it does not affect the witness commitment hash itself (the hash was computed before the solution was appended).

---

## Code Review Findings and Open Issues

### Correctness

The three-way coordination between zero subsidy, difficulty reset, and signet authorization is logically consistent:

- Block 449999: last pre-fork block. Normal rules.
- Block 450000 (`nHeight == nSignetActivationHeight`):
  - `GetBlockSubsidy` returns 0 (zero subsidy check triggers first).
  - `GetNextWorkRequired` returns `powLimit` (difficulty reset).
  - `CheckSignetBlockSolution` requires a valid authorization signature.
  - The template for this block is produced by `CreateNewBlock` with the signing logic embedded.
- Block 450001+:
  - Subsidy remains 0.
  - ASERT continues using the original anchor from block 70,232; since the chain has maintained ~2-minute blocks, the computed difficulty remains near `powLimit`.
  - Authorization required.

### Open Issues

1. **CRITICAL: Placeholder pubkeys must be replaced.** The `signet_challenge_alpha` in `CAlphaMainParams` uses non-EC-point placeholder byte strings. Deployment with these keys will make all post-fork blocks unverifiable and stall the chain. The five authorized compressed pubkeys must be substituted before any mainnet release.

2. **SIGNET_HEADER duplication.** The constant `{0xec, 0xc7, 0xda, 0xa2}` is defined independently in `signet.cpp` (line 26, as a file-scope `static constexpr`) and again in `miner.cpp` (line 239, as a function-local `static constexpr`). If the header bytes are ever modified in one place but not the other, produced blocks will fail validation. This constant should be moved to `signet.h` as a shared exported constant.

3. **`-server` as template-mode proxy.** The startup key check uses `-server` to identify template-serving mode. Nodes running with `-server` but without `-signetblockkey` will start normally post-fork but will be unable to produce block templates (RPC callers will receive an error). Operators who want to mine should configure `-signetblockkey`.

4. **~~Hardcoded "5" in error message~~ FIXED.** `init.cpp` now uses `ExtractPubkeysFromChallenge()` to derive the count dynamically from the challenge script.

5. **No unit tests for the new consensus rules.** The existing test framework (functional tests and unit tests inherited from Bitcoin Core) does not include tests specific to the `nSignetActivationHeight` path. Test coverage for: (a) zero-subsidy at exactly height 450000 vs 449999; (b) difficulty reset at the boundary; (c) signet check accept/reject at the boundary; should be added before deployment.

---

---

## File Reference Summary

| File | Changes | Purpose |
|------|---------|---------|
| `src/consensus/params.h` | Added 2 new fields to `struct Params` | Fork activation height, challenge script |
| `src/kernel/chainparams.h` | Added `AlphaSignetForkOptions` struct, updated factory signatures | Configurable fork params for testnet/regtest |
| `src/kernel/chainparams.cpp` | Added `BuildSignetChallenge`, updated constructors + factories | Configure fork parameters per chain; CLI-driven on test chains |
| `src/chainparams.cpp` | Added `ReadAlphaSignetForkArgs`, updated `CreateChainParams` dispatch | Parse `-signetforkheight`/`-signetforkpubkeys` CLI args |
| `src/chainparamsbase.cpp` | Registered `-signetforkheight` and `-signetforkpubkeys` | CLI arg registration |
| `src/signet.h` | Added height-aware function + `ExtractPubkeysFromChallenge` | Shared pubkey extraction helper |
| `src/signet.cpp` | Explicit SIGNET_HEADER check + `ExtractPubkeysFromChallenge` impl | Height-gated signet verification with explicit header rejection |
| `src/validation.cpp` | 4 edits: zero subsidy, timebomb removal, 2 signet checks | Core consensus enforcement |
| `src/pow.cpp` | 1 edit: difficulty reset at fork height | Prevent chain stall at fork |
| `src/node/miner.h` | Added global key declaration | `extern CKey g_alpha_signet_key` |
| `src/node/miner.cpp` | Added key definition + template signing logic | Embed BIP325 signet solution in block templates |
| `src/init.cpp` | Startup logging, CLI warning, refactored key validation | Log fork params, warn on mainnet CLI args, use shared helper |
| `src/rpc/mining.cpp` | Added informational RPC fields | Expose challenge + active flag in `getblocktemplate` |

---

*Document updated: 2026-02-18. All code modifications are marked with `// !ALPHA SIGNET FORK` and `// !ALPHA SIGNET FORK END` comment delimiters.*

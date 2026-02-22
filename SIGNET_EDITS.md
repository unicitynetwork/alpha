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
   - [src/init.cpp](#srcinitcpp)
4. [Execution Flow](#execution-flow)
5. [Configuration Guide](#configuration-guide)
6. [Deployment Notes](#deployment-notes)
7. [Testing Strategy](#testing-strategy)
8. [Appendix: Script Encoding Reference](#appendix-script-encoding-reference)

---

## Overview

At block height 450,000, the Alpha mainnet undergoes a programmatic hard fork that transitions the chain from open RandomX proof-of-work mining to a federation-based block production model. This is one of Alpha's scheduled "programmatic hard forks" (the pattern established in the CLAUDE.md as occurring every 50,000 blocks from 400,000 onward). Note: at fork-adjacent heights (400,000–449,999), the subsidy is already halved to 5 ALPHA per block (halving at block 400,000).

The fork implements three simultaneous consensus rule changes that activate atomically at block 450,000:

1. **Zero block subsidy and fee burning** -- The block reward drops to exactly 0: both the subsidy (via `GetBlockSubsidy` returning 0) and transaction fees are burned. Post-fork, `blockReward` is forced to 0 in `ConnectBlock`, so the coinbase output must have zero value. `CreateNewBlock` also sets `coinbaseTx.vout[0].nValue = 0` to produce compliant templates. This eliminates all economic incentive for unauthorized miners, since only authorized miners can produce blocks and they cannot collect fees.

2. **Difficulty reset** -- The difficulty for block 450,000 is forced to `powLimit` (minimum difficulty), preventing a chain stall. After block 450,000, the existing ASERT anchor from block 70,232 continues to govern difficulty adjustment. Since the chain has maintained ~2-minute blocks, ASERT naturally computes a difficulty near `powLimit` for post-fork blocks.

3. **Signet-style block authorization** -- Every block at height >= 450,000 must carry a valid signature from one of five authorized keys, embedded in the coinbase witness commitment using the BIP325 signet mechanism. Blocks lacking a valid signature are rejected by all consensus rules.

In addition to the three consensus changes, four supporting infrastructure changes enable authorized nodes to produce valid blocks:

4. **Startup key validation** -- If `-signetblockkey` is provided, the key is always validated against the authorized public keys in the challenge script, regardless of `-server` mode or current chain height. This ensures operators discover misconfiguration immediately at startup, not when the fork activates. If no key is configured, the node starts normally as a non-mining full node.

5. **Template signing** -- `CreateNewBlock()` automatically appends the SIGNET_HEADER and serialized signature to the coinbase witness commitment output of every block template it produces for heights >= 450,000. The Merkle root is recomputed after this modification.

6. **New config parameter** -- `-signetblockkey=<WIF>` is registered as a `SENSITIVE` argument in the `BLOCK_CREATION` category.

The approach deliberately reuses Bitcoin Core's existing `signet.cpp` / `SignetTxs` infrastructure rather than reimplementing the signing and verification logic from scratch. The only new code is the height-gated wrapper that activates the signet check at a specific block height on the Alpha mainnet, instead of being chain-wide as in Bitcoin's signet.

---

## Architecture of the Three Simultaneous Consensus Changes

```
Block 449,999 (last PoW block)
     |
     v
Block 450,000 (first fork block)
     |
     +--- Subsidy + fee burn: GetBlockSubsidy(450000) returns 0
     |     AND blockReward forced to 0 (fees burned)
     |     Coinbase value must be exactly 0
     |
     +--- Difficulty: GetNextWorkRequired() returns nProofOfWorkLimit
     |     (minimum difficulty, so the block is trivially solvable)
     |     Future blocks: ASERT re-anchors at block 450,000 with nBits=powLimit
     |
     +--- Authorization: CheckSignetBlockSolution(block, params, 450000)
           Must find SIGNET_HEADER in coinbase witness commitment
           Signature must satisfy 1-of-5 multisig challenge script
```

The three changes interact in a specific order within the validation pipeline. Difficulty is checked at the header level during `CheckProofOfWork`. The signet authorization check occurs first in `ContextualCheckBlock` (primary enforcement) and again in `ConnectBlock` (belt-and-suspenders). In `ConnectBlock`, the authorization check precedes the coinbase value check, so an unauthorized block fails authorization before its coinbase amount is ever evaluated. The subsidy check happens after the signet check in `ConnectBlock`.

---

## File-by-File Modification Guide

### src/consensus/params.h

**Role:** Defines the `Consensus::Params` struct that holds all consensus-critical parameters for a chain. This is the data structure passed throughout the codebase to make consensus decisions. Adding fields here is the first step in introducing any new consensus rule.

**Full path:** `/home/vrogojin/alpha/src/consensus/params.h`

```diff
@@ -180,6 +180,10 @@ struct Params {
     uint32_t RandomX_DiffMult;
     // !ALPHA END

+    // !ALPHA SIGNET FORK
+    int nSignetActivationHeight{0};              // Height at which signet authorization activates (0 = never)
+    // Challenge script stored in signet_challenge (safe because signet_blocks=false on Alpha chains,
+    // so native BIP325 code paths never read it)
+    // !ALPHA SIGNET FORK END

     // !SCASH END
 };
```

**Line-by-line explanation:**

- `int nSignetActivationHeight{0}` -- The block height at which the three consensus changes activate. The in-class initializer `{0}` means that if a chain (such as the original Bitcoin mainnet or signet) does not configure this field, the fork is permanently disabled. The value `0` is treated as "never" by every guard throughout the codebase (all guards test `> 0` before taking any action). On the Alpha mainnet this is set to `450000`; on testnet and regtest it is configurable via CLI flags for testing purposes.

- There is no longer a separate `signet_challenge_alpha` field. The challenge script is stored directly in the pre-existing `signet_challenge` field (of type `std::vector<uint8_t>`). This is safe because all three Alpha chain constructors set `consensus.signet_blocks = false`, which prevents the native BIP325 code path in the original `CheckSignetBlockSolution(block, params)` from reading the field. The height-gated Alpha overload is the only consumer of `signet_challenge` on Alpha chains.

**Cross-references:** Every other modified file reads `nSignetActivationHeight` and `signet_challenge`. The in-class initializer `{0}` on `nSignetActivationHeight` ensures backward compatibility: code compiled without any chain configuration will have `nSignetActivationHeight == 0` and all guards will silently pass. The `signet_challenge` field already existed in `Params` and defaults to an empty vector.

**Security implications:** Reusing `signet_challenge` rather than adding a new field eliminates any risk of the two fields diverging if chainparams are edited. Placing `nSignetActivationHeight{0}` in the struct definition is a defensive choice: a new chain type inadvertently omitting this field cannot accidentally activate the fork, because the value defaults to "never active."

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
+        consensus.signet_challenge = ParseHex(
+            "51"                                                              // OP_1
+            "21" "02a86f4a1875e967435d9836df3dfba75fc84700af293ce487a99d6adb6f4ebecc"  // push 33 bytes + pubkey 1
+            "21" "0234dae4ef312c640fa00f4d74048da77262224e506341b85f0b2a783c811bcef0"  // push 33 bytes + pubkey 2
+            "21" "023602941d79d865ad32e88265feb101f3990a813d46b2fc01bc6601e9df7d69cc"  // push 33 bytes + pubkey 3
+            "21" "024f12994fae223c07a2a802b9fa0cb8a1f5d24a7fedc40d3c2fad0a69574b2f9e"  // push 33 bytes + pubkey 4
+            "21" "030934597b587069a9bb885782790eae0b16496e4863d0d6b7ad1ba0de0b078b3e"  // push 33 bytes + pubkey 5
+            "55"                                                              // OP_5
+            "ae"                                                              // OP_CHECKMULTISIG
+        );
+        // !ALPHA SIGNET FORK END
```

Note: the mainnet constructor also sets `consensus.signet_blocks = false` (a pre-existing field) at the top of the constructor body, before the fork block. This guard ensures that the native BIP325 code path (the original two-argument `CheckSignetBlockSolution`) never reads `signet_challenge` on Alpha chains, preventing any interference between the two mechanisms.

**Line-by-line explanation:**

- `consensus.nSignetActivationHeight = 450000` -- Sets the fork activation height. This is the first block that must comply with all three new consensus rules.

- `consensus.signet_challenge = ParseHex(...)` -- The challenge script is stored in the pre-existing `signet_challenge` field. It encodes a 1-of-5 bare multisig in standard Script. The five real compressed secp256k1 pubkeys are now deployed (see keys above). The byte encoding is:
  - `0x51` = `OP_1` (minimum signature count required)
  - `0x21` = push 33 bytes (compressed public key length)
  - 66 hex characters = 33 bytes of compressed public key (one for each of the 5 authorized signers)
  - `0x55` = `OP_5` (total number of keys)
  - `0xae` = `OP_CHECKMULTISIG`

  The choice of bare multisig (rather than P2SH or P2WSH wrapping) is consistent with the Bitcoin signet design, where the challenge is placed directly as the scriptPubKey of the `m_to_spend` output in the synthetic signing transaction pair. Bare multisig scripts can be verified by `VerifyScript` without any additional wrapping.

#### Testnet / Regtest (CAlphaTestNetParams / CAlphaRegTestParams) changes

The testnet and regtest constructors now accept `AlphaSignetForkOptions` alongside the existing `RegTestOptions`. The signet fork is **disabled by default** (height=0, empty challenge) unless the operator provides CLI args:

```
-signetforkheight=<n> -signetforkpubkeys=<hex1>,<hex2>,...
```

When provided, `BuildSignetChallenge()` constructs a 1-of-N bare multisig from the supplied compressed pubkeys and assigns the result to `consensus.signet_challenge`. This replaces the previous hardcoded `OP_TRUE` challenge, which allowed any block to pass post-fork validation -- making it impossible to test the actual signing/verification flow.

The `BuildSignetChallenge` helper (file-scope static in `kernel/chainparams.cpp`) uses `GetScriptForMultisig(1, pubkeys)` to produce the same script format as mainnet.

After initialization, the exact same `CheckSignetBlockSolution` code path runs for all chain types.

**Cross-references:**
- The `nSignetActivationHeight` value is read by `validation.cpp`, `pow.cpp`, `signet.cpp`, `node/miner.cpp`, and `init.cpp`.
- The `signet_challenge` bytes are read by `signet.cpp` (validation), `node/miner.cpp` (signing), and `init.cpp` (key validation at startup). This is the same field that BIP325 signet chains use, but on Alpha chains `signet_blocks=false` prevents the original BIP325 checker from consuming it.

---

### src/signet.h

**Role:** Public header declaring the `CheckSignetBlockSolution` function and the `SignetTxs` class. The `SignetTxs` class encapsulates the BIP325 synthetic transaction pair used both for signing (in `miner.cpp`) and for verification (in `signet.cpp` and `validation.cpp`). After the refactoring, this header also exports the `SIGNET_HEADER` constant and the `ExtractPubkeysFromChallenge` helper.

**Full path:** `/home/vrogojin/alpha/src/signet.h`

```diff
@@ -14,6 +14,9 @@
 #include <cstdint>
 #include <optional>

+/** Four-byte magic header used to locate the signet commitment in the coinbase witness commitment. */
+inline constexpr uint8_t SIGNET_HEADER[4] = {0xec, 0xc7, 0xda, 0xa2};
+
 /**
  * Extract signature and check whether a block has a valid solution
  */
 bool CheckSignetBlockSolution(const CBlock& block, const Consensus::Params& consensusParams);

+// !ALPHA SIGNET FORK
+/**
+ * Height-gated variant: check signet block solution only if height >= activation height.
+ * Uses consensus.signet_challenge (safe because signet_blocks=false on Alpha chains).
+ */
+bool CheckSignetBlockSolution(const CBlock& block, const Consensus::Params& consensusParams, int nHeight);
+
+/**
+ * Extract compressed pubkeys from a challenge script (e.g. bare multisig).
+ * Returns all valid 33-byte compressed pubkeys found as push data in the script.
+ */
+std::vector<CPubKey> ExtractPubkeysFromChallenge(const std::vector<uint8_t>& challenge);
+// !ALPHA SIGNET FORK END
+
 /**
  * Generate the signet tx corresponding to the given block
```

**Line-by-line explanation:**

- `inline constexpr uint8_t SIGNET_HEADER[4]` -- The four magic bytes are now exported from `signet.h` as an `inline constexpr` array. Moving the definition here makes it a single authoritative source shared by `signet.cpp`, `miner.cpp`, and any future consumer. The previous arrangement had `signet.cpp` defining it at file scope and `miner.cpp` redeclaring it as a local `static constexpr`, creating a silent duplication risk. The `inline` specifier (C++17) allows the definition to appear in a header included by multiple translation units without violating the One Definition Rule. The comment in `signet.cpp` now reads "SIGNET_HEADER is now defined in signet.h (inline constexpr)" to document the change.

- `bool CheckSignetBlockSolution(..., int nHeight)` -- A second overload of `CheckSignetBlockSolution` is declared, adding an `int nHeight` parameter. This overload is what every Alpha-specific call site uses. The original two-parameter version is left untouched to preserve compatibility with Bitcoin's signet chain type (the original version is called in `validation.cpp` for `signet_blocks` chains). The comment now reads "Uses consensus.signet_challenge (safe because signet_blocks=false on Alpha chains)" reflecting that no separate field is needed.

- `std::vector<CPubKey> ExtractPubkeysFromChallenge(const std::vector<uint8_t>& challenge)` -- Shared helper that decodes a challenge script and returns all valid 33-byte compressed public keys found within it. Used by `init.cpp` (startup key validation and logging) to avoid duplicating the opcode-iteration logic.

The two-overload distinction is critical: calling the wrong overload would either always enforce signet (if the original is called with the Alpha challenge) or bypass height-gating (if the new one is called without passing the block height). By making the height a required parameter of the new overload, call sites cannot accidentally omit it.

**Cross-references:**
- `CheckSignetBlockSolution` (3-arg) and `ExtractPubkeysFromChallenge` are both implemented in `src/signet.cpp`.
- `CheckSignetBlockSolution` (3-arg) is called from `src/validation.cpp` (two call sites: `ContextualCheckBlock` and `ConnectBlock`) and indirectly via `TestBlockValidity` in `src/node/miner.cpp`.
- `ExtractPubkeysFromChallenge` is called from `src/init.cpp` (startup key validation and logging).
- `SIGNET_HEADER` is used in `src/signet.cpp` (via `FetchAndClearCommitmentSection`) and in `src/node/miner.cpp` (when embedding the solution into the coinbase).

---

### src/signet.cpp

**Role:** Implements the BIP325 signet transaction pair construction (`SignetTxs::Create`) and the block solution checkers. After the refactoring, the file contains a new static helper `VerifySignetChallenge` that deduplicates the verification logic shared between the two-argument and three-argument `CheckSignetBlockSolution` overloads, and a new `ExtractPubkeysFromChallenge` helper for startup key validation.

**Full path:** `/home/vrogojin/alpha/src/signet.cpp`

```diff
-static constexpr uint8_t SIGNET_HEADER[4] = {0xec, 0xc7, 0xda, 0xa2};
+// SIGNET_HEADER is now defined in signet.h (inline constexpr)

+/**
+ * Shared verification kernel: constructs the signet transaction pair from the
+ * block and challenge, then verifies the script signature.
+ * Returns true if the block's signet signature satisfies the challenge.
+ */
+static bool VerifySignetChallenge(const CBlock& block, const std::vector<uint8_t>& challenge)
+{
+    const CScript script_challenge(challenge.begin(), challenge.end());
+    const std::optional<SignetTxs> signet_txs = SignetTxs::Create(block, script_challenge);
+
+    if (!signet_txs) {
+        LogPrint(BCLog::VALIDATION, "VerifySignetChallenge: SignetTxs::Create failed (parse error or missing witness commitment)\n");
+        return false;
+    }
+
+    const CScript& scriptSig = signet_txs->m_to_sign.vin[0].scriptSig;
+    const CScriptWitness& witness = signet_txs->m_to_sign.vin[0].scriptWitness;
+
+    PrecomputedTransactionData txdata;
+    txdata.Init(signet_txs->m_to_sign, {signet_txs->m_to_spend.vout[0]});
+    TransactionSignatureChecker sigcheck(&signet_txs->m_to_sign, /*nInIn=*/ 0,
+        /*amountIn=*/ signet_txs->m_to_spend.vout[0].nValue, txdata, MissingDataBehavior::ASSERT_FAIL);
+
+    return VerifyScript(scriptSig, signet_txs->m_to_spend.vout[0].scriptPubKey,
+        &witness, BLOCK_SCRIPT_VERIFY_FLAGS, sigcheck);
+}

 // Signet block solution checker (native BIP325 -- used when signet_blocks=true)
 bool CheckSignetBlockSolution(const CBlock& block, const Consensus::Params& consensusParams)
 {
     if (block.GetHash() == consensusParams.hashGenesisBlock) return true;
-    // ... inline VerifyScript logic ...
+    if (!VerifySignetChallenge(block, consensusParams.signet_challenge)) {
+        LogPrint(BCLog::VALIDATION, "CheckSignetBlockSolution: Errors in block (block solution invalid)\n");
+        return false;
+    }
+    return true;
 }

+// !ALPHA SIGNET FORK
+std::vector<CPubKey> ExtractPubkeysFromChallenge(const std::vector<uint8_t>& challenge) { ... }
+
+bool CheckSignetBlockSolution(const CBlock& block, const Consensus::Params& consensusParams, int nHeight)
+{
+    // Only enforce after activation height
+    if (consensusParams.nSignetActivationHeight <= 0 || nHeight < consensusParams.nSignetActivationHeight) {
+        return true;  // Pre-fork: no authorization required
+    }
+
+    if (consensusParams.signet_challenge.empty()) {
+        LogPrint(BCLog::VALIDATION, "CheckSignetBlockSolution (Alpha fork): no challenge configured at height %d\n", nHeight);
+        return false;
+    }
+
+    // Explicit SIGNET_HEADER check — reject blocks without it
+    if (block.vtx.empty()) return false;
+    const int cidx = GetWitnessCommitmentIndex(block);
+    if (cidx == NO_WITNESS_COMMITMENT) {
+        LogPrint(BCLog::VALIDATION, "CheckSignetBlockSolution (Alpha fork): no witness commitment at height %d\n", nHeight);
+        return false;
+    }
+    {
+        // Work on a copy — FetchAndClearCommitmentSection mutates its argument
+        CScript commitment_copy = block.vtx[0]->vout.at(cidx).scriptPubKey;
+        std::vector<uint8_t> dummy;
+        if (!FetchAndClearCommitmentSection(SIGNET_HEADER, commitment_copy, dummy)) {
+            LogPrint(BCLog::VALIDATION, "CheckSignetBlockSolution (Alpha fork): "
+                "missing SIGNET_HEADER at height %d\n", nHeight);
+            return false;
+        }
+    }
+
+    // Standard signet verification using shared helper
+    if (!VerifySignetChallenge(block, consensusParams.signet_challenge)) {
+        LogPrint(BCLog::VALIDATION, "CheckSignetBlockSolution (Alpha fork): invalid block solution at height %d\n", nHeight);
+        return false;
+    }
+    return true;
+}
+// !ALPHA SIGNET FORK END
```

**Line-by-line explanation:**

- **`SIGNET_HEADER` removal** -- The file-scope `static constexpr uint8_t SIGNET_HEADER[4]` definition (previously a live, uncommented definition) has been removed from `signet.cpp`. The constant is now obtained from the `signet.h` header via the `inline constexpr` definition. The comment at line 26 reads "SIGNET_HEADER is now defined in signet.h (inline constexpr)" to document this change.

- **`VerifySignetChallenge` static helper** -- A new `static bool VerifySignetChallenge(const CBlock& block, const std::vector<uint8_t>& challenge)` function deduplicates the shared verification kernel: `SignetTxs::Create` -> `PrecomputedTransactionData` -> `TransactionSignatureChecker` -> `VerifyScript`. This logic was previously written out inline in both the two-argument overload (for native BIP325 chains) and the three-argument overload (for Alpha). Extracting it into a shared static function means there is now a single place where the verification sequence is defined, reducing the risk of the two overloads diverging.

- **Two-argument overload** -- The original `CheckSignetBlockSolution(block, params)` now calls `VerifySignetChallenge(block, consensusParams.signet_challenge)` instead of containing inline verification code. The behavior is identical; only the structure has changed.

- **Height guard** in the three-argument overload (`nSignetActivationHeight <= 0 || nHeight < nSignetActivationHeight`) -- Returns `true` immediately for any block before the fork height. This is the single gate that makes the entire mechanism height-conditional. On chains where `nSignetActivationHeight` is zero (all non-Alpha chains), this always short-circuits.

- **Empty challenge guard** -- If `signet_challenge` is empty (fork disabled or not configured), returns `false` with a log message. This prevents silent pass-through on misconfigured chains.

- **Explicit SIGNET_HEADER check** -- Before calling `VerifySignetChallenge`, the function independently verifies that the coinbase witness commitment contains the `SIGNET_HEADER` magic bytes (`{0xec, 0xc7, 0xda, 0xa2}`). This closes the fragile implicit rejection path: previously, blocks missing the header relied on `VerifyScript` failing against a real multisig challenge (empty scriptSig fails multisig). The explicit check uses `FetchAndClearCommitmentSection` on a copy of the commitment script and rejects immediately if the header is absent, with a "missing SIGNET_HEADER" log message. Working on a copy is required because `FetchAndClearCommitmentSection` mutates its argument.

- **`VerifySignetChallenge(block, consensusParams.signet_challenge)`** -- The three-argument overload now uses `consensusParams.signet_challenge` (not a removed `signet_challenge_alpha` field). This is safe because all Alpha chain constructors set `signet_blocks = false`, which prevents the native BIP325 two-argument checker from running on Alpha chains.

- **`ExtractPubkeysFromChallenge`** -- New shared helper function (declared in `signet.h`, implemented in `signet.cpp`) that extracts all valid 33-byte compressed pubkeys from a challenge script by iterating its opcodes. Used by `init.cpp` (startup key validation, startup logging) to avoid code duplication.

- **`SignetTxs::Create(block, challenge)`** -- Called inside `VerifySignetChallenge`. This function:
  1. Creates a synthetic "to_spend" transaction with a single output whose `scriptPubKey` is the challenge script.
  2. Finds the witness commitment in the coinbase output.
  3. Searches the witness commitment for the `SIGNET_HEADER` (`{0xec, 0xc7, 0xda, 0xa2}`).
  4. Extracts and removes the signet solution bytes from the commitment.
  5. Deserializes those bytes as a `scriptSig` and witness stack into the "to_sign" spending transaction.
  6. Computes a modified Merkle root using the coinbase without the signet solution, and commits that root into the "to_spend" output's scriptSig.

  If any step fails (no witness commitment, extraneous data after the solution, deserialization error), `SignetTxs::Create` returns `std::nullopt` and `VerifySignetChallenge` returns `false`. For the three-argument overload, the explicit `SIGNET_HEADER` check that precedes the `VerifySignetChallenge` call guarantees that any block reaching this point already contains the header.

- **`VerifyScript` call** (inside `VerifySignetChallenge`) -- Runs the Script interpreter against the extracted `scriptSig` and witness using `BLOCK_SCRIPT_VERIFY_FLAGS`. These flags (defined at the top of `signet.cpp` as `SCRIPT_VERIFY_P2SH | SCRIPT_VERIFY_WITNESS | SCRIPT_VERIFY_DERSIG | SCRIPT_VERIFY_NULLDUMMY`) are the same flags used by the original `CheckSignetBlockSolution`. The `SCRIPT_VERIFY_NULLDUMMY` flag enforces the BIP147 rule that the mandatory dummy element in `OP_CHECKMULTISIG` must be an empty byte vector.

- **Logging** -- Uses `LogPrint(BCLog::VALIDATION, ...)` which only emits output when the `validation` debug category is enabled (`-debug=validation`). This matches the logging pattern in the original `CheckSignetBlockSolution` and avoids noisy output on nodes that are not actively debugging validation.

**Security implications:**

The three-argument overload is now structurally identical to the original `CheckSignetBlockSolution` in terms of verification logic (both delegate to `VerifySignetChallenge`), differing only in:
1. The height gate at the top.
2. Reading `signet_challenge` via the Alpha-safe path (guarded by `signet_blocks=false`).
3. The explicit `SIGNET_HEADER` pre-check before calling `VerifySignetChallenge`.
4. Including `nHeight` in log messages for better diagnostics.

By extracting `VerifySignetChallenge` as a shared helper, any future changes to the verification pipeline (e.g., new script flags) automatically apply to both the native BIP325 path and the Alpha height-gated path.

**Cross-references:**
- `SignetTxs::Create` is also called in `src/node/miner.cpp` during block template creation.
- The `SIGNET_HEADER` constant (`{0xec, 0xc7, 0xda, 0xa2}`) is now defined in `signet.h` and shared by both `signet.cpp` and `miner.cpp`.

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
- `<signet.h>` -- Provides `SignetTxs::Create`, `GetWitnessCommitmentIndex`, and the exported `SIGNET_HEADER` constant.
- `<streams.h>` -- Provides `VectorWriter`, used to serialize the signet solution into a byte vector.

```diff
+// !ALPHA SIGNET FORK
+CKey g_alpha_signet_key;
+// !ALPHA SIGNET FORK END
```

The global variable definition (corresponding to the `extern` declaration in `miner.h`). `CKey` has a default constructor that leaves the key in an invalid state (`IsValid()` returns `false`), so this initial state correctly represents "no key configured."

#### Fee burning: zero coinbase value post-fork

```diff
-    coinbaseTx.vout[0].nValue = nFees + GetBlockSubsidy(nHeight, chainparams.GetConsensus());
+    // !ALPHA SIGNET FORK - Burn transaction fees: coinbase value is 0 post-fork
+    if (g_isAlpha && chainparams.GetConsensus().nSignetActivationHeight > 0 &&
+        nHeight >= chainparams.GetConsensus().nSignetActivationHeight) {
+        coinbaseTx.vout[0].nValue = 0;
+    } else {
+        coinbaseTx.vout[0].nValue = nFees + GetBlockSubsidy(nHeight, chainparams.GetConsensus());
+    }
+    // !ALPHA SIGNET FORK END
```

This change ensures that the block template itself is created with a zero-value coinbase output post-fork, matching the `blockReward = 0` enforcement in `ConnectBlock`. The if/else structure preserves the original computation for pre-fork blocks. Post-fork, both the subsidy (already 0 via `GetBlockSubsidy`) and transaction fees are excluded from the coinbase output -- fees are effectively burned.

#### Block template signing

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
+        const CScript challenge(cparams.signet_challenge.begin(),
+                               cparams.signet_challenge.end());
+
+        int commitpos = GetWitnessCommitmentIndex(*pblock);
+        if (commitpos == NO_WITNESS_COMMITMENT) {
+            throw std::runtime_error(strprintf(
+                "%s: No witness commitment in block for signet signing at height %d", __func__, nHeight));
+        }
+
+        // Add an empty 4-byte SIGNET_HEADER placeholder to the coinbase
+        // witness commitment output BEFORE computing the signet merkle root.
+        // During verification, FetchAndClearCommitmentSection strips the
+        // solution but leaves this 4-byte placeholder, so the signing and
+        // verification merkle roots must both include it.
+        CScript savedScriptPubKey;
+        {
+            CMutableTransaction mtx(*pblock->vtx[0]);
+            savedScriptPubKey = mtx.vout[commitpos].scriptPubKey;
+            std::vector<uint8_t> empty_header(std::begin(SIGNET_HEADER), std::end(SIGNET_HEADER));
+            mtx.vout[commitpos].scriptPubKey << empty_header;
+            pblock->vtx[0] = MakeTransactionRef(std::move(mtx));
+        }
+
+        // Create the signet signing transaction pair
+        const std::optional<SignetTxs> signet_txs = SignetTxs::Create(*pblock, challenge);
+        if (!signet_txs) {
+            throw std::runtime_error(strprintf(
+                "%s: Failed to create signet transactions for signing at height %d", __func__, nHeight));
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
+            throw std::runtime_error(strprintf(
+                "%s: Failed to produce signet signature at height %d", __func__, nHeight));
+        }
+        UpdateInput(tx_signing.vin[0], sigdata);
+
+        // Serialize the signet solution: scriptSig || witness stack
+        std::vector<unsigned char> signet_solution;
+        VectorWriter writer{signet_solution, 0};
+        writer << tx_signing.vin[0].scriptSig;
+        writer << tx_signing.vin[0].scriptWitness.stack;
+
+        // Replace the placeholder with the full SIGNET_HEADER + solution.
+        // Restore the original scriptPubKey (without placeholder) then append
+        // the complete signet commitment pushdata.
+        CMutableTransaction mtx_coinbase(*pblock->vtx[0]);
+        mtx_coinbase.vout[commitpos].scriptPubKey = savedScriptPubKey;
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

1. **Guard check** -- `g_alpha_signet_key.IsValid()` is checked to catch calls from nodes that started without a signing key configured. Since the startup validation is silent when no key is configured (rather than requiring one to start), this guard ensures that any RPC caller requesting a block template receives a clear error message rather than producing an invalid block.

2. **Challenge construction** -- `cparams.signet_challenge` is the same field set in `chainparams.cpp` via `consensus.signet_challenge = ParseHex(...)`. Because `signet_blocks = false` on Alpha chains, the native BIP325 checker never reads this field; the signing code here is the only consumer on Alpha chains.

3. **SIGNET_HEADER placeholder** -- Before calling `SignetTxs::Create`, a 4-byte `SIGNET_HEADER` placeholder (with no solution data) is appended to the witness commitment output. This is critical for signing/verification agreement: during verification, `FetchAndClearCommitmentSection` strips pushdata sections whose data length exceeds 4 bytes (i.e., sections containing `SIGNET_HEADER` + solution), but leaves behind the 4-byte-only placeholder (since it only matches pushdata longer than the header). The Merkle root computed during signing must therefore include this placeholder, so that it matches the Merkle root computed during verification (after the solution is stripped but the placeholder remains).

4. **`SignetTxs::Create(*pblock, challenge)`** -- With the placeholder present, the block's coinbase has a witness commitment with the 4-byte `SIGNET_HEADER` push. `FetchAndClearCommitmentSection` does not match it (data length == header length, not greater), so `signet_solution` remains empty, and the signing transaction pair is constructed with an empty spending input. The resulting `signet_merkle` hash reflects the coinbase state with the placeholder -- matching what verification will compute.

5. **`FlatSigningProvider` setup** -- A minimal in-memory key store is constructed containing only the signing key. This is the correct approach because `ProduceSignature` is a generic signing function that works with any `SigningProvider`; using `FlatSigningProvider` with a single key avoids any wallet dependency.

6. **`ProduceSignature`** -- Generates a DER-encoded ECDSA signature using `SIGHASH_ALL`. For a 1-of-5 multisig challenge, `ProduceSignature` will construct a `scriptSig` of the form `OP_0 <sig>` (with the mandatory null dummy for `OP_CHECKMULTISIG`). The signature commits to the hash of the synthetic spending transaction, which itself commits to the modified Merkle root (block contents with the SIGNET_HEADER placeholder but without the signet solution).

7. **`UpdateInput`** -- Applies the generated `sigdata` back to `tx_signing.vin[0]`, populating `scriptSig` and `scriptWitness.stack`.

8. **Serialization** -- The signet solution format is: Bitcoin-serialized `scriptSig` followed by Bitcoin-serialized `scriptWitness.stack` (as a vector of vectors). Both are written using `VectorWriter` which produces the same wire encoding that `SpanReader` in `SignetTxs::Create` expects to read back during validation.

9. **Embedding into the coinbase** -- The original `scriptPubKey` (without the placeholder) is restored, then the `SIGNET_HEADER` (`{0xec, 0xc7, 0xda, 0xa2}`) is prepended to the solution bytes, and the combined byte array is appended as a push to the witness commitment output's `scriptPubKey`. The `<<` operator on `CScript` performs a minimal push, so the data will be pushed as an `OP_PUSHDATA` instruction of appropriate length. This is exactly the format that `FetchAndClearCommitmentSection` searches for: a push whose data begins with the 4-byte magic header and has data length > 4. During verification, `FetchAndClearCommitmentSection` strips this full push (header + solution) but leaves the 4-byte-only placeholder from step 3, ensuring the Merkle roots match.

10. **Merkle root recomputation** -- Modifying the coinbase transaction changes its hash, which changes the Merkle root. `BlockMerkleRoot(*pblock)` recomputes this. The nonce field is not re-initialized because the miner will overwrite it during PoW search anyway. The block template returned by `CreateNewBlock` still has `nNonce = 0`.

11. **`TestBlockValidity`** -- The existing call to `TestBlockValidity` at the end of `CreateNewBlock` (which runs after the signet block shown above) will now validate the signed template. This means `ContextualCheckBlock` (which calls `CheckSignetBlockSolution`) runs on the template before it is handed to the miner, providing early detection of any signing errors.

**Cross-references:**
- The `SIGNET_HEADER` constant is now sourced from `signet.h` (via the `#include <signet.h>` already present). The previous local `static constexpr uint8_t SIGNET_HEADER[4]` definition has been removed.
- The witness commitment index is found using `GetWitnessCommitmentIndex` from `<consensus/merkle.h>` (already included transitively).

---

### src/pow.cpp

**Role:** Implements `GetNextWorkRequired`, the function that computes the required difficulty (`nBits`) for the next block. Two changes are added: an explicit difficulty reset at the fork height, and a post-fork ASERT anchor re-base.

**Full path:** `/home/vrogojin/alpha/src/pow.cpp`

#### Change 1: Difficulty reset at fork height

```diff
+    // !ALPHA SIGNET FORK - Reset difficulty to powLimit at fork activation
+    if (g_isAlpha && params.nSignetActivationHeight > 0 && (pindexLast->nHeight + 1 == params.nSignetActivationHeight)) {
+        return nProofOfWorkLimit;
+    }
+    // !ALPHA SIGNET FORK END
```

This guard checks whether the block being computed (`pindexLast->nHeight + 1`) is exactly the activation height. When true, it returns `nProofOfWorkLimit` unconditionally. `nProofOfWorkLimit` is computed as `UintToArith256(params.powLimit).GetCompact()` at the start of `GetNextWorkRequired`. The `powLimit` for Alpha mainnet is defined as `uint256S("000fffff00000000000000000000000000000000000000000000000000000000")` in `chainparams.cpp` (note: the genesis block's `nBits` is `0x1d0fffff`, which is a different value used only for the genesis block).

Why a difficulty reset is necessary: In the weeks or months before block 450,000, mining activity on the Alpha mainnet is driven by economic incentive (the 5 ALPHA block subsidy post-halving at block 400,000). ASERT continuously adjusts difficulty to maintain the 2-minute target. At block 450,000, the subsidy drops to zero. If the only authorized block producers are the five keyholders and they are not running industrial mining equipment, they would be unable to find blocks at the difficulty level established by RandomX miners. The explicit reset to minimum difficulty ensures the first post-fork block can be produced essentially immediately, and ASERT then adjusts from there.

#### Change 2: Post-fork ASERT re-anchor at block 450,000

```diff
+            // !ALPHA SIGNET FORK - Use fork block as new ASERT anchor post-fork
+            // After the signet fork, ASERT must anchor from the fork block (which
+            // reset difficulty to powLimit) rather than the original anchor at
+            // block 70232, otherwise ASERT computes an astronomically high difficulty.
+            if (g_isAlpha && params.nSignetActivationHeight > 0 && pindexLast->nHeight + 1 > params.nSignetActivationHeight) {
+                const CBlockIndex* pForkBlock = pindexLast;
+                while (pForkBlock && pForkBlock->nHeight > params.nSignetActivationHeight) {
+                    pForkBlock = pForkBlock->pprev;
+                }
+                if (pForkBlock && pForkBlock->nHeight == params.nSignetActivationHeight) {
+                    const CBlockIndex* pForkPrev = pForkBlock->pprev;
+                    Consensus::Params::ASERTAnchor forkAnchor{
+                        params.nSignetActivationHeight,   // anchor height
+                        nProofOfWorkLimit,                // anchor nBits (powLimit)
+                        pForkPrev ? pForkPrev->GetBlockTime() : pForkBlock->GetBlockTime(),
+                    };
+                    return GetNextASERTWorkRequired(pindexLast, pblock, params, forkAnchor);
+                }
+            }
+            // !ALPHA SIGNET FORK END
```

After the difficulty reset at block 450,000, blocks 450,001 onward use a **new ASERT anchor at the fork block itself** rather than the original anchor from block 70,232. This is necessary because the time elapsed from block 70,232 to 450,000 (~264 days at 2-minute blocks) causes ASERT to compute an astronomically high difficulty when anchored at 70,232 with `nBits=powLimit`. The new anchor is constructed dynamically by walking back the chain index to the fork block:

- **Anchor height:** `nSignetActivationHeight` (450,000)
- **Anchor nBits:** `nProofOfWorkLimit` (matching the difficulty reset at the fork)
- **Anchor timestamp:** `pForkBlock->pprev->GetBlockTime()` (the previous block's timestamp, consistent with ASERT convention)

This code runs inside the ASERT activation check (within `if (params.asertAnchorParams)`) so it inherits all ASERT preconditions. The original `GetNextASERTWorkRequired(pindexLast, pblock, params, *params.asertAnchorParams)` call serves as the fallback for pre-fork blocks.

---

### src/validation.cpp

**Role:** The core block validation engine. Five distinct changes are made: a zero-subsidy enforcement in `GetBlockSubsidy`, a fee-burning override (`blockReward = 0`) in `ConnectBlock`, two calls to `CheckSignetBlockSolution` in the block connection pipeline, and the removal of the old "timebomb" forced shutdown at block 450,000.

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

After the zero subsidy, a second enforcement step burns transaction fees. In `ConnectBlock`, after computing `blockReward = nFees + GetBlockSubsidy(nHeight)` (which evaluates to `nFees + 0 = nFees`), the code forces `blockReward = 0` post-fork:

```cpp
// !ALPHA SIGNET FORK - Burn transaction fees: miner reward is 0 post-fork
if (g_isAlpha && params.GetConsensus().nSignetActivationHeight > 0 &&
    pindex->nHeight >= params.GetConsensus().nSignetActivationHeight) {
    blockReward = 0;
}
// !ALPHA SIGNET FORK END
```

This means post-fork coinbase outputs must sum to exactly 0. Any block with `coinbase.vout[0].nValue > 0` is rejected with `bad-cb-amount`. Transaction fees are effectively burned (destroyed) since no coinbase output can claim them. This removes the unfair competition advantage that authorized miners would otherwise have by collecting all fees.

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

### src/init.cpp

**Role:** Implements `AppInitMain`, the node startup function, and `SetupServerArgs`, which registers all command-line and config-file arguments. Two changes are made: registration of `-signetblockkey`, and startup validation of the configured key.

**Full path:** `/home/vrogojin/alpha/src/init.cpp`

#### New includes

```diff
+// !ALPHA SIGNET FORK
+#include <addresstype.h>
+#include <key.h>
+#include <key_io.h>
+#include <node/mining_thread.h>
+#include <script/script.h>
+#include <signet.h>
+// !ALPHA SIGNET FORK END
```

- `<addresstype.h>` -- For address type utilities used in mining address parsing.
- `<key.h>` -- For `CKey`, `CPubKey`, `CKeyID`.
- `<key_io.h>` -- For `DecodeSecret` (WIF decoder).
- `<node/mining_thread.h>` -- For `node::MiningContext`, the integrated mining thread interface.
- `<script/script.h>` -- For `CScript`, `opcodetype`, and `GetOp`.
- `<signet.h>` -- For `ExtractPubkeysFromChallenge` (shared helper for startup key validation).

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
+    // !ALPHA SIGNET FORK - Validate signing key at startup
+    // If -signetblockkey is provided, always validate it against the authorized
+    // pubkeys regardless of -server mode or current chain height. This ensures
+    // operators discover misconfiguration immediately, not when the fork activates.
+    // If -signetblockkey is not set, that is fine — the node simply will not
+    // produce blocks.
+    if (g_isAlpha && chainman.GetConsensus().nSignetActivationHeight > 0) {
+        const Consensus::Params& forkParams = chainman.GetConsensus();
+        const std::string strKey = args.GetArg("-signetblockkey", "");
+
+        if (!strKey.empty()) {
+            // ... key validation logic (WIF decode, pubkey derivation, allowlist check) ...
+        }
+    }
+    // !ALPHA SIGNET FORK END
```

**Line-by-line explanation:**

- The outer guard `g_isAlpha && nSignetActivationHeight > 0` ensures this code only runs on the Alpha chain where the signet fork is configured. There is no `-server` mode gate and no chain-height gate — if a key is provided, it is validated immediately regardless of node role or sync state.

- `if (!strKey.empty())` — validation only fires when `-signetblockkey` is explicitly set. If the argument is absent or empty, the node starts normally and simply will not produce blocks. No warning is logged for an absent key, since most nodes (peers, explorers, wallets) are not miners.

The key validation procedure when a key is provided:

1. **WIF decode** -- `DecodeSecret(strKey)` parses the WIF-encoded string into a `CKey` object. If the string is malformed (wrong checksum, wrong prefix, wrong length), `signingKey.IsValid()` returns `false` and startup fails with a descriptive error.

2. **Public key derivation** -- `signingKey.GetPubKey()` derives the compressed 33-byte public key. `VerifyPubKey(signingPubKey)` signs a test message and verifies it to confirm the key pair is internally consistent. This catches any implementation-level inconsistency.

3. **Allowlist check** -- The challenge is read from `forkParams.signet_challenge`. The shared `ExtractPubkeysFromChallenge(forkParams.signet_challenge)` helper (declared in `signet.h`, implemented in `signet.cpp`) iterates the script opcodes and returns all valid 33-byte compressed public keys. The startup code iterates the returned list; if any key matches `signingPubKey`, `keyAuthorized` is set to `true`. Each candidate key is validated with `CPubKey::IsFullyValid()` to skip any 33-byte push that is not an actual secp256k1 point (this is defensive, since the challenge script should always contain valid keys). If no match is found, startup fails with an error message that includes the derived public key hex and the count of authorized keys derived dynamically from the challenge (not hardcoded).

4. **Key storage** -- `g_alpha_signet_key = signingKey` stores the validated key in the global variable declared in `miner.h`. This is the only place in the codebase where `g_alpha_signet_key` is written.

5. **Logging** -- The first 16 hex characters of the public key are logged (8 bytes = 16 hex chars), sufficient for an operator to identify which key was loaded without revealing a meaningful fraction of the key material.

**Security implications of the allowlist check:**

The allowlist check at startup serves two purposes. First, it prevents misconfiguration: an operator who accidentally configures the wrong private key will see an immediate error rather than silently producing blocks that peers reject. Second, it provides a lightweight audit: a node operator can independently verify that their key is authorized by comparing the logged public key against the challenge script in chainparams. The check iterates the challenge script without executing it, which avoids any Script interpreter complexity at startup.

**Cross-references:**
- `g_alpha_signet_key` is written here and read in `src/node/miner.cpp`.
- `chainman.GetConsensus()` returns the same `Consensus::Params` configured in `src/kernel/chainparams.cpp`.

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
    |     - Output 0: scriptPubKeyIn (miner reward address, value = 0 post-fork; fees burned)
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
    +-- Check coinbase value <= blockReward (blockReward forced to 0 post-fork)
    |     GetBlockSubsidy returns 0 AND blockReward overridden to 0
    |     So coinbase value must be exactly 0 (fees burned)
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
    +-- If mainnet + CLI args set (-signetforkheight or -signetforkpubkeys):
    |     return InitError() — node refuses to start
    |
    +-- Load block index
    |
    v
    [ALPHA SIGNET FORK key validation]
    |
    +-- if not g_isAlpha or nSignetActivationHeight == 0: skip
    +-- if no -signetblockkey: no-op (node runs as non-mining full node)
    +-- if -signetblockkey provided: validate key against challenge
    |     - DecodeSecret(WIF) — fail on invalid format
    |     - GetPubKey() + VerifyPubKey() — fail on derivation error
    |     - ExtractPubkeysFromChallenge → check against allowlist — fail if not authorized
    |     (uses dynamic pubkey count in error msg)
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

**Key authorization:** The WIF key's corresponding public key must match one of the five public keys embedded in `consensus.signet_challenge` in `src/kernel/chainparams.cpp`. If it does not, the node refuses to start with the error:

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

The following deployment steps are tracked below. Steps marked DONE have been completed; remaining steps must be completed before the binary is released.

1. **~~Generate five key pairs.~~ DONE.** Five key pairs were generated using `scripts/generate_mainnet_keys.sh`. The private keys (WIF-encoded) are stored in `.env` (gitignored via `.gitignore`). The script uses a temporary Docker container running `alphad` on `chain=alpha` with a legacy wallet. To regenerate, run `bash scripts/generate_mainnet_keys.sh --force`.

2. **~~Replace placeholders in chainparams.cpp.~~ DONE.** The five compressed pubkeys have been deployed in `src/kernel/chainparams.cpp` (lines 168–177):
   - `02a86f4a1875e967435d9836df3dfba75fc84700af293ce487a99d6adb6f4ebecc`
   - `0234dae4ef312c640fa00f4d74048da77262224e506341b85f0b2a783c811bcef0`
   - `023602941d79d865ad32e88265feb101f3990a813d46b2fc01bc6601e9df7d69cc`
   - `024f12994fae223c07a2a802b9fa0cb8a1f5d24a7fedc40d3c2fad0a69574b2f9e`
   - `030934597b587069a9bb885782790eae0b16496e4863d0d6b7ad1ba0de0b078b3e`

   Validation: `test/e2e/mainnet_pubkey_e2e.sh` (Test 2) confirms the `.env` private key derives to the first hardcoded pubkey, and (Test 3) confirms block production works with these keys on `alpharegtest`.

3. **Verify the challenge script.** Decode the challenge script and verify that it correctly encodes a 1-of-5 bare multisig:
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

# Confirm getblocktemplate returns coinbasevalue: 0
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

### E2E Docker test suite (`test/e2e/signet_fork_e2e.sh`)

The primary integration test runs 20 tests across 7+ Docker containers on `alpharegtest`:

```bash
bash test/e2e/signet_fork_e2e.sh
```

The suite covers 9 phases: pre-fork mining, fork boundary, post-fork authorization, network agreement, transactions, partitions/reorgs, backward compatibility, external miner (minerd via getblocktemplate/submitblock), and integrated miner (`-mine` flag). Total: 59 assertions across 20 tests.

Prerequisites: Docker, `jq`, `bash 4+`. The script builds a Docker image from `docker/Dockerfile` (three-stage: alphad builder + alpha-miner builder + runtime image).

### Deployment-readiness test (`test/e2e/mainnet_pubkey_e2e.sh`)

Standalone test (not part of the 20-test suite) that validates deployment readiness:

```bash
bash test/e2e/mainnet_pubkey_e2e.sh
```

5 tests / 10 assertions:
1. `.env` validation — keys present and valid WIF format
2. Pubkey derivation — `.env` key derives to the hardcoded mainnet pubkey (uses `chain=alpha` container)
3. Block production — real pubkeys work on `alpharegtest` (uses `test/e2e/lib/wif_convert.py` to convert mainnet WIF to regtest WIF)
4. Mainnet rejection — `alphad` with `-signetforkheight` on mainnet exits with `InitError`
5. Wrong key rejected — unauthorized key fails startup with "NOT in the authorized allowlist"

Prerequisites: Docker, `jq`, `python3`, `bash 4+`, `.env` file (generated by `scripts/generate_mainnet_keys.sh`).

### Integrated mining (`-mine` flag)

The `-mine` flag enables continuous background mining via `src/node/mining_thread.{h,cpp}`:

```bash
alphad -chain=alpharegtest \
  -signetforkheight=10 \
  -signetforkpubkeys=$PUBKEY \
  -signetblockkey=$WIF \
  -mine=1 -mineaddress=$ADDR -minethreads=1
```

The node mines blocks automatically in the background using RandomX PoW. Test 20 in `signet_fork_e2e.sh` validates this mode. Configuration parameters: `-mine` (enable), `-mineaddress=<addr>` (coinbase address), `-minethreads=<n>` (thread count).

### External miner (minerd via getblocktemplate)

The `alpha-miner` (minerd) binary is built as part of the Docker image from `docker/Dockerfile`. It uses the standard `getblocktemplate` / `submitblock` RPC protocol. Test 19 in `signet_fork_e2e.sh` validates that the external miner can produce post-fork blocks when the signing key is configured on the `alphad` node.

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
5. Verify that `getblocktemplate` returns `coinbasevalue: 0` after block 10.
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
  - `GetBlockSubsidy` returns 0 (zero subsidy).
  - `blockReward` forced to 0 in `ConnectBlock` (fees burned).
  - `coinbaseTx.vout[0].nValue` set to 0 in `CreateNewBlock` (template compliance).
  - `GetNextWorkRequired` returns `powLimit` (difficulty reset).
  - `CheckSignetBlockSolution` requires a valid authorization signature.
  - The template for this block is produced by `CreateNewBlock` with the signing logic embedded.
- Block 450001+:
  - Subsidy remains 0, fees remain burned (`blockReward = 0`).
  - ASERT uses a new dynamic anchor at block 450,000 (nBits=powLimit, timestamp from block 449,999); difficulty stays near powLimit for post-fork blocks.
  - Authorization required.

### Open Issues

1. **~~CRITICAL: Placeholder pubkeys must be replaced.~~ FIXED.** Real compressed secp256k1 pubkeys have been deployed in `CAlphaMainParams`: `02a86f4a...`, `0234dae4...`, `02360294...`, `024f1299...`, `03093459...`. Key pairs generated by `scripts/generate_mainnet_keys.sh` and validated by `test/e2e/mainnet_pubkey_e2e.sh`.

2. **~~SIGNET_HEADER duplication~~ FIXED.** The constant `{0xec, 0xc7, 0xda, 0xa2}` is now defined once in `signet.h` as `inline constexpr uint8_t SIGNET_HEADER[4]` and shared by both `signet.cpp` and `miner.cpp`. The previous duplicate `static constexpr` definition in `miner.cpp` has been removed.

3. **~~`-server` as template-mode proxy~~ RESOLVED.** The startup key validation no longer gates on `-server` mode or chain height. If `-signetblockkey` is provided, the key is validated unconditionally at startup. If not provided, the node starts normally as a non-mining full node.

4. **~~Hardcoded "5" in error message~~ FIXED.** `init.cpp` now uses `ExtractPubkeysFromChallenge()` to derive the count dynamically from the challenge script.

5. **~~No unit tests for the new consensus rules~~ FIXED.** Comprehensive unit tests added in `src/test/alpha_signet_fork_tests.cpp` (8 test cases): subsidy boundary, fork-disabled guard, `ExtractPubkeysFromChallenge` helper, `CheckSignetBlockSolution` height gating, post-fork zero coinbase via `CreateNewBlock`, pre-fork normal subsidy, rejection of non-zero coinbase post-fork, and difficulty reset to `powLimit` at fork height. Tests use REGTEST (SHA256 PoW) with `g_isAlpha = true` and `const_cast` consensus params to set a low fork height, avoiding RandomX dependency.

6. **~~No integration / E2E tests~~ FIXED.** Comprehensive E2E Docker test suite added in `test/e2e/` (20 test cases across 7+ Docker containers on `alpharegtest`). Validates pre-fork mining, fork boundary activation, post-fork authorized/unauthorized mining, network partition and reorg, fee burning, single-input transaction restriction, wrong-key startup rejection, backward compatibility, consensus agreement, block template inspection, external miner (minerd) via getblocktemplate/submitblock, and integrated miner (`-mine` flag). Run with `bash test/e2e/signet_fork_e2e.sh`. Additionally, a standalone deployment-readiness test (`test/e2e/mainnet_pubkey_e2e.sh`, 5 tests / 10 assertions) validates `.env` key integrity, pubkey derivation against hardcoded mainnet pubkeys, block production with real keys, mainnet InitError on custom args, and wrong-key rejection.

---

---

## File Reference Summary

| File | Changes | Purpose |
|------|---------|---------|
| `src/consensus/params.h` | Added 1 new field (`nSignetActivationHeight`) to `struct Params` | Fork activation height; challenge stored in existing `signet_challenge` field |
| `src/kernel/chainparams.h` | Added `AlphaSignetForkOptions` struct, updated factory signatures | Configurable fork params for testnet/regtest |
| `src/kernel/chainparams.cpp` | Added `BuildSignetChallenge`, updated constructors to use `signet_challenge` | Configure fork parameters per chain; CLI-driven on test chains |
| `src/chainparams.cpp` | Added `ReadAlphaSignetForkArgs`, updated `CreateChainParams` dispatch | Parse `-signetforkheight`/`-signetforkpubkeys` CLI args |
| `src/chainparamsbase.cpp` | Registered `-signetforkheight` and `-signetforkpubkeys` | CLI arg registration |
| `src/signet.h` | Exported `SIGNET_HEADER` constant; added height-aware overload + `ExtractPubkeysFromChallenge` | Single source for SIGNET_HEADER; shared pubkey extraction helper |
| `src/signet.cpp` | Added `VerifySignetChallenge` static helper; removed local SIGNET_HEADER; uses `signet_challenge` | Deduplicated verification kernel; height-gated signet check with explicit header rejection |
| `src/validation.cpp` | 5 edits: zero subsidy, fee burning (`blockReward = 0`), timebomb removal, 2 signet checks | Core consensus enforcement |
| `src/pow.cpp` | 2 edits: difficulty reset at fork height + ASERT re-anchor post-fork | Prevent chain stall at fork; maintain stable difficulty post-fork |
| `src/node/miner.h` | Added global key declaration | `extern CKey g_alpha_signet_key` |
| `src/node/miner.cpp` | Added key definition + template signing logic with SIGNET_HEADER placeholder + fee burning (`coinbaseTx.vout[0].nValue = 0`); uses `signet_challenge`; removed local SIGNET_HEADER | Embed BIP325 signet solution in block templates; zero coinbase value post-fork |
| `src/init.cpp` | Startup logging, CLI warning, refactored key validation using `signet_challenge` | Log fork params, warn on mainnet CLI args, use shared helper |
| `src/test/alpha_signet_fork_tests.cpp` | New test file: 8 test cases for fork consensus rules | Unit tests for subsidy, fee burning, signet auth, difficulty reset, pubkey extraction |
| `src/Makefile.test.include` | Added `alpha_signet_fork_tests.cpp` to test source list | Register new test file |
| `src/node/mining_thread.h` | New: integrated mining interface | `node::MiningContext` struct with Start/Stop |
| `src/node/mining_thread.cpp` | New: integrated mining implementation | Background mining thread with RandomX PoW |
| `docker/Dockerfile` | New: three-stage Docker build (alphad builder + miner builder + runtime) | E2E test image with alphad and minerd |
| `scripts/generate_mainnet_keys.sh` | New: mainnet key generation script | Generates 5 key pairs, writes `.env`, prints pubkeys |
| `.gitignore` | Added `.env` and `.env.*` exclusion patterns | Keep signing keys out of git |
| `test/e2e/signet_fork_e2e.sh` | New: E2E test orchestration script (20 tests, 59 assertions) | Multi-node Docker integration tests for signet fork |
| `test/e2e/mainnet_pubkey_e2e.sh` | New: deployment-readiness test (5 tests, 10 assertions) | Validates .env keys, pubkey derivation, block production, mainnet rejection, wrong-key rejection |
| `test/e2e/lib/config.sh` | New: test constants and configuration | Ports, chain, colors, counters |
| `test/e2e/lib/docker_helpers.sh` | New: Docker operations + external miner | Image build, container start/stop, mesh connect, start/stop minerd |
| `test/e2e/lib/keygen.sh` | New: key generation via temp container | Generate 5 signing key pairs |
| `test/e2e/lib/node_helpers.sh` | New: RPC wrappers and sync utilities | cli(), sync_blocks(), mine_blocks(), connect/disconnect |
| `test/e2e/lib/assertions.sh` | New: test assertion functions | assert_eq, assert_ne, assert_gt, assert_ge, assert_contains, assert_fail |
| `test/e2e/lib/cleanup.sh` | New: teardown functions | Stop containers, remove network, cleanup temp files |
| `test/e2e/lib/wif_convert.py` | New: WIF network-version converter | Converts mainnet WIF (0x80) to regtest WIF (0xef) and back |

---

*Document updated: 2026-02-22. All code modifications are marked with `// !ALPHA SIGNET FORK` and `// !ALPHA SIGNET FORK END` comment delimiters.*

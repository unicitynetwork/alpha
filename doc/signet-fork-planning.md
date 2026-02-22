# Timebomb fork @ height 450000 — instructions for Claude (PLAN ONLY, NO IMPLEMENTATION)

> **CRITICAL: Claude MUST NOT IMPLEMENT ANYTHING.**
>
> Claude’s only job is to produce **comprehensive, manual code-editing instructions** (file-by-file, function-by-function) so that **I** can apply every change manually and verify it.
>
> - No patches / diffs / PRs
> - No “paste this code”
> - No autonomous refactors
> - Only: *where to edit, what to add, what to verify, and why*
>
> **Repeat:** Claude MUST NOT IMPLEMENT ANYTHING.

---

## Objective

At **block height 450000** (the “timebomb height”), our Bitcoin-based RandomX network must switch to a post-fork consensus regime:

1) **Set block subsidy to 0** (fees-only coinbase)
2) **Reset difficulty** (one-time adjustment) to prevent stalling when hashrate drops from ~200 MHz to near 0
3) **Enforce Signet-style block authorization** (only blocks authorized by our hardcoded allowlist are accepted)

This is a **consensus change / hard fork**. All nodes must upgrade before height 450000.

We already have **SegWit / witness commitments enabled**.

---

## Modes: full node vs block-producing template server

We have at least two operational modes:

- **Normal full node mode**: validates, relays, serves RPC, etc.  
  ✅ Must NOT require any mining private key. Must run normally without authorization key material.

- **Template-serving mode**: the node accepts `getblocktemplate`-like requests / builds block templates for miners/workers.  
  ✅ In this mode, post-fork templates **must** include authorization solution signatures.  
  ✅ Therefore, in this mode, the node must be able to sign using an authorized key.

**Claude must design the “startup key authorization invariant” to apply ONLY in template-serving mode.**

---

## Activation and boundary conditions

Let `H = 450000`.

- **Before H**:
  - Accept blocks as currently (RandomX PoW, normal subsidy schedule)
  - No Signet authorization required
- **At/after H** (`height >= H`):
  - `subsidy(height) = 0`
  - difficulty reset triggers at height H (one-time)
  - blocks must pass Signet-style authorization check against a hardcoded allowlist challenge

---

## Required deliverable from Claude

Claude must output a **manual implementation plan** including:

- exact code locations (files, functions) to inspect and edit
- specific height-gated logic changes required
- how to keep changes minimal and isolated
- testing plan + validation steps + reject reasons

> **Claude MUST NOT IMPLEMENT ANYTHING.** Only instructions.

---

## Workstream A — Subsidy becomes 0 at height 450000

### Goal
From height `>= 450000`, coinbase may only pay **transaction fees**.

### Minimal enforcement
Modify consensus subsidy function (likely `GetBlockSubsidy(height, ...)`):
- return 0 when `height >= H`
This naturally makes the existing “coinbase pays too much” check enforce fees-only.

### Claude must plan
- identify subsidy function + block reward enforcement site
- provide exact manual insertion point for height-gate

---

## Workstream B — Difficulty reset at height 450000 (avoid stall)

### Goal
At height H, perform a **one-time reset** to an easy target (typically `powLimit`) so blocks continue even with huge hashrate drop.

### Minimal strategy
In difficulty calculation (`GetNextWorkRequired` or equivalent):
- compute `nextHeight = pindexLast->nHeight + 1`
- if `nextHeight == H`: return min difficulty (powLimit compact)
- otherwise: normal rules

### Claude must plan
- identify difficulty function(s) for our RandomX fork
- choose the least invasive reset method (prefer `powLimit`)
- specify exactly how to encode the target into `nBits`
- describe reorg implications (any chain’s height H must obey reset)

---

## Workstream C — Enforce Signet-style block authorization at height 450000

### Goal
From `height >= H`, blocks must include a valid Signet/BIP325-style “solution” satisfying a **hardcoded allowlist challenge**.

### Minimal strategy
Reuse existing Signet verification logic if present (e.g., `CheckSignetBlockSolution`):
- do NOT enable signet globally from genesis
- add a height-gated call in a height-aware validation path (e.g., `ContextualCheckBlock`)

### Allowlist
Hardcode 5 authorized **pubkeys** in a single challenge script (recommended):
- 1-of-5 multisig challenge (or other script), stored in consensus params

### Claude must plan
- where to store challenge bytes in chainparams/consensus params
- where to add `if (height >= H) require CheckSignetBlockSolution(...)`
- what reject code/reason to use for unauthorized blocks
- mining/template implications (solution must be present in coinbase witness commitment optional data)

---

## NEW Workstream D — Startup key authorization invariant (template-serving mode only)

> **Claude MUST NOT IMPLEMENT ANYTHING.** This section is for Claude to produce a manual edit plan.

### Requirement
If (and only if) the node is started in **template-serving mode** (i.e., it will build templates for miners), then:

- the node must have access to a private key that corresponds to **one of the 5 authorized hardcoded pubkeys**
- if it does not, the node must **terminate immediately** with a clear fatal error
- in normal full node mode, the node must run without any mining key and must NOT perform this invariant check

### Define “template-serving mode”
Claude must determine how our node currently enables template serving, for example:
- RPC server enabled + `getblocktemplate` exposed
- a dedicated `-mining` / `-server` / `-rpc` flag set
- a pool mode flag
- any existing “miner support” configuration

Claude must propose a precise trigger condition, e.g.:
- `if (IsRPCEnabled && IsTemplateRPCEnabled && !-disablegbt)` OR
- `if (-templatemode=1)` (if we add a flag)  
but Claude should prefer using **existing** flags/structure if possible.

### What must be checked at startup
In template-serving mode only:

1) Obtain the configured “mining signing key” material (see Workstream E below).
2) Derive pubkey (compressed/uncompressed rules must be clear).
3) Compare against hardcoded allowlist pubkeys.
4) If no match:
   - log a fatal message stating:
     - node is in template-serving mode
     - configured key is not authorized
     - list the authorized pubkey fingerprints (not full keys, if you prefer)
   - then exit via controlled fatal path (AbortNode / InitError / exception), not a segfault.

### Also required: runtime/template-time safety
Even with startup checks, if template signing fails later (HSM down, wallet locked, key missing):
- template creation at/after height H must hard-fail (do not serve unsigned templates)

Claude must include both layers in the plan:
- startup invariant (mode-gated)
- template generation hard-fail post-fork

---

## NEW Workstream E — How the node should be provided the signing private key (plan options)

We want minimal changes, but also predictable ops. Claude must evaluate these options and recommend one, with pros/cons and exact manual steps.

> Claude MUST NOT IMPLEMENT ANYTHING. Only provide instructions for me.

### Option 1 (recommended for clarity): dedicated config parameter for mining signing key
Example (conceptual): `-miningsignkey=<WIF/hex/descriptor>` or `-miningsignkeyfile=...`

Pros:
- explicit: avoids ambiguity between “wallet has key” vs “this is the mining signer”
- easier to enforce allowlist match at startup
- can work without a loaded wallet if desired

Cons:
- adds a new configuration surface (small code change)

Claude must plan:
- where to parse/store this option
- how to keep it secure (permissions, avoid logging secrets)
- how to derive pubkey reliably

### Option 2: use the standard wallet (loadwallet) mechanism
Node obtains the signing key from a loaded wallet.

Typical sub-variants:
- **A)** “coinbase destination address” belongs to wallet, and node picks that key as signer
- **B)** explicit “mining address” config, and wallet must contain its privkey
- **C)** descriptor wallet: pick key from descriptor

Pros:
- no new secret storage format if you already manage wallet securely
- can integrate with existing encryption/locking flows

Cons / gotchas (Claude must address explicitly):
- wallet may be absent on some nodes (full validation nodes)
- wallet could be locked (signing fails)
- ambiguous key selection if wallet has many keys
- using “address” is encoding-dependent; consensus allowlist should be pubkeys

If you choose wallet-based:
- Claude must specify a deterministic way to select *the* signing key, not “first key found”.
- Claude must define behavior when wallet is locked:
  - fail startup in template-serving mode OR
  - require `-walletpassphrase` usage / operator procedure (no silent fallback)

### Option 3: external signer / HSM via a thin node-side interface
Node calls an external signer (HSM or local signing daemon) when building templates.

Pros:
- private key not resident in node memory/disk
- operationally aligns with HSM policies

Cons:
- more plumbing; may be more than “minimal”
- adds dependencies and failure modes

If considered:
- Claude must keep plan minimal (reuse existing signer interface if already present)
- must still satisfy startup invariant (connectivity / pubkey check)

### Required outcome
Claude must recommend **one default** approach (likely Option 1 or Option 2), and also describe fallback options.

---

## Integration notes (all workstreams)

At `height >= H`:
- difficulty reset impacts `nBits` at height H
- subsidy=0 impacts coinbase max payout
- authorization required impacts validation AND template construction

Claude must ensure the plan includes how miners will succeed in producing the first post-fork block:
- template must already contain authorization solution
- template must already use fees-only coinbase
- template must already use reset difficulty at height H

---

## Testing plan (Claude must describe, not implement)

Boundary tests:
- height H-1 block: old rules OK
- height H block: must satisfy all three new rules (subsidy 0, reset difficulty, authorization)
- height H+1 block: subsidy 0 + authorization; difficulty returns to normal algorithm (unless specified)

Reorg tests:
- competing branches around H, ensure height-based rules apply per-branch

Template tests:
- in template-serving mode:
  - startup fails if signing key not authorized
  - template generation at/after H fails if signing fails
- in normal full node mode:
  - node starts and runs without any mining key

---

## Repeated critical instruction

**Claude MUST NOT IMPLEMENT ANYTHING.**  
Claude must only generate a comprehensive, manual code-editing plan.

---

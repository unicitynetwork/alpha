// Copyright (c) 2024 The Unicity developers
// Distributed under the MIT software license, see the accompanying
// file COPYING or http://www.opensource.org/licenses/mit-license.php.

//
// Unit tests for Alpha signet fork consensus rules (activation at height N):
//   - Zero block subsidy post-fork
//   - Fee burning (coinbase value = 0)
//   - Signet block authorization (CheckSignetBlockSolution height-gated)
//   - Difficulty reset at fork height
//   - ExtractPubkeysFromChallenge helper
//

#include <chainparams.h>
#include <consensus/amount.h>
#include <consensus/merkle.h>
#include <consensus/params.h>
#include <key.h>
#include <node/miner.h>
#include <pow.h>
#include <primitives/block.h>
#include <script/solver.h>
#include <signet.h>
#include <test/util/random.h>
#include <test/util/setup_common.h>
#include <validation.h>

#include <boost/test/unit_test.hpp>

using node::BlockAssembler;
using node::CBlockTemplate;

namespace alpha_signet_fork_tests {

// ---------------------------------------------------------------------------
// Test fixture: REGTEST chain with g_isAlpha + signet fork configured
// ---------------------------------------------------------------------------
struct AlphaForkTestSetup : public TestingSetup {
    // Saved state for teardown
    bool m_saved_g_isAlpha;
    int m_saved_nSignetActivationHeight;
    std::vector<uint8_t> m_saved_signet_challenge;
    CKey m_saved_alpha_signet_key;
    int m_saved_RandomXHeight;
    int m_saved_RandomXEnforcementHeight;
    uint32_t m_saved_RandomX_DiffMult;

    // Test key and fork config
    CKey m_testKey;
    static constexpr int FORK_HEIGHT = 5;

    AlphaForkTestSetup() : TestingSetup(ChainType::REGTEST)
    {
        // Save global state
        m_saved_g_isAlpha = g_isAlpha;
        m_saved_alpha_signet_key = g_alpha_signet_key;

        // Generate test signing key
        m_testKey.MakeNewKey(/*fCompressed=*/true);

        // Build 1-of-1 multisig challenge with test key
        CScript challenge = GetScriptForMultisig(1, {m_testKey.GetPubKey()});
        std::vector<uint8_t> challenge_bytes(challenge.begin(), challenge.end());

        // Modify consensus params via const_cast (test-only pattern, see miner_tests.cpp)
        auto& mutableConsensus = const_cast<Consensus::Params&>(
            m_node.chainman->GetConsensus());
        m_saved_nSignetActivationHeight = mutableConsensus.nSignetActivationHeight;
        m_saved_signet_challenge = mutableConsensus.signet_challenge;
        m_saved_RandomXHeight = mutableConsensus.RandomXHeight;
        m_saved_RandomXEnforcementHeight = mutableConsensus.RandomXEnforcementHeight;
        m_saved_RandomX_DiffMult = mutableConsensus.RandomX_DiffMult;
        mutableConsensus.nSignetActivationHeight = FORK_HEIGHT;
        mutableConsensus.signet_challenge = challenge_bytes;
        // Set RandomX params to safe values so g_isAlpha checks don't hit
        // uninitialized fields on REGTEST
        mutableConsensus.RandomXHeight = 99999;
        mutableConsensus.RandomXEnforcementHeight = 99999;
        mutableConsensus.RandomX_DiffMult = 1;

        // Set globals
        g_isAlpha = true;
        g_alpha_signet_key = m_testKey;
    }

    ~AlphaForkTestSetup()
    {
        // Restore everything
        auto& mutableConsensus = const_cast<Consensus::Params&>(
            m_node.chainman->GetConsensus());
        mutableConsensus.nSignetActivationHeight = m_saved_nSignetActivationHeight;
        mutableConsensus.signet_challenge = m_saved_signet_challenge;
        mutableConsensus.RandomXHeight = m_saved_RandomXHeight;
        mutableConsensus.RandomXEnforcementHeight = m_saved_RandomXEnforcementHeight;
        mutableConsensus.RandomX_DiffMult = m_saved_RandomX_DiffMult;
        g_isAlpha = m_saved_g_isAlpha;
        g_alpha_signet_key = m_saved_alpha_signet_key;
    }

    /** Mine a single block on the active chain using SHA256 PoW (REGTEST).
     *  Pre-fork: CreateNewBlock doesn't sign (signet guard returns early).
     *  Post-fork: CreateNewBlock signs with g_alpha_signet_key, sets coinbase = 0.
     */
    CBlock MineBlock(const CScript& scriptPubKey)
    {
        auto& chainstate = m_node.chainman->ActiveChainstate();
        auto tmpl = BlockAssembler{chainstate, nullptr}.CreateNewBlock(scriptPubKey);
        CBlock& block = tmpl->block;
        // Compute merkle root (CreateNewBlock only sets it for post-fork signed blocks)
        block.hashMerkleRoot = BlockMerkleRoot(block);
        // Find valid SHA256 nonce (trivial on REGTEST with powLimit ~= 2^255)
        while (!CheckProofOfWork(block.GetHash(), block.nBits,
                                 m_node.chainman->GetConsensus()))
            ++block.nNonce;
        auto shared = std::make_shared<const CBlock>(block);
        bool accepted = Assert(m_node.chainman)->ProcessNewBlock(shared, /*force_processing=*/true, /*min_pow_checked=*/true, /*new_block=*/nullptr);
        BOOST_REQUIRE_MESSAGE(accepted, "MineBlock: ProcessNewBlock failed at height " +
            std::to_string(m_node.chainman->ActiveChain().Height() + 1));
        return block;
    }
};

BOOST_FIXTURE_TEST_SUITE(alpha_signet_fork_tests, AlphaForkTestSetup)

// ---------------------------------------------------------------------------
// 1. GetBlockSubsidy at fork boundary
// ---------------------------------------------------------------------------
BOOST_AUTO_TEST_CASE(alpha_subsidy_boundary)
{
    const auto& params = m_node.chainman->GetConsensus();

    // Pre-fork: Alpha base subsidy = 10 COIN
    BOOST_CHECK_EQUAL(GetBlockSubsidy(0, params), 10 * COIN);
    BOOST_CHECK_EQUAL(GetBlockSubsidy(FORK_HEIGHT - 1, params), 10 * COIN);

    // At fork: zero subsidy
    BOOST_CHECK_EQUAL(GetBlockSubsidy(FORK_HEIGHT, params), 0);

    // Post-fork: still zero
    BOOST_CHECK_EQUAL(GetBlockSubsidy(FORK_HEIGHT + 1, params), 0);
    BOOST_CHECK_EQUAL(GetBlockSubsidy(FORK_HEIGHT + 1000, params), 0);
}

// ---------------------------------------------------------------------------
// 2. Fork disabled when nSignetActivationHeight == 0
// ---------------------------------------------------------------------------
BOOST_AUTO_TEST_CASE(alpha_subsidy_disabled_when_height_zero)
{
    auto& mutableConsensus = const_cast<Consensus::Params&>(
        m_node.chainman->GetConsensus());
    int saved = mutableConsensus.nSignetActivationHeight;
    mutableConsensus.nSignetActivationHeight = 0;

    // With fork disabled, subsidy is always the Alpha base (10 COIN)
    BOOST_CHECK_EQUAL(GetBlockSubsidy(0, mutableConsensus), 10 * COIN);
    BOOST_CHECK_EQUAL(GetBlockSubsidy(FORK_HEIGHT, mutableConsensus), 10 * COIN);
    BOOST_CHECK_EQUAL(GetBlockSubsidy(FORK_HEIGHT + 1000, mutableConsensus), 10 * COIN);

    mutableConsensus.nSignetActivationHeight = saved;
}

// ---------------------------------------------------------------------------
// 3. ExtractPubkeysFromChallenge helper
// ---------------------------------------------------------------------------
BOOST_AUTO_TEST_CASE(alpha_extract_pubkeys)
{
    // 1-of-1 multisig: returns 1 key matching the input
    {
        CKey key;
        key.MakeNewKey(true);
        CScript script = GetScriptForMultisig(1, {key.GetPubKey()});
        std::vector<uint8_t> challenge(script.begin(), script.end());
        auto keys = ExtractPubkeysFromChallenge(challenge);
        BOOST_CHECK_EQUAL(keys.size(), 1U);
        BOOST_CHECK(keys[0] == key.GetPubKey());
    }

    // 1-of-3 multisig: returns 3 keys
    {
        CKey k1, k2, k3;
        k1.MakeNewKey(true);
        k2.MakeNewKey(true);
        k3.MakeNewKey(true);
        CScript script = GetScriptForMultisig(1, {k1.GetPubKey(), k2.GetPubKey(), k3.GetPubKey()});
        std::vector<uint8_t> challenge(script.begin(), script.end());
        auto keys = ExtractPubkeysFromChallenge(challenge);
        BOOST_CHECK_EQUAL(keys.size(), 3U);
    }

    // Empty script: returns empty vector
    {
        std::vector<uint8_t> challenge;
        auto keys = ExtractPubkeysFromChallenge(challenge);
        BOOST_CHECK(keys.empty());
    }

    // OP_TRUE only (no valid 33-byte pushes): returns empty
    {
        CScript script;
        script << OP_TRUE;
        std::vector<uint8_t> challenge(script.begin(), script.end());
        auto keys = ExtractPubkeysFromChallenge(challenge);
        BOOST_CHECK(keys.empty());
    }

    // Bare compressed pubkey push (non-multisig): returns the key
    {
        CKey key;
        key.MakeNewKey(true);
        CScript script;
        script << ToByteVector(key.GetPubKey());
        std::vector<uint8_t> challenge(script.begin(), script.end());
        auto keys = ExtractPubkeysFromChallenge(challenge);
        BOOST_CHECK_EQUAL(keys.size(), 1U);
        BOOST_CHECK(keys[0] == key.GetPubKey());
    }
}

// ---------------------------------------------------------------------------
// 4. CheckSignetBlockSolution height gating
// ---------------------------------------------------------------------------
BOOST_AUTO_TEST_CASE(alpha_signet_check_height_gating)
{
    const auto& params = m_node.chainman->GetConsensus();
    CBlock block; // empty block, no signet commitment

    // Pre-fork heights: returns true regardless of block content
    BOOST_CHECK(CheckSignetBlockSolution(block, params, 0));
    BOOST_CHECK(CheckSignetBlockSolution(block, params, FORK_HEIGHT - 1));

    // Post-fork with empty block (no coinbase → no SIGNET_HEADER): returns false
    BOOST_CHECK(!CheckSignetBlockSolution(block, params, FORK_HEIGHT));
    BOOST_CHECK(!CheckSignetBlockSolution(block, params, FORK_HEIGHT + 1));

    // Post-fork with empty challenge: returns false
    {
        auto& mutableConsensus = const_cast<Consensus::Params&>(params);
        auto saved_challenge = mutableConsensus.signet_challenge;
        mutableConsensus.signet_challenge.clear();
        BOOST_CHECK(!CheckSignetBlockSolution(block, params, FORK_HEIGHT));
        mutableConsensus.signet_challenge = saved_challenge;
    }
}

// ---------------------------------------------------------------------------
// 5. Block template produces zero coinbase at fork height
// ---------------------------------------------------------------------------
BOOST_AUTO_TEST_CASE(alpha_coinbase_value_post_fork)
{
    CScript scriptPubKey = CScript() << OP_TRUE;

    // Mine blocks up to FORK_HEIGHT - 2 (heights 1 through FORK_HEIGHT-2)
    // so the chain tip is at FORK_HEIGHT - 2.
    // Pre-fork: no signet signature needed, standard SHA256 PoW.
    for (int i = 1; i <= FORK_HEIGHT - 2; ++i) {
        MineBlock(scriptPubKey);
    }
    BOOST_CHECK_EQUAL(m_node.chainman->ActiveChain().Height(), FORK_HEIGHT - 2);

    // Now mine one more block at FORK_HEIGHT - 1 (still pre-fork)
    MineBlock(scriptPubKey);
    BOOST_CHECK_EQUAL(m_node.chainman->ActiveChain().Height(), FORK_HEIGHT - 1);

    // Create template for FORK_HEIGHT (post-fork)
    auto& chainstate = m_node.chainman->ActiveChainstate();
    auto tmpl = BlockAssembler{chainstate, nullptr}.CreateNewBlock(scriptPubKey);

    // Coinbase value should be 0 post-fork
    BOOST_CHECK_EQUAL(tmpl->block.vtx[0]->vout[0].nValue, 0);
}

// ---------------------------------------------------------------------------
// 6. Block template has normal subsidy pre-fork
// ---------------------------------------------------------------------------
BOOST_AUTO_TEST_CASE(alpha_coinbase_value_pre_fork)
{
    CScript scriptPubKey = CScript() << OP_TRUE;

    // At genesis (height 0), create template for height 1 (pre-fork)
    BOOST_CHECK_EQUAL(m_node.chainman->ActiveChain().Height(), 0);

    auto& chainstate = m_node.chainman->ActiveChainstate();
    auto tmpl = BlockAssembler{chainstate, nullptr}.CreateNewBlock(scriptPubKey);

    // Coinbase value for height 1: nFees(0) + GetBlockSubsidy(1, params) = 10 COIN
    const auto& params = m_node.chainman->GetConsensus();
    CAmount expected = GetBlockSubsidy(1, params);
    BOOST_CHECK_EQUAL(expected, 10 * COIN);
    BOOST_CHECK_EQUAL(tmpl->block.vtx[0]->vout[0].nValue, expected);
}

// ---------------------------------------------------------------------------
// 7. Post-fork: block with non-zero coinbase is rejected
// ---------------------------------------------------------------------------
BOOST_AUTO_TEST_CASE(alpha_fee_burning_rejects_nonzero_coinbase)
{
    CScript scriptPubKey = CScript() << OP_TRUE;

    // Mine up to FORK_HEIGHT - 1
    for (int i = 1; i <= FORK_HEIGHT - 1; ++i) {
        MineBlock(scriptPubKey);
    }
    BOOST_CHECK_EQUAL(m_node.chainman->ActiveChain().Height(), FORK_HEIGHT - 1);

    // Create a valid signed template at FORK_HEIGHT (coinbase = 0)
    auto& chainstate = m_node.chainman->ActiveChainstate();
    auto tmpl = BlockAssembler{chainstate, nullptr}.CreateNewBlock(scriptPubKey);
    CBlock block = tmpl->block;

    // Verify the template has coinbase = 0
    BOOST_CHECK_EQUAL(block.vtx[0]->vout[0].nValue, 0);

    // Modify coinbase to nValue = 1 (non-zero)
    CMutableTransaction mtx(*block.vtx[0]);
    mtx.vout[0].nValue = 1;
    block.vtx[0] = MakeTransactionRef(std::move(mtx));

    // Recompute merkle root
    block.hashMerkleRoot = BlockMerkleRoot(block);

    // Find valid SHA256 nonce
    while (!CheckProofOfWork(block.GetHash(), block.nBits,
                             m_node.chainman->GetConsensus()))
        ++block.nNonce;

    // ProcessNewBlock should reject this block
    // (either bad-alpha-blksig because merkle root changed invalidates signet signature,
    //  or bad-cb-amount because coinbase > 0 when blockReward == 0)
    auto shared = std::make_shared<const CBlock>(block);
    bool new_block = false;
    bool accepted = m_node.chainman->ProcessNewBlock(shared, /*force_processing=*/true, /*min_pow_checked=*/true, &new_block);
    // The block should not become the new tip
    BOOST_CHECK_EQUAL(m_node.chainman->ActiveChain().Height(), FORK_HEIGHT - 1);
}

// ---------------------------------------------------------------------------
// 8. Difficulty reset to powLimit at fork height
// ---------------------------------------------------------------------------
BOOST_AUTO_TEST_CASE(alpha_difficulty_reset)
{
    const auto& params = m_node.chainman->GetConsensus();
    unsigned int nProofOfWorkLimit = UintToArith256(params.powLimit).GetCompact();

    // Build a dummy CBlockIndex chain up to FORK_HEIGHT - 1
    // (same pattern as miner_tests.cpp for subsidy changing test)
    int nHeight = m_node.chainman->ActiveChain().Height();
    while (m_node.chainman->ActiveChain().Tip()->nHeight < FORK_HEIGHT - 1) {
        CBlockIndex* prev = m_node.chainman->ActiveChain().Tip();
        CBlockIndex* next = new CBlockIndex();
        next->phashBlock = new uint256(InsecureRand256());
        m_node.chainman->ActiveChainstate().CoinsTip().SetBestBlock(next->GetBlockHash());
        next->pprev = prev;
        next->nHeight = prev->nHeight + 1;
        next->nBits = nProofOfWorkLimit; // set nBits for consistency
        next->nTime = prev->nTime + params.nPowTargetSpacing;
        next->BuildSkip();
        m_node.chainman->ActiveChain().SetTip(*next);
    }

    BOOST_CHECK_EQUAL(m_node.chainman->ActiveChain().Tip()->nHeight, FORK_HEIGHT - 1);

    // GetNextWorkRequired for the next block (height = FORK_HEIGHT) should return powLimit
    CBlockHeader header;
    header.nTime = m_node.chainman->ActiveChain().Tip()->nTime + params.nPowTargetSpacing;
    unsigned int nextBits = GetNextWorkRequired(
        m_node.chainman->ActiveChain().Tip(), &header, params);
    BOOST_CHECK_EQUAL(nextBits, nProofOfWorkLimit);

    // Cleanup: remove dummy blocks
    while (m_node.chainman->ActiveChain().Tip()->nHeight > nHeight) {
        CBlockIndex* del = m_node.chainman->ActiveChain().Tip();
        m_node.chainman->ActiveChain().SetTip(*Assert(del->pprev));
        m_node.chainman->ActiveChainstate().CoinsTip().SetBestBlock(del->pprev->GetBlockHash());
        delete del->phashBlock;
        delete del;
    }
}

BOOST_AUTO_TEST_SUITE_END()

} // namespace alpha_signet_fork_tests

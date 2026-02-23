// Copyright (c) 2024 The Unicity developers
// Distributed under the MIT software license, see the accompanying
// file COPYING or http://www.opensource.org/licenses/mit-license.php.

#include <node/mining_thread.h>

#include <consensus/merkle.h>
#include <logging.h>
#include <node/miner.h>
#include <pow.h>
#include <util/threadnames.h>
#include <validation.h>

namespace node {

static void MinerThread(ChainstateManager& chainman,
                        const CTxMemPool& mempool,
                        const CScript& coinbase_script,
                        MiningContext& ctx,
                        int thread_id)
{
    util::ThreadRename(strprintf("miner-%d", thread_id));
    LogPrintf("Mining thread %d started\n", thread_id);

    while (!ctx.shutdown_requested) {
        try {
            // Snapshot the current tip before creating a template.
            uint256 tip_hash;
            {
                LOCK(cs_main);
                const CBlockIndex* tip = chainman.ActiveChain().Tip();
                tip_hash = tip ? tip->GetBlockHash() : uint256();
            }

            std::unique_ptr<CBlockTemplate> tmpl;
            try {
                tmpl = BlockAssembler{chainman.ActiveChainstate(), &mempool}
                           .CreateNewBlock(coinbase_script);
            } catch (const std::exception& e) {
                LogPrintf("Mining thread %d: CreateNewBlock failed: %s\n", thread_id, e.what());
                std::this_thread::sleep_for(std::chrono::seconds(5));
                continue;
            }

            if (!tmpl) {
                std::this_thread::sleep_for(std::chrono::seconds(1));
                continue;
            }

            CBlock& block = tmpl->block;
            block.hashMerkleRoot = BlockMerkleRoot(block);

            uint64_t max_tries = 1000000;
            uint64_t tries_since_tip_check = 0;
            uint256 rxHash;
            rxHash.SetNull();
            bool tip_changed = false;

            while (max_tries > 0 && !ctx.shutdown_requested &&
                   block.nNonce < std::numeric_limits<uint32_t>::max() &&
                   !CheckProofOfWorkRandomX(block, chainman.GetConsensus(),
                                            POW_VERIFY_MINING, &rxHash)) {
                ++block.nNonce;
                --max_tries;
                ++tries_since_tip_check;

                // Periodically check if the chain tip changed (e.g. from
                // syncing blocks from peers).  If so, abandon this stale
                // template and create a new one from the updated tip.
                if (tries_since_tip_check >= 1000) {
                    tries_since_tip_check = 0;
                    LOCK(cs_main);
                    const CBlockIndex* current_tip = chainman.ActiveChain().Tip();
                    uint256 current_hash = current_tip ? current_tip->GetBlockHash() : uint256();
                    if (current_hash != tip_hash) {
                        LogPrintf("Mining thread %d: tip changed, restarting with new template\n", thread_id);
                        tip_changed = true;
                        break;
                    }
                }
            }

            if (ctx.shutdown_requested) break;
            if (tip_changed) continue;

            if (max_tries == 0 || block.nNonce == std::numeric_limits<uint32_t>::max()) {
                // Exhausted nonce space or tries; get new template
                continue;
            }

            block.hashRandomX = rxHash;
            auto shared_block = std::make_shared<const CBlock>(block);

            bool new_block = false;
            if (chainman.ProcessNewBlock(shared_block, /*force_processing=*/true,
                                         /*min_pow_checked=*/true, &new_block)) {
                if (new_block) {
                    ctx.blocks_mined++;
                    LogPrintf("Mined block %s (thread %d, total %lu)\n",
                              shared_block->GetHash().GetHex(), thread_id,
                              ctx.blocks_mined.load());
                }
            }
        } catch (const std::exception& e) {
            LogPrintf("Mining thread %d error: %s\n", thread_id, e.what());
            std::this_thread::sleep_for(std::chrono::seconds(5));
        }
    }

    LogPrintf("Mining thread %d stopped\n", thread_id);
}

void MiningContext::Start(ChainstateManager& chainman, const CTxMemPool& mempool)
{
    enabled = true;
    shutdown_requested = false;
    for (int i = 0; i < num_threads; ++i) {
        threads.emplace_back(MinerThread,
            std::ref(chainman), std::ref(mempool),
            std::cref(coinbase_script), std::ref(*this), i);
    }
    LogPrintf("Started %d mining thread(s)\n", num_threads);
}

void MiningContext::Stop()
{
    if (!enabled) return;
    shutdown_requested = true;
    for (auto& t : threads) {
        if (t.joinable()) t.join();
    }
    threads.clear();
    enabled = false;
    LogPrintf("Mining stopped. Total blocks mined: %lu\n", blocks_mined.load());
}

} // namespace node

// Copyright (c) 2024 The Unicity developers
// Distributed under the MIT software license, see the accompanying
// file COPYING or http://www.opensource.org/licenses/mit-license.php.

#ifndef BITCOIN_NODE_MINING_THREAD_H
#define BITCOIN_NODE_MINING_THREAD_H

#include <atomic>
#include <thread>
#include <vector>
#include <script/script.h>

class ChainstateManager;
class CTxMemPool;

namespace node {

struct MiningContext {
    std::atomic<bool> enabled{false};
    std::atomic<bool> shutdown_requested{false};
    std::vector<std::thread> threads;
    std::atomic<uint64_t> blocks_mined{0};
    CScript coinbase_script;
    int num_threads{1};

    void Start(ChainstateManager& chainman, const CTxMemPool& mempool);
    void Stop();
};

} // namespace node

#endif // BITCOIN_NODE_MINING_THREAD_H

// Copyright (c) 2019-2021 The Bitcoin Core developers
// Distributed under the MIT software license, see the accompanying
// file COPYING or http://www.opensource.org/licenses/mit-license.php.

#ifndef BITCOIN_SIGNET_H
#define BITCOIN_SIGNET_H

#include <consensus/params.h>
#include <primitives/block.h>
#include <primitives/transaction.h>
#include <pubkey.h>

#include <optional>

/**
 * Extract signature and check whether a block has a valid solution
 */
bool CheckSignetBlockSolution(const CBlock& block, const Consensus::Params& consensusParams);

// !ALPHA SIGNET FORK
/**
 * Height-gated variant: check signet block solution only if height >= activation height.
 * Uses signet_challenge_alpha (not signet_challenge) from consensus params.
 */
bool CheckSignetBlockSolution(const CBlock& block, const Consensus::Params& consensusParams, int nHeight);

/**
 * Extract compressed pubkeys from a challenge script (e.g. bare multisig).
 * Returns all valid 33-byte compressed pubkeys found as push data in the script.
 */
std::vector<CPubKey> ExtractPubkeysFromChallenge(const std::vector<uint8_t>& challenge);
// !ALPHA SIGNET FORK END

/**
 * Generate the signet tx corresponding to the given block
 *
 * The signet tx commits to everything in the block except:
 * 1. It hashes a modified merkle root with the signet signature removed.
 * 2. It skips the nonce.
 */
class SignetTxs {
    template<class T1, class T2>
    SignetTxs(const T1& to_spend, const T2& to_sign) : m_to_spend{to_spend}, m_to_sign{to_sign} { }

public:
    static std::optional<SignetTxs> Create(const CBlock& block, const CScript& challenge);

    const CTransaction m_to_spend;
    const CTransaction m_to_sign;
};

#endif // BITCOIN_SIGNET_H

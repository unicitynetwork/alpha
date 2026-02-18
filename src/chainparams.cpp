// Copyright (c) 2010 Satoshi Nakamoto
// Copyright (c) 2009-2022 The Bitcoin Core developers
// Copyright (c) 2024 The Scash developers
// Copyright (c) 2024 The Unicity developers
// Distributed under the MIT software license, see the accompanying
// file COPYING or http://www.opensource.org/licenses/mit-license.php.

#include <chainparams.h>

#include <chainparamsbase.h>
#include <common/args.h>
#include <consensus/params.h>
#include <deploymentinfo.h>
#include <logging.h>
#include <tinyformat.h>
#include <util/chaintype.h>
#include <util/strencodings.h>
#include <util/string.h>

// !ALPHA SIGNET FORK
#include <pubkey.h>
// !ALPHA SIGNET FORK END

#include <cassert>
#include <cstdint>
#include <limits>
#include <stdexcept>
#include <vector>

void ReadSigNetArgs(const ArgsManager& args, CChainParams::SigNetOptions& options)
{
    if (args.IsArgSet("-signetseednode")) {
        options.seeds.emplace(args.GetArgs("-signetseednode"));
    }
    if (args.IsArgSet("-signetchallenge")) {
        const auto signet_challenge = args.GetArgs("-signetchallenge");
        if (signet_challenge.size() != 1) {
            throw std::runtime_error("-signetchallenge cannot be multiple values.");
        }
        const auto val{TryParseHex<uint8_t>(signet_challenge[0])};
        if (!val) {
            throw std::runtime_error(strprintf("-signetchallenge must be hex, not '%s'.", signet_challenge[0]));
        }
        options.challenge.emplace(*val);
    }
}

void ReadRegTestArgs(const ArgsManager& args, CChainParams::RegTestOptions& options)
{
    if (auto value = args.GetBoolArg("-fastprune")) options.fastprune = *value;

    for (const std::string& arg : args.GetArgs("-testactivationheight")) {
        const auto found{arg.find('@')};
        if (found == std::string::npos) {
            throw std::runtime_error(strprintf("Invalid format (%s) for -testactivationheight=name@height.", arg));
        }

        const auto value{arg.substr(found + 1)};
        int32_t height;
        if (!ParseInt32(value, &height) || height < 0 || height >= std::numeric_limits<int>::max()) {
            throw std::runtime_error(strprintf("Invalid height value (%s) for -testactivationheight=name@height.", arg));
        }

        const auto deployment_name{arg.substr(0, found)};
        if (const auto buried_deployment = GetBuriedDeployment(deployment_name)) {
            options.activation_heights[*buried_deployment] = height;
        } else {
            throw std::runtime_error(strprintf("Invalid name (%s) for -testactivationheight=name@height.", arg));
        }
    }

    if (!args.IsArgSet("-vbparams")) return;

    for (const std::string& strDeployment : args.GetArgs("-vbparams")) {
        std::vector<std::string> vDeploymentParams = SplitString(strDeployment, ':');
        if (vDeploymentParams.size() < 3 || 4 < vDeploymentParams.size()) {
            throw std::runtime_error("Version bits parameters malformed, expecting deployment:start:end[:min_activation_height]");
        }
        CChainParams::VersionBitsParameters vbparams{};
        if (!ParseInt64(vDeploymentParams[1], &vbparams.start_time)) {
            throw std::runtime_error(strprintf("Invalid nStartTime (%s)", vDeploymentParams[1]));
        }
        if (!ParseInt64(vDeploymentParams[2], &vbparams.timeout)) {
            throw std::runtime_error(strprintf("Invalid nTimeout (%s)", vDeploymentParams[2]));
        }
        if (vDeploymentParams.size() >= 4) {
            if (!ParseInt32(vDeploymentParams[3], &vbparams.min_activation_height)) {
                throw std::runtime_error(strprintf("Invalid min_activation_height (%s)", vDeploymentParams[3]));
            }
        } else {
            vbparams.min_activation_height = 0;
        }
        bool found = false;
        for (int j=0; j < (int)Consensus::MAX_VERSION_BITS_DEPLOYMENTS; ++j) {
            if (vDeploymentParams[0] == VersionBitsDeploymentInfo[j].name) {
                options.version_bits_parameters[Consensus::DeploymentPos(j)] = vbparams;
                found = true;
                LogPrintf("Setting version bits activation parameters for %s to start=%ld, timeout=%ld, min_activation_height=%d\n", vDeploymentParams[0], vbparams.start_time, vbparams.timeout, vbparams.min_activation_height);
                break;
            }
        }
        if (!found) {
            throw std::runtime_error(strprintf("Invalid deployment (%s)", vDeploymentParams[0]));
        }
    }
}

// !ALPHA SIGNET FORK
void ReadAlphaSignetForkArgs(const ArgsManager& args, CChainParams::AlphaSignetForkOptions& options)
{
    if (args.IsArgSet("-signetforkheight")) {
        int32_t height;
        if (!ParseInt32(args.GetArg("-signetforkheight", "0"), &height) || height < 0) {
            throw std::runtime_error("-signetforkheight must be a non-negative integer.");
        }
        options.fork_height = height;
    }
    if (args.IsArgSet("-signetforkpubkeys")) {
        const std::string val = args.GetArg("-signetforkpubkeys", "");
        if (val.empty()) {
            throw std::runtime_error("-signetforkpubkeys must not be empty.");
        }
        std::vector<std::string> hex_keys = SplitString(val, ',');
        for (const auto& hex_key : hex_keys) {
            auto parsed = TryParseHex<uint8_t>(hex_key);
            if (!parsed || parsed->size() != CPubKey::COMPRESSED_SIZE) {
                throw std::runtime_error(strprintf(
                    "-signetforkpubkeys: '%s' is not a valid 33-byte compressed pubkey hex.", hex_key));
            }
            CPubKey pk(*parsed);
            if (!pk.IsFullyValid()) {
                throw std::runtime_error(strprintf(
                    "-signetforkpubkeys: '%s' is not a valid secp256k1 point.", hex_key));
            }
        }
        options.pubkeys_hex = hex_keys;
    }
    // Cross-validation
    if (options.fork_height && *options.fork_height > 0 && !options.pubkeys_hex) {
        throw std::runtime_error("-signetforkheight > 0 requires -signetforkpubkeys.");
    }
    if (options.pubkeys_hex && (!options.fork_height || *options.fork_height <= 0)) {
        throw std::runtime_error("-signetforkpubkeys requires -signetforkheight > 0.");
    }
}
// !ALPHA SIGNET FORK END

static std::unique_ptr<const CChainParams> globalChainParams;

const CChainParams &Params() {
    assert(globalChainParams);
    return *globalChainParams;
}

std::unique_ptr<const CChainParams> CreateChainParams(const ArgsManager& args, const ChainType chain)
{
    switch (chain) {
    case ChainType::MAIN:
        return CChainParams::Main();
    case ChainType::TESTNET:
        return CChainParams::TestNet();
    case ChainType::SIGNET: {
        auto opts = CChainParams::SigNetOptions{};
        ReadSigNetArgs(args, opts);
        return CChainParams::SigNet(opts);
    }
    case ChainType::REGTEST: {
        auto opts = CChainParams::RegTestOptions{};
        ReadRegTestArgs(args, opts);
        return CChainParams::RegTest(opts);
    }

    // !SCASH
    case ChainType::SCASHREGTEST: {
        auto opts = CChainParams::RegTestOptions{};
        ReadRegTestArgs(args, opts);
        return CChainParams::ScashRegTest(opts);
    }
    case ChainType::SCASHTESTNET: {
        return CChainParams::ScashTestNet();
    }
    case ChainType::SCASHMAIN: {
        return CChainParams::ScashMain();
    }
    // !SCASH END

    // !ALPHA
    case ChainType::ALPHAREGTEST: {
        auto opts = CChainParams::RegTestOptions{};
        ReadRegTestArgs(args, opts);
        auto fork_opts = CChainParams::AlphaSignetForkOptions{};
        ReadAlphaSignetForkArgs(args, fork_opts);
        return CChainParams::AlphaRegTest(opts, fork_opts);
    }
    case ChainType::ALPHATESTNET: {
        auto fork_opts = CChainParams::AlphaSignetForkOptions{};
        ReadAlphaSignetForkArgs(args, fork_opts);
        return CChainParams::AlphaTestNet(fork_opts);
    }
    case ChainType::ALPHAMAIN: {
        return CChainParams::AlphaMain();
    }
    // !ALPHA END

    }
    assert(false);
}

void SelectParams(const ChainType chain)
{
    SelectBaseParams(chain);
    globalChainParams = CreateChainParams(gArgs, chain);
}

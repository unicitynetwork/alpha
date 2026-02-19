#!/usr/bin/env bash
# =============================================================================
# Alpha Mainnet Pubkey Deployment-Readiness E2E Test
#
# Standalone test (not part of the 20-test signet fork suite) that validates:
#   1. .env contains valid signing keys
#   2. .env key derives to a hardcoded mainnet pubkey
#   3. Real pubkeys work for block production on alpharegtest
#   4. Mainnet rejects custom fork args
#   5. Wrong signing key is rejected
#
# Usage:  bash test/e2e/mainnet_pubkey_e2e.sh
# Prereq: docker, jq, python3, bash 4+, .env file (from generate_mainnet_keys.sh)
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

# --- Constants ---------------------------------------------------------------
IMAGE_NAME="alpha-e2e"
CONTAINER_PREFIX="alpha-pubkey-test"
NETWORK_NAME="alpha-pubkey-net"

# The 5 hardcoded mainnet pubkeys (must match src/kernel/chainparams.cpp)
MAINNET_PUBKEYS=(
    "02a86f4a1875e967435d9836df3dfba75fc84700af293ce487a99d6adb6f4ebecc"
    "0234dae4ef312c640fa00f4d74048da77262224e506341b85f0b2a783c811bcef0"
    "023602941d79d865ad32e88265feb101f3990a813d46b2fc01bc6601e9df7d69cc"
    "024f12994fae223c07a2a802b9fa0cb8a1f5d24a7fedc40d3c2fad0a69574b2f9e"
    "030934597b587069a9bb885782790eae0b16496e4863d0d6b7ad1ba0de0b078b3e"
)
MAINNET_PUBKEYS_CSV=$(IFS=,; echo "${MAINNET_PUBKEYS[*]}")

# Chain settings
MAINNET_CHAIN="alpha"
MAINNET_RPC_PORT=8589
REGTEST_CHAIN="alpharegtest"
REGTEST_RPC_PORT=28590
REGTEST_P2P_PORT=28589
FORK_HEIGHT=10

RPC_USER="test"
RPC_PASS="test"

WIF_CONVERT="${SCRIPT_DIR}/lib/wif_convert.py"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Counters
TESTS_PASSED=0
TESTS_FAILED=0
TESTS_TOTAL=0

# --- Helpers -----------------------------------------------------------------

assert_eq() {
    local desc="$1" expected="$2" actual="$3"
    TESTS_TOTAL=$((TESTS_TOTAL + 1))
    if [ "$expected" = "$actual" ]; then
        echo -e "  ${GREEN}PASS${NC}: $desc"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        echo -e "  ${RED}FAIL${NC}: $desc"
        echo -e "    expected: ${expected}"
        echo -e "    actual:   ${actual}"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
}

assert_contains() {
    local desc="$1" needle="$2" haystack="$3"
    TESTS_TOTAL=$((TESTS_TOTAL + 1))
    if echo "$haystack" | grep -q "$needle"; then
        echo -e "  ${GREEN}PASS${NC}: $desc"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        echo -e "  ${RED}FAIL${NC}: $desc"
        echo -e "    expected to contain: ${needle}"
        echo -e "    actual: ${haystack:0:200}"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
}

assert_ge() {
    local desc="$1" threshold="$2" actual="$3"
    TESTS_TOTAL=$((TESTS_TOTAL + 1))
    if [ "$actual" -ge "$threshold" ] 2>/dev/null; then
        echo -e "  ${GREEN}PASS${NC}: $desc"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        echo -e "  ${RED}FAIL${NC}: $desc (expected >= ${threshold}, got ${actual})"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
}

test_header() {
    echo ""
    echo -e "${BLUE}=== Test ${1}: ${2} ===${NC}"
}

cleanup() {
    echo -e "${YELLOW}Cleaning up...${NC}"
    for i in $(seq 0 9); do
        docker rm -f "${CONTAINER_PREFIX}${i}" 2>/dev/null || true
    done
    docker network rm "${NETWORK_NAME}" 2>/dev/null || true
    rm -rf /tmp/alpha-pubkey-test-* 2>/dev/null || true
    echo "Cleanup complete."
}

# acli <container_suffix> <chain> <rpc_port> <args...>
acli() {
    local suffix=$1 chain=$2 port=$3; shift 3
    docker exec "${CONTAINER_PREFIX}${suffix}" alpha-cli \
        -chain="$chain" -rpcport="$port" \
        -rpcuser="$RPC_USER" -rpcpassword="$RPC_PASS" "$@"
}

# --- Preflight ---------------------------------------------------------------
for cmd in docker jq python3; do
    if ! command -v "$cmd" &>/dev/null; then
        echo -e "${RED}ERROR: '${cmd}' is required but not found.${NC}"
        exit 1
    fi
done

if [ "${BASH_VERSINFO[0]}" -lt 4 ]; then
    echo -e "${RED}ERROR: bash 4+ required.${NC}"
    exit 1
fi

if [ ! -f "${WIF_CONVERT}" ]; then
    echo -e "${RED}ERROR: ${WIF_CONVERT} not found.${NC}"
    exit 1
fi

cd "$REPO_ROOT"

# Clean up any leftover state
cleanup
trap cleanup EXIT

docker network create "${NETWORK_NAME}" >/dev/null 2>&1 || true

echo ""
echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}  Mainnet Pubkey Deployment-Readiness   ${NC}"
echo -e "${BLUE}========================================${NC}"

# =============================================================================
# Test 1: .env validation
# =============================================================================
test_header "1" ".env file validation"
{
    if [ ! -f ".env" ]; then
        echo -e "  ${RED}FAIL${NC}: .env file not found (run: bash scripts/generate_mainnet_keys.sh)"
        TESTS_TOTAL=$((TESTS_TOTAL + 1))
        TESTS_FAILED=$((TESTS_FAILED + 1))
        # Cannot continue without .env
        echo ""
        echo -e "  ${RED}FATAL: Cannot continue without .env file.${NC}"
        exit 1
    fi

    # Source .env
    set -a
    source .env
    set +a

    # Verify ALPHA_SIGNING_KEY_0 is non-empty
    TESTS_TOTAL=$((TESTS_TOTAL + 1))
    if [ -n "${ALPHA_SIGNING_KEY_0:-}" ]; then
        echo -e "  ${GREEN}PASS${NC}: ALPHA_SIGNING_KEY_0 is non-empty"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        echo -e "  ${RED}FAIL${NC}: ALPHA_SIGNING_KEY_0 is empty or missing"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi

    # Verify it looks like a valid base58 WIF (starts with K, L, or 5)
    TESTS_TOTAL=$((TESTS_TOTAL + 1))
    first_char="${ALPHA_SIGNING_KEY_0:0:1}"
    if [[ "$first_char" == "K" || "$first_char" == "L" || "$first_char" == "5" ]]; then
        echo -e "  ${GREEN}PASS${NC}: ALPHA_SIGNING_KEY_0 starts with valid WIF prefix (${first_char})"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        echo -e "  ${RED}FAIL${NC}: ALPHA_SIGNING_KEY_0 has unexpected prefix '${first_char}' (expected K/L/5)"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi

    # Verify all 5 keys are present
    all_present=true
    for i in $(seq 0 4); do
        varname="ALPHA_SIGNING_KEY_${i}"
        if [ -z "${!varname:-}" ]; then
            all_present=false
        fi
    done
    TESTS_TOTAL=$((TESTS_TOTAL + 1))
    if $all_present; then
        echo -e "  ${GREEN}PASS${NC}: all 5 signing keys present in .env"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        echo -e "  ${RED}FAIL${NC}: some signing keys missing from .env"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
}

# =============================================================================
# Test 2: Pubkey derivation matches hardcoded mainnet pubkeys
# =============================================================================
test_header "2" "Pubkey derivation matches hardcoded mainnet pubkeys"
{
    conf_dir="/tmp/alpha-pubkey-test-mainnet"
    mkdir -p "$conf_dir"

    cat > "${conf_dir}/alpha.conf" <<CONFEOF
chain=${MAINNET_CHAIN}

[${MAINNET_CHAIN}]
server=1
rpcport=${MAINNET_RPC_PORT}
rpcuser=${RPC_USER}
rpcpassword=${RPC_PASS}
rpcallowip=0.0.0.0/0
rpcbind=0.0.0.0
listen=0
noconnect=1
randomxfastmode=1
deprecatedrpc=create_bdb
CONFEOF

    docker run -d \
        --name "${CONTAINER_PREFIX}0" \
        --network "${NETWORK_NAME}" \
        -v "${conf_dir}:/config" \
        "${IMAGE_NAME}" alphad >/dev/null

    # Wait for RPC
    deadline=$((SECONDS + 120))
    rpc_ready=false
    while [ $SECONDS -lt $deadline ]; do
        if acli 0 "$MAINNET_CHAIN" "$MAINNET_RPC_PORT" getblockchaininfo &>/dev/null; then
            rpc_ready=true
            break
        fi
        sleep 2
    done

    if ! $rpc_ready; then
        echo "  WARNING: mainnet node failed to start"
        docker logs "${CONTAINER_PREFIX}0" 2>&1 | tail -20
        TESTS_TOTAL=$((TESTS_TOTAL + 1))
        TESTS_FAILED=$((TESTS_FAILED + 1))
    else
        # Create a legacy wallet
        acli 0 "$MAINNET_CHAIN" "$MAINNET_RPC_PORT" createwallet "verify" false false "" false false >/dev/null

        # Import first key and check pubkey
        acli 0 "$MAINNET_CHAIN" "$MAINNET_RPC_PORT" -rpcwallet=verify importprivkey "$ALPHA_SIGNING_KEY_0" "key0" false >/dev/null

        # Get the address for this key, then its pubkey
        addr=$(acli 0 "$MAINNET_CHAIN" "$MAINNET_RPC_PORT" -rpcwallet=verify getaddressesbylabel "key0" | jq -r 'keys[0]')
        info_json=$(acli 0 "$MAINNET_CHAIN" "$MAINNET_RPC_PORT" -rpcwallet=verify getaddressinfo "$addr")
        derived_pubkey=$(echo "$info_json" | jq -r '.pubkey')

        echo "  Derived pubkey: ${derived_pubkey}"
        echo "  Expected pk[0]: ${MAINNET_PUBKEYS[0]}"

        assert_eq "derived pubkey matches hardcoded pubkey[0]" "${MAINNET_PUBKEYS[0]}" "$derived_pubkey"
    fi

    docker rm -f "${CONTAINER_PREFIX}0" >/dev/null 2>&1 || true
}

# =============================================================================
# Test 3: Block production with real pubkeys on alpharegtest
# =============================================================================
test_header "3" "Block production with real pubkeys on alpharegtest"
{
    # Convert mainnet WIF to regtest WIF
    regtest_wif=$(python3 "$WIF_CONVERT" "$ALPHA_SIGNING_KEY_0" ef)
    echo "  Converted mainnet WIF -> regtest WIF: ${regtest_wif:0:8}..."

    conf_dir="/tmp/alpha-pubkey-test-regtest"
    mkdir -p "$conf_dir"

    # Get a mining address: use a placeholder, the wallet will generate one
    cat > "${conf_dir}/alpha.conf" <<CONFEOF
chain=${REGTEST_CHAIN}

[${REGTEST_CHAIN}]
server=1
port=${REGTEST_P2P_PORT}
rpcport=${REGTEST_RPC_PORT}
rpcuser=${RPC_USER}
rpcpassword=${RPC_PASS}
rpcallowip=0.0.0.0/0
rpcbind=0.0.0.0
listen=0
noconnect=1
randomxfastmode=1
fallbackfee=0.0001
signetforkheight=${FORK_HEIGHT}
signetforkpubkeys=${MAINNET_PUBKEYS_CSV}
signetblockkey=${regtest_wif}
CONFEOF

    docker run -d \
        --name "${CONTAINER_PREFIX}1" \
        --network "${NETWORK_NAME}" \
        -v "${conf_dir}:/config" \
        "${IMAGE_NAME}" alphad >/dev/null

    # Wait for RPC
    deadline=$((SECONDS + 120))
    rpc_ready=false
    while [ $SECONDS -lt $deadline ]; do
        if acli 1 "$REGTEST_CHAIN" "$REGTEST_RPC_PORT" getblockchaininfo &>/dev/null; then
            rpc_ready=true
            break
        fi
        sleep 2
    done

    if ! $rpc_ready; then
        echo "  WARNING: regtest node failed to start"
        docker logs "${CONTAINER_PREFIX}1" 2>&1 | tail -20
        TESTS_TOTAL=$((TESTS_TOTAL + 4))
        TESTS_FAILED=$((TESTS_FAILED + 4))
    else
        # Create wallet for mining address
        acli 1 "$REGTEST_CHAIN" "$REGTEST_RPC_PORT" createwallet "mine" >/dev/null 2>&1 || true
        mine_addr=$(acli 1 "$REGTEST_CHAIN" "$REGTEST_RPC_PORT" -rpcwallet=mine getnewaddress)

        # Initialize mocktime
        MOCK_TIME=$(date +%s)

        # Mine past fork height using mocktime for min-difficulty
        echo "  Mining 15 blocks (past fork height ${FORK_HEIGHT})..."
        for _i in $(seq 1 15); do
            MOCK_TIME=$((MOCK_TIME + 300))
            acli 1 "$REGTEST_CHAIN" "$REGTEST_RPC_PORT" setmocktime "$MOCK_TIME" >/dev/null
            acli 1 "$REGTEST_CHAIN" "$REGTEST_RPC_PORT" generatetoaddress 1 "$mine_addr" >/dev/null
        done

        h=$(acli 1 "$REGTEST_CHAIN" "$REGTEST_RPC_PORT" getblockcount)
        echo "  Node height: ${h}"

        # Assertion 1: Height >= 15
        assert_ge "node reached height >= 15" 15 "$h"

        # Assertion 2: Post-fork blocks have zero coinbase
        all_zero=true
        for blk in $(seq $((FORK_HEIGHT + 1)) "$h"); do
            blockhash=$(acli 1 "$REGTEST_CHAIN" "$REGTEST_RPC_PORT" getblockhash "$blk")
            block_json=$(acli 1 "$REGTEST_CHAIN" "$REGTEST_RPC_PORT" getblock "$blockhash" 2)
            cb_val=$(echo "$block_json" | jq -r '.tx[0].vout[0].value' | awk '{printf "%.8f\n", $1}')
            if [ "$cb_val" != "0.00000000" ]; then
                echo "    block ${blk}: coinbase=${cb_val} (expected 0)"
                all_zero=false
            fi
        done
        TESTS_TOTAL=$((TESTS_TOTAL + 1))
        if $all_zero; then
            echo -e "  ${GREEN}PASS${NC}: all post-fork blocks have zero coinbase"
            TESTS_PASSED=$((TESTS_PASSED + 1))
        else
            echo -e "  ${RED}FAIL${NC}: some post-fork blocks have non-zero coinbase"
            TESTS_FAILED=$((TESTS_FAILED + 1))
        fi

        # Assertion 3: Post-fork blocks contain SIGNET_HEADER (ecc7daa2)
        all_signed=true
        for blk in $(seq $((FORK_HEIGHT + 1)) "$h"); do
            blockhash=$(acli 1 "$REGTEST_CHAIN" "$REGTEST_RPC_PORT" getblockhash "$blk")
            cb_hex=$(acli 1 "$REGTEST_CHAIN" "$REGTEST_RPC_PORT" getblock "$blockhash" 2 | jq -r '.tx[0].hex // empty')
            if [ -n "$cb_hex" ] && ! echo "$cb_hex" | grep -qi "ecc7daa2"; then
                echo "    block ${blk}: missing SIGNET_HEADER"
                all_signed=false
            fi
        done
        TESTS_TOTAL=$((TESTS_TOTAL + 1))
        if $all_signed; then
            echo -e "  ${GREEN}PASS${NC}: all post-fork blocks contain SIGNET_HEADER"
            TESTS_PASSED=$((TESTS_PASSED + 1))
        else
            echo -e "  ${RED}FAIL${NC}: some post-fork blocks missing SIGNET_HEADER"
            TESTS_FAILED=$((TESTS_FAILED + 1))
        fi
    fi

    docker rm -f "${CONTAINER_PREFIX}1" >/dev/null 2>&1 || true
}

# =============================================================================
# Test 4: Mainnet rejects custom fork args
# =============================================================================
test_header "4" "Mainnet rejects -signetforkheight"
{
    conf_dir="/tmp/alpha-pubkey-test-mainnet-reject"
    mkdir -p "$conf_dir"

    cat > "${conf_dir}/alpha.conf" <<CONFEOF
chain=${MAINNET_CHAIN}

[${MAINNET_CHAIN}]
server=1
rpcport=${MAINNET_RPC_PORT}
rpcuser=${RPC_USER}
rpcpassword=${RPC_PASS}
rpcallowip=0.0.0.0/0
rpcbind=0.0.0.0
listen=0
noconnect=1
randomxfastmode=1
signetforkheight=100000
CONFEOF

    # Run container; it should exit quickly with an error
    docker run -d \
        --name "${CONTAINER_PREFIX}2" \
        --network "${NETWORK_NAME}" \
        -v "${conf_dir}:/config" \
        "${IMAGE_NAME}" alphad >/dev/null 2>&1 || true

    # Wait for it to exit (should be fast)
    sleep 10

    logs=$(docker logs "${CONTAINER_PREFIX}2" 2>&1 || echo "")
    container_running=$(docker inspect -f '{{.State.Running}}' "${CONTAINER_PREFIX}2" 2>/dev/null || echo "false")

    assert_contains "alphad rejected -signetforkheight on mainnet" "not allowed on mainnet" "$logs"

    TESTS_TOTAL=$((TESTS_TOTAL + 1))
    if [ "$container_running" = "false" ]; then
        echo -e "  ${GREEN}PASS${NC}: container exited (not running)"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        echo -e "  ${RED}FAIL${NC}: container still running (should have exited with error)"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi

    docker rm -f "${CONTAINER_PREFIX}2" >/dev/null 2>&1 || true
}

# =============================================================================
# Test 5: Wrong signing key rejected
# =============================================================================
test_header "5" "Wrong signing key rejected by authorized pubkey check"
{
    conf_dir="/tmp/alpha-pubkey-test-wrong-key"
    mkdir -p "$conf_dir"

    # Generate a fresh WIF key that is NOT in the authorized set.
    # Use a known regtest WIF that won't match any of the 5 hardcoded pubkeys.
    # We generate one by converting a dummy hex private key.
    wrong_wif=$(python3 -c "
import hashlib, sys
# Deterministic dummy key (not in authorized set)
privkey = hashlib.sha256(b'wrong-key-for-testing-12345').digest()
version = bytes([0xef])  # regtest
payload = version + privkey + b'\x01'  # compressed
checksum = hashlib.sha256(hashlib.sha256(payload).digest()).digest()[:4]
raw = payload + checksum
# base58 encode
alphabet = b'123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz'
n = int.from_bytes(raw, 'big')
result = []
while n > 0:
    n, r = divmod(n, 58)
    result.append(alphabet[r:r+1])
for byte in raw:
    if byte == 0:
        result.append(alphabet[0:1])
    else:
        break
print(b''.join(reversed(result)).decode())
")
    echo "  Wrong key WIF: ${wrong_wif:0:8}..."

    cat > "${conf_dir}/alpha.conf" <<CONFEOF
chain=${REGTEST_CHAIN}

[${REGTEST_CHAIN}]
server=1
port=${REGTEST_P2P_PORT}
rpcport=${REGTEST_RPC_PORT}
rpcuser=${RPC_USER}
rpcpassword=${RPC_PASS}
rpcallowip=0.0.0.0/0
rpcbind=0.0.0.0
listen=0
noconnect=1
randomxfastmode=1
signetforkheight=${FORK_HEIGHT}
signetforkpubkeys=${MAINNET_PUBKEYS_CSV}
signetblockkey=${wrong_wif}
CONFEOF

    docker run -d \
        --name "${CONTAINER_PREFIX}3" \
        --network "${NETWORK_NAME}" \
        -v "${conf_dir}:/config" \
        "${IMAGE_NAME}" alphad >/dev/null 2>&1 || true

    # Wait for it to exit or show the error in logs
    deadline=$((SECONDS + 30))
    logs=""
    while [ $SECONDS -lt $deadline ]; do
        logs=$(docker logs "${CONTAINER_PREFIX}3" 2>&1 || echo "")
        container_running=$(docker inspect -f '{{.State.Running}}' "${CONTAINER_PREFIX}3" 2>/dev/null || echo "false")
        if [ "$container_running" = "false" ]; then
            break
        fi
        if echo "$logs" | grep -q "NOT in the authorized allowlist"; then
            break
        fi
        sleep 2
    done

    logs=$(docker logs "${CONTAINER_PREFIX}3" 2>&1 || echo "")

    TESTS_TOTAL=$((TESTS_TOTAL + 1))
    if echo "$logs" | grep -q "NOT in the authorized allowlist\|Invalid -signetblockkey"; then
        echo -e "  ${GREEN}PASS${NC}: wrong key rejected at startup"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        echo -e "  ${RED}FAIL${NC}: expected key rejection error in logs"
        echo "  Last 10 lines of logs:"
        echo "$logs" | tail -10
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi

    docker rm -f "${CONTAINER_PREFIX}3" >/dev/null 2>&1 || true
}

# =============================================================================
# Summary
# =============================================================================
echo ""
echo "======================================"
echo -e "  Tests passed: ${GREEN}${TESTS_PASSED}${NC} / ${TESTS_TOTAL}"
if [ "$TESTS_FAILED" -gt 0 ]; then
    echo -e "  Tests failed: ${RED}${TESTS_FAILED}${NC}"
    echo "======================================"
    exit 1
else
    echo -e "  ${GREEN}All tests passed!${NC}"
    echo "======================================"
    exit 0
fi

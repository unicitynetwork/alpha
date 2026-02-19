#!/usr/bin/env bash
# =============================================================================
# Generate 5 mainnet signing key pairs for Alpha signet fork
#
# Uses a temporary Docker container running alphad on chain=alpha (offline)
# to generate compressed public keys and WIF private keys.
#
# Output:
#   - .env file with ALPHA_SIGNING_KEY_0..4 (mainnet WIF keys)
#   - Stdout: pubkey hex values formatted for chainparams.cpp
#
# Usage:  bash scripts/generate_mainnet_keys.sh [--force]
# Prereq: docker (with alpha-e2e image built)
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

IMAGE_NAME="alpha-e2e"
CONTAINER_NAME="alpha-keygen-mainnet"
CONF_DIR="/tmp/alpha-keygen-mainnet-conf"
ENV_FILE="${REPO_ROOT}/.env"
NUM_KEYS=5

CHAIN="alpha"
RPC_PORT=8589
RPC_USER="keygen"
RPC_PASS="keygen"

# --- Parse args ---
FORCE=false
if [[ "${1:-}" == "--force" ]]; then
    FORCE=true
fi

# --- Safeguard: refuse to overwrite .env ---
if [[ -f "$ENV_FILE" ]] && ! $FORCE; then
    echo "ERROR: ${ENV_FILE} already exists. Use --force to overwrite."
    exit 1
fi

# --- Cleanup on exit ---
cleanup() {
    docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
    rm -rf "$CONF_DIR" 2>/dev/null || true
}
trap cleanup EXIT

# --- Helper: run alpha-cli in the container ---
acli() {
    docker exec "$CONTAINER_NAME" alpha-cli \
        -chain="$CHAIN" -rpcport="$RPC_PORT" \
        -rpcuser="$RPC_USER" -rpcpassword="$RPC_PASS" "$@"
}

# --- Write minimal config for offline mainnet node ---
mkdir -p "$CONF_DIR"
cat > "${CONF_DIR}/alpha.conf" <<EOF
chain=${CHAIN}

[${CHAIN}]
server=1
rpcport=${RPC_PORT}
rpcuser=${RPC_USER}
rpcpassword=${RPC_PASS}
rpcallowip=0.0.0.0/0
rpcbind=0.0.0.0
listen=0
noconnect=1
randomxfastmode=1
deprecatedrpc=create_bdb
EOF

# --- Start temporary container ---
echo "Starting temporary alphad container (offline, chain=${CHAIN})..."
docker run -d \
    --name "$CONTAINER_NAME" \
    -v "${CONF_DIR}:/config" \
    "$IMAGE_NAME" alphad >/dev/null

# --- Wait for RPC ---
echo "Waiting for RPC..."
deadline=$((SECONDS + 120))
while [ $SECONDS -lt $deadline ]; do
    if acli getblockchaininfo &>/dev/null; then
        break
    fi
    sleep 2
done

if ! acli getblockchaininfo &>/dev/null; then
    echo "ERROR: alphad failed to start within 120s"
    docker logs "$CONTAINER_NAME" 2>&1 | tail -20
    exit 1
fi

# --- Create legacy wallet for dumpprivkey support ---
echo "Creating keygen wallet..."
acli createwallet "keygen" false false "" false false >/dev/null

# --- Generate key pairs ---
declare -a PUBKEYS
declare -a WIFS

echo "Generating ${NUM_KEYS} key pairs..."
for i in $(seq 0 $((NUM_KEYS - 1))); do
    addr=$(acli -rpcwallet=keygen getnewaddress "" "legacy")

    info_json=$(acli -rpcwallet=keygen getaddressinfo "$addr")
    pubkey=$(echo "$info_json" | jq -r '.pubkey')
    PUBKEYS+=("$pubkey")

    wif=$(acli -rpcwallet=keygen dumpprivkey "$addr")
    WIFS+=("$wif")

    echo "  Key ${i}: pubkey=${pubkey}"
done

# --- Write .env file ---
echo "Writing ${ENV_FILE}..."
cat > "$ENV_FILE" <<ENVEOF
# Alpha mainnet signing keys (WIF format)
# Generated on $(date -u +%Y-%m-%dT%H:%M:%SZ)
# KEEP THIS FILE SECRET — do not commit to git
ENVEOF

for i in $(seq 0 $((NUM_KEYS - 1))); do
    echo "ALPHA_SIGNING_KEY_${i}=${WIFS[$i]}" >> "$ENV_FILE"
done
chmod 600 "$ENV_FILE"

# --- Print pubkeys for chainparams.cpp ---
echo ""
echo "========================================="
echo "  Pubkeys for src/kernel/chainparams.cpp"
echo "========================================="
for i in $(seq 0 $((NUM_KEYS - 1))); do
    echo "            \"21\" \"${PUBKEYS[$i]}\"  // push 33 bytes + pubkey $((i + 1))"
done

echo ""
echo "========================================="
echo "  Comma-separated pubkeys for -signetforkpubkeys"
echo "========================================="
csv=$(IFS=,; echo "${PUBKEYS[*]}")
echo "$csv"

echo ""
echo "Done. Private keys saved to ${ENV_FILE}"

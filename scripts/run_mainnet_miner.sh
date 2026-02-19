#!/usr/bin/env bash
# =============================================================================
# Start Alpha mainnet node with integrated mining using the feature branch image
#
# Uses the alpha-e2e Docker image (built from feature/signet-fork-450000)
# which contains the hardcoded signet fork pubkeys for height 450000.
#
# The node will:
#   1. Sync the existing mainnet chain (uses alpha-data volume)
#   2. Mine blocks using integrated RandomX miner
#   3. Automatically produce signed blocks after fork height 450000
#
# Usage:  bash scripts/run_mainnet_miner.sh [--threads N]
# Stop:   docker stop alpha-fork-miner
# Logs:   docker logs -f alpha-fork-miner
# CLI:    docker exec alpha-fork-miner alpha-cli -chain=alpha -rpcport=8589 \
#             -rpcuser=miner -rpcpassword=miner getblockchaininfo
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# --- Configuration ---
IMAGE_NAME="alpha-e2e"
CONTAINER_NAME="alpha-fork-miner"
NETWORK_NAME="alpha-net"
CONF_DIR="/home/vrogojin/alpha/config/mainnet-miner"
ENV_FILE="${REPO_ROOT}/.env"

CHAIN="alpha"
P2P_PORT=8590
RPC_PORT=8589
RPC_USER="miner"
RPC_PASS="miner"
MINE_THREADS=1

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# --- Parse args ---
while [[ $# -gt 0 ]]; do
    case $1 in
        --threads)
            MINE_THREADS="$2"
            shift 2
            ;;
        *)
            echo "Usage: $0 [--threads N]"
            exit 1
            ;;
    esac
done

# --- Preflight checks ---
echo -e "${BLUE}=== Alpha Mainnet Fork Miner ===${NC}"
echo ""

# Check .env exists
if [ ! -f "$ENV_FILE" ]; then
    echo -e "${RED}ERROR: ${ENV_FILE} not found.${NC}"
    echo "Run: bash scripts/generate_mainnet_keys.sh"
    exit 1
fi

# Source .env to get signing key
set -a
source "$ENV_FILE"
set +a

if [ -z "${ALPHA_SIGNING_KEY_0:-}" ]; then
    echo -e "${RED}ERROR: ALPHA_SIGNING_KEY_0 not found in .env${NC}"
    exit 1
fi

# Check Docker image exists
if ! docker image inspect "$IMAGE_NAME" &>/dev/null; then
    echo -e "${RED}ERROR: Docker image '${IMAGE_NAME}' not found.${NC}"
    echo "Build it with: docker build -t alpha-e2e -f docker/Dockerfile ."
    exit 1
fi

# Check if container already running
if docker ps --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
    echo -e "${YELLOW}Container '${CONTAINER_NAME}' is already running.${NC}"
    echo "  Logs:  docker logs -f ${CONTAINER_NAME}"
    echo "  Stop:  docker stop ${CONTAINER_NAME}"
    echo "  CLI:   docker exec ${CONTAINER_NAME} alpha-cli -chain=${CHAIN} -rpcport=${RPC_PORT} -rpcuser=${RPC_USER} -rpcpassword=${RPC_PASS} getblockchaininfo"
    exit 0
fi

# Remove stopped container with same name
docker rm -f "$CONTAINER_NAME" 2>/dev/null || true

# --- Create config ---
mkdir -p "$CONF_DIR"

# Generate a mining address? No — we need to get one from the wallet after startup.
# Instead, we'll leave mineaddress blank initially and set it after wallet creation.
# Actually, the integrated miner requires mineaddress at startup, so we need to
# pick an approach. We'll start without -mine, create a wallet, get an address,
# then restart with mining enabled.
#
# Simpler approach: write config, start node, wait for sync, then the miner
# will use the configured address. For the first run, we use a temporary address
# and can update it later.

echo -e "${BLUE}Writing config...${NC}"
cat > "${CONF_DIR}/alpha.conf" <<CONFEOF
chain=${CHAIN}

[${CHAIN}]
server=1
port=${P2P_PORT}
rpcport=${RPC_PORT}
rpcuser=${RPC_USER}
rpcpassword=${RPC_PASS}
rpcallowip=0.0.0.0/0
rpcbind=0.0.0.0
listen=1
txindex=1

# Mining
signetblockkey=${ALPHA_SIGNING_KEY_0}
minethreads=${MINE_THREADS}

# Performance
randomxfastmode=1
dbcache=1000
maxmempool=300

# Logging
printtoconsole=1
logtimestamps=1
logips=1

# Peers
deprecatedrpc=create_bdb
CONFEOF

echo -e "${GREEN}Config written to ${CONF_DIR}/alpha.conf${NC}"

# --- Ensure network exists ---
docker network create "$NETWORK_NAME" 2>/dev/null || true

# --- Start node (Phase 1: sync without mining) ---
echo -e "${BLUE}Starting node (sync mode)...${NC}"
docker run -d --restart unless-stopped \
    --name "$CONTAINER_NAME" \
    --network "$NETWORK_NAME" \
    -p ${P2P_PORT}:${P2P_PORT} \
    -v alpha-data:/root/.alpha \
    -v "${CONF_DIR}:/config" \
    "$IMAGE_NAME" alphad

echo "  Waiting for RPC to become available..."
deadline=$((SECONDS + 180))
rpc_ready=false
while [ $SECONDS -lt $deadline ]; do
    if docker exec "$CONTAINER_NAME" alpha-cli \
        -chain="$CHAIN" -rpcport="$RPC_PORT" \
        -rpcuser="$RPC_USER" -rpcpassword="$RPC_PASS" \
        getblockchaininfo &>/dev/null; then
        rpc_ready=true
        break
    fi
    sleep 3
done

if ! $rpc_ready; then
    echo -e "${RED}ERROR: Node failed to start within 180s${NC}"
    docker logs "$CONTAINER_NAME" 2>&1 | tail -30
    exit 1
fi

echo -e "${GREEN}Node RPC ready.${NC}"

# --- Helper ---
acli() {
    docker exec "$CONTAINER_NAME" alpha-cli \
        -chain="$CHAIN" -rpcport="$RPC_PORT" \
        -rpcuser="$RPC_USER" -rpcpassword="$RPC_PASS" "$@"
}

# --- Show current chain state ---
info=$(acli getblockchaininfo)
height=$(echo "$info" | python3 -c "import sys,json; print(json.load(sys.stdin)['blocks'])")
headers=$(echo "$info" | python3 -c "import sys,json; print(json.load(sys.stdin)['headers'])")
echo ""
echo -e "${BLUE}Chain state:${NC}"
echo "  Height:  ${height}"
echo "  Headers: ${headers}"
echo "  Fork at: 450000"
echo "  Blocks until fork: $((450000 - height))"

# --- Create wallet and get mining address ---
echo ""
echo -e "${BLUE}Setting up mining wallet...${NC}"
acli createwallet "miner" false false "" false false 2>/dev/null || \
    acli loadwallet "miner" 2>/dev/null || true

mine_addr=$(acli -rpcwallet=miner getnewaddress "" "legacy")
echo "  Mining address: ${mine_addr}"

# --- Stop and restart with mining enabled ---
echo ""
echo -e "${BLUE}Restarting with integrated mining enabled...${NC}"
docker stop "$CONTAINER_NAME" >/dev/null 2>&1
docker rm "$CONTAINER_NAME" >/dev/null 2>&1

# Update config with mining address
cat >> "${CONF_DIR}/alpha.conf" <<CONFEOF

# Mining address (auto-generated)
mine=1
mineaddress=${mine_addr}
CONFEOF

docker run -d --restart unless-stopped \
    --name "$CONTAINER_NAME" \
    --network "$NETWORK_NAME" \
    -p ${P2P_PORT}:${P2P_PORT} \
    -v alpha-data:/root/.alpha \
    -v "${CONF_DIR}:/config" \
    "$IMAGE_NAME" alphad

# Wait for RPC again
echo "  Waiting for RPC..."
deadline=$((SECONDS + 180))
rpc_ready=false
while [ $SECONDS -lt $deadline ]; do
    if docker exec "$CONTAINER_NAME" alpha-cli \
        -chain="$CHAIN" -rpcport="$RPC_PORT" \
        -rpcuser="$RPC_USER" -rpcpassword="$RPC_PASS" \
        getblockchaininfo &>/dev/null; then
        rpc_ready=true
        break
    fi
    sleep 3
done

if ! $rpc_ready; then
    echo -e "${RED}ERROR: Node failed to restart within 180s${NC}"
    docker logs "$CONTAINER_NAME" 2>&1 | tail -30
    exit 1
fi

# --- Final status ---
info=$(acli getblockchaininfo)
height=$(echo "$info" | python3 -c "import sys,json; print(json.load(sys.stdin)['blocks'])")
peer_count=$(acli getconnectioncount 2>/dev/null || echo "0")

echo ""
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}  Alpha Mainnet Fork Miner — Running    ${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""
echo "  Container:    ${CONTAINER_NAME}"
echo "  Image:        ${IMAGE_NAME} (feature/signet-fork-450000)"
echo "  Chain height: ${height}"
echo "  Fork height:  450000"
echo "  Blocks to go: $((450000 - height))"
echo "  Mine address: ${mine_addr}"
echo "  Mine threads: ${MINE_THREADS}"
echo "  Peers:        ${peer_count}"
echo ""
echo "  Useful commands:"
echo "    Logs:    docker logs -f ${CONTAINER_NAME}"
echo "    Height:  docker exec ${CONTAINER_NAME} alpha-cli -chain=${CHAIN} -rpcport=${RPC_PORT} -rpcuser=${RPC_USER} -rpcpassword=${RPC_PASS} getblockcount"
echo "    Info:    docker exec ${CONTAINER_NAME} alpha-cli -chain=${CHAIN} -rpcport=${RPC_PORT} -rpcuser=${RPC_USER} -rpcpassword=${RPC_PASS} getblockchaininfo"
echo "    Mining:  docker exec ${CONTAINER_NAME} alpha-cli -chain=${CHAIN} -rpcport=${RPC_PORT} -rpcuser=${RPC_USER} -rpcpassword=${RPC_PASS} getmininginfo"
echo "    Peers:   docker exec ${CONTAINER_NAME} alpha-cli -chain=${CHAIN} -rpcport=${RPC_PORT} -rpcuser=${RPC_USER} -rpcpassword=${RPC_PASS} getpeerinfo"
echo "    Stop:    docker stop ${CONTAINER_NAME}"
echo ""

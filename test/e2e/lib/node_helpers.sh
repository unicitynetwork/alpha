#!/usr/bin/env bash
# RPC wrappers and node helper functions

# Global mock time tracker (seconds since epoch)
MOCK_TIME=0

# cli <node_index> <rpc_command> [args...]
cli() {
    local node=$1; shift
    docker exec "${CONTAINER_PREFIX}${node}" alpha-cli \
        -chain="${CHAIN}" -rpcport="${RPC_PORT}" \
        -rpcuser="${RPC_USER}" -rpcpassword="${RPC_PASS}" "$@"
}

# wait_for_rpc <node_index> <timeout_seconds>
wait_for_rpc() {
    local node=$1
    local timeout=${2:-120}
    local deadline=$((SECONDS + timeout))
    while [ $SECONDS -lt $deadline ]; do
        if cli "$node" getblockchaininfo &>/dev/null; then
            return 0
        fi
        sleep 2
    done
    echo -e "${RED}ERROR: Node ${node} RPC not ready after ${timeout}s${NC}"
    return 1
}

# get_height <node_index>
get_height() {
    cli "$1" getblockcount
}

# get_best_hash <node_index>
get_best_hash() {
    cli "$1" getbestblockhash
}

# advance_mocktime <seconds_to_add>
# Advances the mock time on ALL nodes to trigger min-difficulty mining.
# alpharegtest uses fPowAllowMinDifficultyBlocks=true, so if a block's
# timestamp is > prev_block_time + 2*target_spacing (4 min), difficulty
# drops to powLimit (trivially easy). We advance by 5 minutes per call.
advance_mocktime() {
    local delta=${1:-300}
    if [ "$MOCK_TIME" -eq 0 ]; then
        # Initialize from current real time
        MOCK_TIME=$(date +%s)
    fi
    MOCK_TIME=$((MOCK_TIME + delta))
    for i in $(seq 0 $((NUM_NODES - 1))); do
        cli "$i" setmocktime "$MOCK_TIME" 2>/dev/null || true
    done
}

# advance_mocktime_nodes <seconds_to_add> <node_indices...>
# Advances mock time on specific nodes only
advance_mocktime_nodes() {
    local delta=$1; shift
    local nodes=("$@")
    if [ "$MOCK_TIME" -eq 0 ]; then
        MOCK_TIME=$(date +%s)
    fi
    MOCK_TIME=$((MOCK_TIME + delta))
    for i in "${nodes[@]}"; do
        cli "$i" setmocktime "$MOCK_TIME" 2>/dev/null || true
    done
}

# sync_blocks <timeout_seconds>
# Waits until all 7 nodes agree on the best block hash
sync_blocks() {
    local timeout=${1:-60}
    local deadline=$((SECONDS + timeout))
    while [ $SECONDS -lt $deadline ]; do
        local hashes=()
        local ok=true
        for i in $(seq 0 $((NUM_NODES - 1))); do
            local h
            h=$(get_best_hash "$i" 2>/dev/null) || { ok=false; break; }
            hashes+=("$h")
        done
        if $ok; then
            local unique
            unique=$(printf '%s\n' "${hashes[@]}" | sort -u | wc -l)
            if [ "$unique" -eq 1 ]; then
                return 0
            fi
        fi
        sleep 1
    done
    echo -e "${RED}ERROR: Nodes did not sync within ${timeout}s${NC}"
    for i in $(seq 0 $((NUM_NODES - 1))); do
        echo "  node${i}: height=$(get_height "$i" 2>/dev/null || echo '?') hash=$(get_best_hash "$i" 2>/dev/null || echo '?')"
    done
    return 1
}

# sync_specific_nodes <timeout_seconds> <node_indices...>
# Waits until specified nodes agree on the best block hash
sync_specific_nodes() {
    local timeout=$1; shift
    local nodes=("$@")
    local deadline=$((SECONDS + timeout))
    while [ $SECONDS -lt $deadline ]; do
        local hashes=()
        local ok=true
        for i in "${nodes[@]}"; do
            local h
            h=$(get_best_hash "$i" 2>/dev/null) || { ok=false; break; }
            hashes+=("$h")
        done
        if $ok; then
            local unique
            unique=$(printf '%s\n' "${hashes[@]}" | sort -u | wc -l)
            if [ "$unique" -eq 1 ]; then
                return 0
            fi
        fi
        sleep 1
    done
    return 1
}

# get_coinbase_value <node_index> <block_height>
# Returns the coinbase output value in BTC
get_coinbase_value() {
    local node=$1
    local height=$2
    local blockhash
    blockhash=$(cli "$node" getblockhash "$height")
    local block_json
    block_json=$(cli "$node" getblock "$blockhash" 2)
    # jq returns 0E-8 for zero values; normalize to fixed decimal
    echo "$block_json" | jq -r '.tx[0].vout[0].value' | awk '{printf "%.8f\n", $1}'
}

# mine_blocks <node_index> <count> [address]
# Mines blocks using mocktime to trigger min-difficulty.
# Each block advances mocktime by 5 minutes so fPowAllowMinDifficultyBlocks kicks in.
mine_blocks() {
    local node=$1
    local count=$2
    local addr=${3:-$(cli "$node" getnewaddress 2>/dev/null || echo "")}
    if [ -z "$addr" ]; then
        addr=$(cli 0 getnewaddress 2>/dev/null || echo "ralpha1qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq6ayzv5")
    fi
    # Mine blocks one at a time, advancing mocktime for each
    for _block_i in $(seq 1 "$count"); do
        advance_mocktime 300
        cli "$node" generatetoaddress 1 "$addr" >/dev/null
    done
}

# connect_nodes <from_node> <to_node>
connect_nodes() {
    local from=$1
    local to=$2
    local to_ip
    to_ip=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "${CONTAINER_PREFIX}${to}")
    cli "$from" addnode "${to_ip}:${P2P_PORT}" "add" 2>/dev/null || true
}

# disconnect_node <from_node> <to_node>
disconnect_node() {
    local from=$1
    local to=$2
    local to_ip
    to_ip=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "${CONTAINER_PREFIX}${to}")
    cli "$from" addnode "${to_ip}:${P2P_PORT}" "remove" 2>/dev/null || true
    cli "$from" disconnectnode "${to_ip}:${P2P_PORT}" 2>/dev/null || true
}

# disconnect_node_from_all <node_index>
# Disconnects a node from all other nodes
disconnect_node_from_all() {
    local node=$1
    for i in $(seq 0 $((NUM_NODES - 1))); do
        if [ "$i" -ne "$node" ]; then
            disconnect_node "$node" "$i"
            disconnect_node "$i" "$node"
        fi
    done
    sleep 1
}

# reconnect_node_to_all <node_index>
# Reconnects a node to all other nodes
reconnect_node_to_all() {
    local node=$1
    for i in $(seq 0 $((NUM_NODES - 1))); do
        if [ "$i" -ne "$node" ]; then
            connect_nodes "$node" "$i"
            connect_nodes "$i" "$node"
        fi
    done
}

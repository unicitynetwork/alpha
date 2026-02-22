#!/usr/bin/env bash
# Docker operations: image build, container start/stop, network management

build_image() {
    echo -e "${BLUE}Building Docker image '${IMAGE_NAME}'...${NC}"
    docker build -t "${IMAGE_NAME}" -f docker/Dockerfile . || {
        echo -e "${RED}Docker image build failed!${NC}"
        exit 1
    }
    echo -e "${GREEN}Image built successfully.${NC}"
}

create_network() {
    echo -e "${BLUE}Creating Docker network '${NETWORK_NAME}'...${NC}"
    docker network create "${NETWORK_NAME}" >/dev/null 2>&1 || true
}

# write_node_config <node_index>
# Generates a per-node alpha.conf in /tmp/alpha-e2e-node<N>/
write_node_config() {
    local node=$1
    local conf_dir="/tmp/alpha-e2e-node${node}"
    mkdir -p "$conf_dir"

    cat > "${conf_dir}/alpha.conf" <<CONFEOF
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
randomxfastmode=1
fallbackfee=0.0001
signetforkheight=${FORK_HEIGHT}
signetforkpubkeys=${PUBKEYS_CSV}
CONFEOF

    # Only authorized nodes (0-4) get the signing key
    if [ "$node" -lt "$NUM_AUTHORIZED" ]; then
        echo "signetblockkey=${WIFS[$node]}" >> "${conf_dir}/alpha.conf"
    fi
}

# start_node <node_index>
start_node() {
    local node=$1
    write_node_config "$node"

    docker run -d \
        --name "${CONTAINER_PREFIX}${node}" \
        --network "${NETWORK_NAME}" \
        -v "/tmp/alpha-e2e-node${node}:/config" \
        "${IMAGE_NAME}" alphad >/dev/null

    echo "  Started node${node}"
}

# start_all_nodes
start_all_nodes() {
    echo -e "${BLUE}Starting ${NUM_NODES} nodes...${NC}"
    for i in $(seq 0 $((NUM_NODES - 1))); do
        start_node "$i"
    done
}

# wait_all_rpc
wait_all_rpc() {
    echo -e "${BLUE}Waiting for all nodes to be RPC-ready...${NC}"
    for i in $(seq 0 $((NUM_NODES - 1))); do
        wait_for_rpc "$i" 120 || {
            echo -e "${RED}Node ${i} failed to start. Logs:${NC}"
            docker logs "${CONTAINER_PREFIX}${i}" 2>&1 | tail -30
            exit 1
        }
    done
    echo -e "${GREEN}All nodes ready.${NC}"
}

# mesh_connect
# Connects all nodes to each other using addnode RPC
mesh_connect() {
    echo -e "${BLUE}Forming mesh topology...${NC}"
    for i in $(seq 0 $((NUM_NODES - 1))); do
        for j in $(seq 0 $((NUM_NODES - 1))); do
            if [ "$i" -ne "$j" ]; then
                connect_nodes "$i" "$j"
            fi
        done
    done
    # Give connections time to establish
    sleep 3
    echo -e "${GREEN}Mesh connected.${NC}"
}

# create_test_wallets
# Creates wallets on all nodes for mining/tx operations
create_test_wallets() {
    echo -e "${BLUE}Creating test wallets on all nodes...${NC}"
    for i in $(seq 0 $((NUM_NODES - 1))); do
        cli "$i" createwallet "test" >/dev/null 2>&1 || true
    done
}

# start_external_miner <node_index>
# Starts the alpha-miner (minerd) inside the given node's container.
# The miner uses getblocktemplate/submitblock to produce blocks.
start_external_miner() {
    local node=$1
    local container="${CONTAINER_PREFIX}${node}"
    local addr
    addr=$(cli "$node" -rpcwallet=test getnewaddress)
    # Write address via stdin to avoid shell injection from RPC-derived values
    echo "$addr" | docker exec -i "$container" sh -c 'cat > /tmp/miner_addrs.txt'
    docker exec -d "$container" sh -c "minerd \
        -o http://127.0.0.1:${RPC_PORT} \
        -O ${RPC_USER}:${RPC_PASS} \
        --afile /tmp/miner_addrs.txt \
        -t 1 --no-affinity \
        > /tmp/minerd.log 2>&1"
}

# stop_external_miner <node_index>
# Stops the alpha-miner inside the given node's container.
stop_external_miner() {
    local node=$1
    local container="${CONTAINER_PREFIX}${node}"
    docker exec "$container" pkill -f minerd 2>/dev/null || true
    sleep 1
    docker exec "$container" pkill -9 -f minerd 2>/dev/null || true
}

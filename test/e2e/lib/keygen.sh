#!/usr/bin/env bash
# Key generation: produces 5 key pairs using a temporary alphad container

generate_keys() {
    echo -e "${BLUE}Generating 5 signing key pairs...${NC}"

    local keygen_container="alpha-e2e-keygen"
    local keygen_conf_dir="/tmp/alpha-e2e-keygen-conf"
    mkdir -p "$keygen_conf_dir"

    cat > "${keygen_conf_dir}/alpha.conf" <<CONFEOF
chain=${CHAIN}
server=1
port=${P2P_PORT}
rpcport=${RPC_PORT}
rpcuser=${RPC_USER}
rpcpassword=${RPC_PASS}
rpcallowip=0.0.0.0/0
rpcbind=0.0.0.0
listen=0
randomxfastmode=1
CONFEOF

    # Start temporary keygen container
    docker run -d \
        --name "$keygen_container" \
        --network "${NETWORK_NAME}" \
        -v "${keygen_conf_dir}:/config" \
        "${IMAGE_NAME}" alphad >/dev/null

    # Wait for RPC
    local deadline=$((SECONDS + 120))
    while [ $SECONDS -lt $deadline ]; do
        if docker exec "$keygen_container" alpha-cli \
            -chain="${CHAIN}" -rpcport="${RPC_PORT}" \
            -rpcuser="${RPC_USER}" -rpcpassword="${RPC_PASS}" \
            getblockchaininfo &>/dev/null; then
            break
        fi
        sleep 2
    done

    # Create a legacy wallet for dumpprivkey support
    docker exec "$keygen_container" alpha-cli \
        -chain="${CHAIN}" -rpcport="${RPC_PORT}" \
        -rpcuser="${RPC_USER}" -rpcpassword="${RPC_PASS}" \
        createwallet "keygen" false false "" false false >/dev/null

    # Generate 5 key pairs
    PUBKEYS=()
    WIFS=()
    for i in $(seq 0 4); do
        local addr
        addr=$(docker exec "$keygen_container" alpha-cli \
            -chain="${CHAIN}" -rpcport="${RPC_PORT}" \
            -rpcuser="${RPC_USER}" -rpcpassword="${RPC_PASS}" \
            -rpcwallet=keygen getnewaddress "" "legacy")

        local info_json
        info_json=$(docker exec "$keygen_container" alpha-cli \
            -chain="${CHAIN}" -rpcport="${RPC_PORT}" \
            -rpcuser="${RPC_USER}" -rpcpassword="${RPC_PASS}" \
            -rpcwallet=keygen getaddressinfo "$addr")

        local pubkey
        pubkey=$(echo "$info_json" | jq -r '.pubkey')
        PUBKEYS+=("$pubkey")

        local wif
        wif=$(docker exec "$keygen_container" alpha-cli \
            -chain="${CHAIN}" -rpcport="${RPC_PORT}" \
            -rpcuser="${RPC_USER}" -rpcpassword="${RPC_PASS}" \
            -rpcwallet=keygen dumpprivkey "$addr")
        WIFS+=("$wif")

        echo "  Key ${i}: pubkey=${pubkey:0:16}..."
    done

    # Build comma-separated pubkey list
    PUBKEYS_CSV=$(IFS=,; echo "${PUBKEYS[*]}")

    # Stop and remove keygen container
    docker rm -f "$keygen_container" >/dev/null 2>&1 || true
    rm -rf "$keygen_conf_dir"

    echo -e "${GREEN}Key generation complete.${NC}"
}

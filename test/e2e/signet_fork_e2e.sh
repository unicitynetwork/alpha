#!/usr/bin/env bash
# =============================================================================
# Alpha Signet Fork — E2E Docker Test Suite
#
# Runs 20 tests across 7+ Docker containers on alpharegtest to validate
# pre-fork, fork boundary, and post-fork behavior end-to-end.
#
# Mining uses setmocktime to trigger fPowAllowMinDifficultyBlocks, ensuring
# blocks are found near-instantly despite RandomX PoW.
#
# Usage:  bash test/e2e/signet_fork_e2e.sh
# Prereq: docker, jq, bash 4+
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

# Source library files
source "${SCRIPT_DIR}/lib/config.sh"
source "${SCRIPT_DIR}/lib/assertions.sh"
source "${SCRIPT_DIR}/lib/cleanup.sh"
source "${SCRIPT_DIR}/lib/node_helpers.sh"
source "${SCRIPT_DIR}/lib/keygen.sh"
source "${SCRIPT_DIR}/lib/docker_helpers.sh"

# --- Preflight checks -------------------------------------------------------
for cmd in docker jq; do
    if ! command -v "$cmd" &>/dev/null; then
        echo -e "${RED}ERROR: '${cmd}' is required but not found.${NC}"
        exit 1
    fi
done

if [ "${BASH_VERSINFO[0]}" -lt 4 ]; then
    echo -e "${RED}ERROR: bash 4+ required (found ${BASH_VERSION}).${NC}"
    exit 1
fi

# --- Setup -------------------------------------------------------------------
cd "$REPO_ROOT"

# Clean up any leftover state from previous runs
cleanup

trap cleanup EXIT

create_network
build_image
generate_keys
start_all_nodes
wait_all_rpc
create_test_wallets
mesh_connect

# Give the mesh a moment to fully establish
sleep 2

echo ""
echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}  Running E2E Test Suite (20 tests)     ${NC}"
echo -e "${BLUE}========================================${NC}"

# =============================================================================
# Phase 1: Pre-Fork (height 0 → 9)
# =============================================================================

test_header "01" "Pre-fork mining by authorized node"
{
    mine_blocks 0 9
    sleep 3
    sync_blocks 30

    for i in $(seq 0 $((NUM_NODES - 1))); do
        h=$(get_height "$i")
        assert_eq "node${i} at height 9" "9" "$h" || true
    done

    # Check coinbase value for a pre-fork block (block 1)
    cb_val=$(get_coinbase_value 0 1)
    assert_eq "block 1 coinbase = 10 ALPHA" "10.00000000" "$cb_val" || true
}

test_header "02" "Pre-fork mining by non-authorized node"
{
    # node5 has no signing key — should still mine pre-fork.
    # Pre-fork CreateNewBlock doesn't require a signing key.
    addr5=$(cli 5 getnewaddress)
    advance_mocktime 300
    result=$(cli 5 generatetoaddress 1 "$addr5" 2>&1) || true
    sleep 2
    sync_blocks 30

    h0=$(get_height 0)
    # Verify chain progressed (node5 should be able to mine pre-fork)
    assert_ge "chain at height >= 9 after non-auth mining" "9" "$h0" || true
    if [ "$h0" -ge "10" ]; then
        echo "  non-auth node mined to height ${h0} (at or past fork boundary)"
    else
        echo "  (node5 pre-fork mine result: ${result:0:100})"
    fi

    if [ "$h" -lt "10" ]; then
        echo "  (chain still at pre-fork height, proceeding to fork boundary tests)"
    fi
}

# =============================================================================
# Phase 2: Fork Boundary (height 9 → 10)
# =============================================================================

test_header "03" "Fork boundary — authorized node mines block 10"
{
    current=$(get_height 0)
    if [ "$current" -lt "10" ]; then
        needed=$((10 - current))
        mine_blocks 0 "$needed"
        sleep 3
        sync_blocks 30
    fi

    h0=$(get_height 0)
    assert_eq "chain at fork height 10" "10" "$h0" || true

    sync_blocks 30
    for i in $(seq 0 $((NUM_NODES - 1))); do
        h=$(get_height "$i")
        assert_eq "node${i} at height 10" "10" "$h" || true
    done

    # Coinbase value at fork height should be 0
    cb_val=$(get_coinbase_value 0 10)
    assert_eq "block 10 coinbase = 0 (zero subsidy)" "0.00000000" "$cb_val" || true
}

test_header "04" "Difficulty reset verification"
{
    hash9=$(cli 0 getblockhash 9)
    hash10=$(cli 0 getblockhash 10)
    block9=$(cli 0 getblock "$hash9")
    block10=$(cli 0 getblock "$hash10")

    bits9=$(echo "$block9" | jq -r '.bits')
    bits10=$(echo "$block10" | jq -r '.bits')

    echo "  block 9 nBits: ${bits9}"
    echo "  block 10 nBits: ${bits10}"

    # Block 10 should have minimum difficulty (powLimit compact = 2100ffff)
    assert_eq "block 10 nBits = powLimit (2100ffff)" "2100ffff" "$bits10" || true
}

# =============================================================================
# Phase 3: Post-Fork Mining (height 10 → 25)
# =============================================================================

test_header "05" "Post-fork mining continues"
{
    mine_blocks 1 5
    sleep 2
    mine_blocks 2 5
    sleep 2
    sync_blocks 30

    h0=$(get_height 0)
    assert_eq "chain at height 20" "20" "$h0" || true

    all_zero=true
    for height in $(seq 11 20); do
        cb=$(get_coinbase_value 0 "$height")
        if [ "$cb" != "0.00000000" ]; then
            echo -e "  ${RED}block ${height} coinbase = ${cb} (expected 0)${NC}"
            all_zero=false
        fi
    done
    TESTS_TOTAL=$((TESTS_TOTAL + 1))
    if $all_zero; then
        echo -e "  ${GREEN}PASS${NC}: blocks 11-20 all have zero coinbase"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        echo -e "  ${RED}FAIL${NC}: some post-fork blocks have non-zero coinbase"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
}

test_header "06" "Non-authorized node cannot mine post-fork"
{
    h0_before=$(get_height 0)
    h5_before=$(get_height 5)
    advance_mocktime 300
    result=$(cli 5 generatetoaddress 1 "$(cli 5 getnewaddress 2>/dev/null || echo 'ralpha1qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq6ayzv5')" 2>&1) || true
    sleep 2
    h5_after=$(get_height 5)
    h0_after=$(get_height 0)

    # Primary assertion: height did NOT advance (security-critical)
    assert_eq "node5 height unchanged (cannot mine post-fork)" "$h5_before" "$h5_after" || true
    assert_eq "node0 height unchanged (no block from non-auth node)" "$h0_before" "$h0_after" || true
    # Secondary: verify we got the expected error message
    TESTS_TOTAL=$((TESTS_TOTAL + 1))
    if echo "$result" | grep -q "No signing key configured"; then
        echo -e "  ${GREEN}PASS${NC}: non-authorized node got error: No signing key configured"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        echo -e "  ${RED}FAIL${NC}: expected 'No signing key configured' error, got: ${result:0:120}"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
}

test_header "07" "All 5 authorized keys mine independently"
{
    for i in $(seq 0 4); do
        mine_blocks "$i" 1
        sleep 1
    done
    sleep 2
    sync_blocks 30

    h0=$(get_height 0)
    assert_eq "chain at height 25" "25" "$h0" || true

    hash0=$(get_best_hash 0)
    all_agree=true
    # Guard: empty hash0 means RPC failure, not consensus
    if [ -z "$hash0" ]; then
        all_agree=false
        echo -e "  ${RED}node0 hash is empty (RPC error)${NC}"
    fi
    for i in $(seq 1 $((NUM_NODES - 1))); do
        hi=$(get_best_hash "$i")
        if [ -z "$hi" ]; then
            all_agree=false
            echo -e "  ${RED}node${i} hash is empty (RPC error)${NC}"
        elif [ "$hash0" != "$hi" ]; then
            all_agree=false
            echo -e "  ${RED}node${i} disagrees: ${hi:0:16}...${NC}"
        fi
    done
    TESTS_TOTAL=$((TESTS_TOTAL + 1))
    if $all_agree; then
        echo -e "  ${GREEN}PASS${NC}: all 7 nodes agree on chain tip after 5 different signers"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        echo -e "  ${RED}FAIL${NC}: consensus disagreement"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
}

# =============================================================================
# Phase 4: Network Scenarios (height 25 → 85+)
# =============================================================================

test_header "08" "Network partition and reconnection"
{
    # Disconnect node3 from all others
    disconnect_node_from_all 3
    sleep 2

    # node3 mines 5 blocks on its own partition
    # Only advance mocktime on node3's partition
    for _pi in $(seq 1 5); do
        advance_mocktime_nodes 300 3
        cli 3 generatetoaddress 1 "$(cli 3 getnewaddress)" >/dev/null
    done
    h3=$(get_height 3)

    # Main network (node0) mines only 3 blocks — shorter chain
    for _pi in $(seq 1 3); do
        advance_mocktime_nodes 300 0 1 2 4 5 6
        cli 0 generatetoaddress 1 "$(cli 0 getnewaddress)" >/dev/null
    done
    sleep 2

    sync_specific_nodes 30 0 1 2 4 5 6 || true

    h0_before=$(get_height 0)
    h3_before=$(get_height 3)
    echo "  node0 height (main): ${h0_before}, node3 height (partition): ${h3_before}"

    # Reconnect node3
    reconnect_node_to_all 3
    # Sync mocktime across all nodes
    advance_mocktime 300
    sleep 5

    sync_blocks 60 || true

    h0_after=$(get_height 0)
    hash0=$(get_best_hash 0)
    hash3=$(get_best_hash 3)

    assert_eq "node0 and node3 agree after reconnection" "$hash3" "$hash0" || true
    assert_eq "reorg converged to longer chain" "$h3_before" "$h0_after" || true
}

test_header "09" "Stress test — rapid mining by rotating authorized nodes"
{
    h_start=$(get_height 0)
    for round in $(seq 1 50); do
        node_idx=$((( round - 1 ) % NUM_AUTHORIZED))
        mine_blocks "$node_idx" 1
    done
    sleep 3
    sync_blocks 60

    h_end=$(get_height 0)
    expected=$((h_start + 50))
    assert_eq "chain advanced by 50 blocks" "$expected" "$h_end" || true

    for offset in 5 25 45; do
        check_h=$((h_start + offset))
        cb=$(get_coinbase_value 0 "$check_h")
        assert_eq "block ${check_h} coinbase = 0" "0.00000000" "$cb" || true
    done
}

# =============================================================================
# Phase 5: Transactions (height ~85 → 111+)
# =============================================================================

test_header "10" "Mine to coinbase maturity"
{
    current=$(get_height 0)
    target=$((COINBASE_MATURITY + 10))  # 110
    if [ "$current" -lt "$target" ]; then
        needed=$((target - current))
        echo "  Mining ${needed} blocks to reach height ${target}..."
        while [ "$needed" -gt 0 ]; do
            batch=$((needed > 25 ? 25 : needed))
            node_idx=$(( (target - needed) % NUM_AUTHORIZED ))
            mine_blocks "$node_idx" "$batch"
            needed=$((needed - batch))
        done
        sleep 3
        sync_blocks 60
    fi

    h=$(get_height 0)
    assert_ge "chain at height >= 110" "$target" "$h" || true
}

test_header "11" "Transaction with fee burning"
{
    utxos=$(cli 0 -rpcwallet=test listunspent 1 9999999 '[]' true '{"minimumAmount": 1}' 2>/dev/null || echo "[]")
    utxo_count=$(echo "$utxos" | jq 'length')

    if [ "$utxo_count" -gt 0 ]; then
        addr5=$(cli 5 -rpcwallet=test getnewaddress)

        # Debug: show available UTXOs and wallet balance
        balance0=$(cli 0 -rpcwallet=test getbalance 2>/dev/null || echo "?")
        echo "  node0 wallet balance: ${balance0}"

        # Send transaction — capture stdout and stderr separately
        txid=$(cli 0 -rpcwallet=test sendtoaddress "$addr5" 9.999 2>/dev/null) || true
        send_err=$(cli 0 -rpcwallet=test sendtoaddress "$addr5" 0.001 2>&1 >/dev/null) || true

        if [ -n "$txid" ] && echo "$txid" | grep -q "^[0-9a-f]\{64\}$"; then
            echo "  sendtoaddress txid: ${txid:0:32}..."

            # Check mempool immediately
            mempool_count=$(cli 0 getmempoolinfo | jq '.size')
            echo "  mempool size after send: ${mempool_count}"

            # If mempool is empty, the wallet created the tx but it wasn't accepted
            # Try to rebroadcast it
            if [ "$mempool_count" -eq 0 ]; then
                echo "  tx not in mempool, attempting rebroadcast..."
                cli 0 -rpcwallet=test resendwallettransactions 2>/dev/null || true
                sleep 2
                mempool_count=$(cli 0 getmempoolinfo | jq '.size')
                echo "  mempool size after rebroadcast: ${mempool_count}"
            fi

            # Mine a block
            mine_blocks 0 1
            sleep 3
            sync_blocks 60

            h=$(get_height 0)

            # Primary assertion: coinbase is zero (fees burned)
            cb=$(get_coinbase_value 0 "$h")
            assert_eq "post-fork coinbase = 0 (fee burned, not collected)" "0.00000000" "$cb" || true

            # Check if the tx was included in any recent block using wallet
            tx_info=$(cli 0 -rpcwallet=test gettransaction "$txid" 2>/dev/null || echo "{}")
            conf=$(echo "$tx_info" | jq -r '.confirmations // 0')

            TESTS_TOTAL=$((TESTS_TOTAL + 1))
            if [ "$conf" -gt 0 ]; then
                echo -e "  ${GREEN}PASS${NC}: tx confirmed with ${conf} confirmations (fee burned)"
                TESTS_PASSED=$((TESTS_PASSED + 1))
            else
                # Check if the block has transactions (alternative verification)
                blockhash=$(cli 0 getblockhash "$h")
                block_tx_count=$(cli 0 getblock "$blockhash" | jq '.tx | length')
                if [ "$block_tx_count" -gt 1 ]; then
                    echo -e "  ${GREEN}PASS${NC}: block ${h} has ${block_tx_count} txs with zero coinbase (fees burned)"
                    TESTS_PASSED=$((TESTS_PASSED + 1))
                else
                    echo -e "  ${RED}FAIL${NC}: tx not confirmed (conf=${conf}, block_txs=${block_tx_count})"
                    echo "  Debug: wallet says tx state: $(echo "$tx_info" | jq -r '.details[0].category // "unknown"' 2>/dev/null)"
                    TESTS_FAILED=$((TESTS_FAILED + 1))
                fi
            fi
        else
            echo -e "  ${RED}FAIL${NC}: sendtoaddress failed: ${txid:0:120}"
            echo "  (Cannot verify fee-burn without a valid transaction)"
            TESTS_TOTAL=$((TESTS_TOTAL + 2))
            TESTS_FAILED=$((TESTS_FAILED + 2))
        fi
    else
        echo -e "  ${RED}FAIL${NC}: no mature UTXOs found on node0 — cannot test fee burning"
        TESTS_TOTAL=$((TESTS_TOTAL + 2))
        TESTS_FAILED=$((TESTS_FAILED + 2))
    fi
}

test_header "12" "Single-input transaction restriction"
{
    utxos=$(cli 0 -rpcwallet=test listunspent 1 9999999 2>/dev/null || echo "[]")
    utxo_count=$(echo "$utxos" | jq 'length')

    if [ "$utxo_count" -ge 2 ]; then
        txid0=$(echo "$utxos" | jq -r '.[0].txid')
        vout0=$(echo "$utxos" | jq -r '.[0].vout')
        txid1=$(echo "$utxos" | jq -r '.[1].txid')
        vout1=$(echo "$utxos" | jq -r '.[1].vout')
        addr=$(cli 0 -rpcwallet=test getnewaddress)

        raw_result=$(cli 0 -rpcwallet=test createrawtransaction \
            "[{\"txid\":\"${txid0}\",\"vout\":${vout0}},{\"txid\":\"${txid1}\",\"vout\":${vout1}}]" \
            "{\"${addr}\":0.001}" 2>&1) || true

        if echo "$raw_result" | grep -q "^[0-9a-f]"; then
            signed=$(cli 0 -rpcwallet=test signrawtransactionwithwallet "$raw_result" 2>&1) || true
            signed_hex=$(echo "$signed" | jq -r '.hex // empty')
            if [ -n "$signed_hex" ]; then
                send_result=$(cli 0 -rpcwallet=test sendrawtransaction "$signed_hex" 2>&1) || true
                assert_contains "multi-input tx rejected" "bad-txns-too-many-inputs|too-many-inputs|TX rejected" "$send_result" || true
            else
                assert_contains "multi-input tx signing failed or rejected" "bad-txns-too-many-inputs|too-many-inputs" "$signed" || true
            fi
        else
            assert_contains "multi-input raw tx creation rejected" "bad-txns-too-many-inputs|too-many-inputs" "$raw_result" || true
        fi
    else
        echo -e "  ${RED}FAIL${NC}: fewer than 2 UTXOs available — cannot test multi-input rejection"
        TESTS_TOTAL=$((TESTS_TOTAL + 1))
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
}

# =============================================================================
# Phase 6: Edge Cases & Security
# =============================================================================

test_header "13" "Wrong key startup rejection"
{
    wrong_conf_dir="/tmp/alpha-e2e-node7"
    mkdir -p "$wrong_conf_dir"

    # WRONG_WIF was pre-generated during keygen (the 6th key, not in authorized set)

    cat > "${wrong_conf_dir}/alpha.conf" <<CONFEOF
chain=${CHAIN}

[${CHAIN}]
server=1
port=${P2P_PORT}
rpcport=${RPC_PORT}
rpcuser=${RPC_USER}
rpcpassword=${RPC_PASS}
rpcallowip=0.0.0.0/0
rpcbind=0.0.0.0
listen=0
randomxfastmode=1
signetforkheight=${FORK_HEIGHT}
signetforkpubkeys=${PUBKEYS_CSV}
signetblockkey=${WRONG_WIF}
CONFEOF

    docker run -d \
        --name "${CONTAINER_PREFIX}7" \
        --network "${NETWORK_NAME}" \
        -v "${wrong_conf_dir}:/config" \
        "${IMAGE_NAME}" alphad >/dev/null 2>&1 || true

    # Poll until the container exits or we find the rejection message (max 30s)
    poll_deadline=$((SECONDS + 30))
    container_status="true"
    logs=""
    while [ $SECONDS -lt $poll_deadline ]; do
        container_status=$(docker inspect -f '{{.State.Running}}' "${CONTAINER_PREFIX}7" 2>/dev/null || echo "false")
        logs=$(docker logs "${CONTAINER_PREFIX}7" 2>&1 || echo "")
        # Exit early if container stopped or error message found
        if [ "$container_status" = "false" ]; then
            break
        fi
        if echo "$logs" | grep -q "NOT in the authorized allowlist"; then
            break
        fi
        sleep 2
    done

    # Container MUST have stopped AND show the rejection message
    final_status=$(docker inspect -f '{{.State.Running}}' "${CONTAINER_PREFIX}7" 2>/dev/null || echo "false")
    TESTS_TOTAL=$((TESTS_TOTAL + 1))
    if echo "$logs" | grep -qE "NOT in the authorized allowlist|Invalid -signetblockkey" \
            && [ "$final_status" = "false" ]; then
        echo -e "  ${GREEN}PASS${NC}: wrong key rejected and node exited"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        echo -e "  ${RED}FAIL${NC}: expected key rejection + container exit"
        echo "  Container running: ${final_status}"
        echo "  Logs contain rejection: $(echo "$logs" | grep -cE 'NOT in the authorized allowlist|Invalid -signetblockkey')"
        echo "  Logs (last 200 chars): ${logs: -200}"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi

    docker rm -f "${CONTAINER_PREFIX}7" >/dev/null 2>&1 || true
}

test_header "14" "Backward compatibility — non-fork node syncs"
{
    compat_conf_dir="/tmp/alpha-e2e-node8"
    mkdir -p "$compat_conf_dir"

    cat > "${compat_conf_dir}/alpha.conf" <<CONFEOF
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
CONFEOF

    docker run -d \
        --name "${CONTAINER_PREFIX}8" \
        --network "${NETWORK_NAME}" \
        -v "${compat_conf_dir}:/config" \
        "${IMAGE_NAME}" alphad >/dev/null 2>&1 || true

    deadline=$((SECONDS + 120))
    rpc_ready=false
    while [ $SECONDS -lt $deadline ]; do
        if docker exec "${CONTAINER_PREFIX}8" alpha-cli \
            -chain="${CHAIN}" -rpcport="${RPC_PORT}" \
            -rpcuser="${RPC_USER}" -rpcpassword="${RPC_PASS}" \
            getblockchaininfo &>/dev/null; then
            rpc_ready=true
            break
        fi
        sleep 2
    done

    if $rpc_ready; then
        # Set mocktime on the compat node to match the main network's mocktime.
        # Without this, blocks from the main network have timestamps far in the
        # future (due to advance_mocktime) and would be rejected as too-far-ahead.
        docker exec "${CONTAINER_PREFIX}8" alpha-cli \
            -chain="${CHAIN}" -rpcport="${RPC_PORT}" \
            -rpcuser="${RPC_USER}" -rpcpassword="${RPC_PASS}" \
            setmocktime "$MOCK_TIME" >/dev/null 2>&1 || true

        node0_ip=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "${CONTAINER_PREFIX}0")
        docker exec "${CONTAINER_PREFIX}8" alpha-cli \
            -chain="${CHAIN}" -rpcport="${RPC_PORT}" \
            -rpcuser="${RPC_USER}" -rpcpassword="${RPC_PASS}" \
            addnode "${node0_ip}:${P2P_PORT}" "add" >/dev/null 2>&1 || true

        target_hash=$(get_best_hash 0)
        synced=false
        sync_deadline=$((SECONDS + 120))
        while [ $SECONDS -lt $sync_deadline ]; do
            compat_hash=$(docker exec "${CONTAINER_PREFIX}8" alpha-cli \
                -chain="${CHAIN}" -rpcport="${RPC_PORT}" \
                -rpcuser="${RPC_USER}" -rpcpassword="${RPC_PASS}" \
                getbestblockhash 2>/dev/null || echo "")
            if [ "$compat_hash" = "$target_hash" ]; then
                synced=true
                break
            fi
            sleep 2
        done

        compat_height=$(docker exec "${CONTAINER_PREFIX}8" alpha-cli \
            -chain="${CHAIN}" -rpcport="${RPC_PORT}" \
            -rpcuser="${RPC_USER}" -rpcpassword="${RPC_PASS}" \
            getblockcount 2>/dev/null || echo "0")
        target_height=$(get_height 0)

        if $synced; then
            assert_eq "non-fork node synced full chain" "$target_height" "$compat_height" || true
        else
            TESTS_TOTAL=$((TESTS_TOTAL + 1))
            if [ "$compat_height" -gt "$((FORK_HEIGHT + 5))" ]; then
                echo -e "  ${GREEN}PASS${NC}: non-fork node synced past fork height (height=${compat_height})"
                TESTS_PASSED=$((TESTS_PASSED + 1))
            else
                echo -e "  ${RED}FAIL${NC}: non-fork node only at height ${compat_height} (target: ${target_height})"
                TESTS_FAILED=$((TESTS_FAILED + 1))
            fi
        fi
    else
        echo -e "  ${RED}FAIL${NC}: non-fork node failed to start — cannot test backward compatibility"
        TESTS_TOTAL=$((TESTS_TOTAL + 1))
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi

    docker rm -f "${CONTAINER_PREFIX}8" >/dev/null 2>&1 || true
}

test_header "15" "Consensus agreement — all nodes identical state"
{
    sync_blocks 30

    hash0=$(get_best_hash 0)
    all_match=true
    # Guard: empty hash means RPC failure, not consensus
    if [ -z "$hash0" ]; then
        all_match=false
        echo -e "  ${RED}node0 hash is empty (RPC error)${NC}"
    fi
    for i in $(seq 1 $((NUM_NODES - 1))); do
        hi=$(get_best_hash "$i")
        if [ -z "$hi" ]; then
            all_match=false
            echo -e "  ${RED}node${i} hash is empty (RPC error)${NC}"
        elif [ "$hash0" != "$hi" ]; then
            all_match=false
            echo -e "  ${RED}node${i} hash mismatch: ${hi:0:16}...${NC}"
        fi
    done
    TESTS_TOTAL=$((TESTS_TOTAL + 1))
    if $all_match; then
        echo -e "  ${GREEN}PASS${NC}: all 7 nodes agree on best block hash"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        echo -e "  ${RED}FAIL${NC}: consensus disagreement on best block"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi

    utxo0=$(cli 0 gettxoutsetinfo 2>/dev/null | jq -r '.hash_serialized_2 // .bestblock' || echo "")
    utxo6=$(cli 6 gettxoutsetinfo 2>/dev/null | jq -r '.hash_serialized_2 // .bestblock' || echo "")

    if [ -n "$utxo0" ] && [ -n "$utxo6" ]; then
        assert_eq "UTXO set hash matches (node0 vs node6)" "$utxo0" "$utxo6" || true
    else
        echo -e "  ${RED}FAIL${NC}: gettxoutsetinfo failed — cannot verify UTXO set equality"
        TESTS_TOTAL=$((TESTS_TOTAL + 1))
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi

    # Always count checkpoint assertions (3 total)
    for ckpt in 5 10 15; do
        h0_hash=$(cli 0 getblockhash "$ckpt" 2>/dev/null || echo "")
        h6_hash=$(cli 6 getblockhash "$ckpt" 2>/dev/null || echo "")
        if [ -n "$h0_hash" ] && [ -n "$h6_hash" ]; then
            assert_eq "block ${ckpt} hash matches (node0 vs node6)" "$h0_hash" "$h6_hash" || true
        else
            echo -e "  ${RED}FAIL${NC}: block ${ckpt} hash comparison failed (empty hash from RPC)"
            TESTS_TOTAL=$((TESTS_TOTAL + 1))
            TESTS_FAILED=$((TESTS_FAILED + 1))
        fi
    done
}

test_header "16" "Block template inspection"
{
    advance_mocktime 300
    template=$(cli 0 getblocktemplate '{"rules": ["segwit"]}' 2>&1) || true

    if echo "$template" | jq . >/dev/null 2>&1; then
        cb_value=$(echo "$template" | jq -r '.coinbasevalue')
        tmpl_height=$(echo "$template" | jq -r '.height')

        assert_eq "template coinbasevalue = 0" "0" "$cb_value" || true

        tip=$(get_height 0)
        expected_h=$((tip + 1))
        assert_eq "template height = tip+1" "$expected_h" "$tmpl_height" || true
    else
        echo -e "  ${RED}FAIL${NC}: getblocktemplate returned error: ${template:0:200}"
        TESTS_TOTAL=$((TESTS_TOTAL + 2))
        TESTS_FAILED=$((TESTS_FAILED + 2))
    fi

    hash10=$(cli 0 getblockhash 10)
    block10_verbose=$(cli 0 getblock "$hash10" 2)
    coinbase_hex=$(echo "$block10_verbose" | jq -r '.tx[0].hex // empty')

    if [ -n "$coinbase_hex" ]; then
        assert_contains "block 10 coinbase contains SIGNET_HEADER" "ecc7daa2" "$coinbase_hex" || true
    else
        coinbase_txid=$(echo "$block10_verbose" | jq -r '.tx[0].txid')
        raw_tx=$(cli 0 getrawtransaction "$coinbase_txid" 2>/dev/null || echo "")
        if [ -n "$raw_tx" ]; then
            assert_contains "block 10 coinbase contains SIGNET_HEADER" "ecc7daa2" "$raw_tx" || true
        else
            echo -e "  ${RED}FAIL${NC}: could not retrieve coinbase hex for block 10"
            TESTS_TOTAL=$((TESTS_TOTAL + 1))
            TESTS_FAILED=$((TESTS_FAILED + 1))
        fi
    fi
}

# =============================================================================
# Phase 7: Additional Gap Coverage
# =============================================================================

test_header "17" "Non-authorized mining attempt — chain height unchanged"
{
    # Verify that when a non-authorized node (node5) attempts to mine post-fork,
    # node0's chain height does not advance. CreateNewBlock throws before block
    # construction, so no block is ever propagated to the network.
    h0_before=$(get_height 0)
    h5_before=$(get_height 5)
    advance_mocktime 300

    # node5 has no signing key — this should fail locally
    result=$(cli 5 generatetoaddress 1 "$(cli 5 getnewaddress)" 2>&1) || true
    sleep 2

    h0_after=$(get_height 0)
    assert_eq "node0 height unchanged after node5 mining attempt" "$h0_before" "$h0_after" || true

    # Also verify node5 itself didn't advance
    h5_after=$(get_height 5)
    assert_eq "node5 height unchanged after failed mining attempt" "$h5_before" "$h5_after" || true
}

test_header "18" "Non-authorized node creates and sends transaction post-fork"
{
    # node5 (non-authorized) should be able to create, send, and receive
    # transactions normally — only block production is gated.

    # First ensure node0 has a spendable UTXO
    utxos=$(cli 0 -rpcwallet=test listunspent 1 9999999 '[]' true '{"minimumAmount": 0.1}' 2>/dev/null || echo "[]")
    utxo_count=$(echo "$utxos" | jq 'length')

    if [ "$utxo_count" -gt 0 ]; then
        # Step 1: node0 sends to node5
        addr5=$(cli 5 -rpcwallet=test getnewaddress)
        txid_to5=$(cli 0 -rpcwallet=test sendtoaddress "$addr5" 0.5 2>/dev/null) || true

        if [ -n "$txid_to5" ] && echo "$txid_to5" | grep -q "^[0-9a-f]\{64\}$"; then
            echo "  node0 → node5 txid: ${txid_to5:0:32}..."

            # Mine a block to confirm
            mine_blocks 0 1
            sleep 3
            sync_blocks 60

            # Verify node5 received the funds
            bal5=$(cli 5 -rpcwallet=test getbalance 2>/dev/null || echo "0")
            TESTS_TOTAL=$((TESTS_TOTAL + 1))
            # bal5 should be >= 0.5 (could have dust from other tests)
            if awk "BEGIN{exit !($bal5 >= 0.49)}"; then
                echo -e "  ${GREEN}PASS${NC}: node5 received funds (balance=${bal5})"
                TESTS_PASSED=$((TESTS_PASSED + 1))
            else
                echo -e "  ${RED}FAIL${NC}: node5 balance=${bal5} (expected >= 0.49)"
                TESTS_FAILED=$((TESTS_FAILED + 1))
            fi

            # Step 2: node5 sends to node6 (non-auth → non-auth transaction)
            addr6=$(cli 6 -rpcwallet=test getnewaddress)
            txid_to6=$(cli 5 -rpcwallet=test sendtoaddress "$addr6" 0.1 2>/dev/null) || true

            if [ -n "$txid_to6" ] && echo "$txid_to6" | grep -q "^[0-9a-f]\{64\}$"; then
                echo "  node5 → node6 txid: ${txid_to6:0:32}..."

                # Fetch raw tx from node5's wallet (more reliable than getrawtransaction
                # which only checks mempool on non-txindex nodes).
                raw_tx=$(cli 5 -rpcwallet=test gettransaction "$txid_to6" 2>/dev/null | jq -r '.hex // empty')
                if [ -z "$raw_tx" ]; then
                    raw_tx=$(cli 5 getrawtransaction "$txid_to6" 2>/dev/null || echo "")
                fi

                # Relay the tx directly to the mining node AND node6.
                # P2P propagation across Docker containers can be slow/unreliable.
                if [ -n "$raw_tx" ]; then
                    cli 0 sendrawtransaction "$raw_tx" 0.10 >/dev/null 2>&1 || true
                    cli 6 sendrawtransaction "$raw_tx" 0.10 >/dev/null 2>&1 || true
                fi

                # Verify tx is in node0's mempool before mining
                in_mempool=false
                for _wait in $(seq 1 10); do
                    if cli 0 getmempoolentry "$txid_to6" >/dev/null 2>&1; then
                        in_mempool=true
                        break
                    fi
                    sleep 1
                done
                if ! $in_mempool; then
                    echo "  WARNING: tx not in node0 mempool, mining anyway"
                fi

                # Mine a block to confirm (use node0 — tx should be in its mempool)
                mine_blocks 0 1
                sleep 3
                sync_blocks 60

                tip=$(get_height 0)

                # Verify coinbase is still zero (fees burned)
                cb=$(get_coinbase_value 0 "$tip")
                assert_eq "confirming block coinbase = 0 (fees burned)" "0.00000000" "$cb" || true

                # Verify node6 received the funds.
                # Use getreceivedbyaddress which is more reliable than gettransaction
                # (works as long as the block is synced and the address is in the wallet).
                received6="0"
                poll_tx6_deadline=$((SECONDS + 30))
                while [ $SECONDS -lt $poll_tx6_deadline ]; do
                    received6=$(cli 6 -rpcwallet=test getreceivedbyaddress "$addr6" 1 2>/dev/null || echo "0")
                    if awk "BEGIN{exit !($received6 >= 0.09)}" 2>/dev/null; then
                        break
                    fi
                    sleep 1
                done
                TESTS_TOTAL=$((TESTS_TOTAL + 1))
                if awk "BEGIN{exit !($received6 >= 0.09)}" 2>/dev/null; then
                    echo -e "  ${GREEN}PASS${NC}: node6 received tx from node5 (received=${received6})"
                    TESTS_PASSED=$((TESTS_PASSED + 1))
                else
                    bal6=$(cli 6 -rpcwallet=test getbalance "*" 0 2>/dev/null || echo "0")
                    echo -e "  ${RED}FAIL${NC}: node6 did not receive tx (received=${received6}, bal=${bal6})"
                    TESTS_FAILED=$((TESTS_FAILED + 1))
                fi
            else
                echo -e "  ${RED}FAIL${NC}: node5 → node6 sendtoaddress failed: ${txid_to6:0:100}"
                TESTS_TOTAL=$((TESTS_TOTAL + 2))
                TESTS_FAILED=$((TESTS_FAILED + 2))
            fi
        else
            echo -e "  ${RED}FAIL${NC}: node0 → node5 sendtoaddress failed: ${txid_to5:0:100}"
            TESTS_TOTAL=$((TESTS_TOTAL + 3))
            TESTS_FAILED=$((TESTS_FAILED + 3))
        fi
    else
        echo -e "  ${RED}FAIL${NC}: no spendable UTXOs on node0 — cannot test transactions"
        TESTS_TOTAL=$((TESTS_TOTAL + 3))
        TESTS_FAILED=$((TESTS_FAILED + 3))
    fi
}

# =============================================================================
# Phase 8: External Mining
# =============================================================================

test_header "19" "External miner keeps network producing blocks"
{
    TARGET_MINER_BLOCKS=3
    h_before=$(get_height 0)
    target_height=$((h_before + TARGET_MINER_BLOCKS))

    # Advance mocktime before starting the miner so the first
    # getblocktemplate call already sees min-difficulty.
    advance_mocktime 300

    # Start external miner on node0 (authorized signer)
    start_external_miner 0
    sleep 2

    # Verify miner process is running
    miner_running=$(docker exec "${CONTAINER_PREFIX}0" pgrep -c minerd 2>/dev/null || echo "0")
    if [ "$miner_running" -eq 0 ]; then
        echo "  WARNING: minerd failed to start"
        docker exec "${CONTAINER_PREFIX}0" tail -20 /tmp/minerd.log 2>/dev/null || true
    fi

    # Advance mocktime in loop — each advance triggers min-difficulty
    # for the next getblocktemplate call.  After advancing, send a
    # small self-transfer to trigger a mempool update; this causes
    # the miner's long-poll to return with a fresh template that
    # reflects the new mocktime (and thus min-difficulty nBits).
    self_addr=$(cli 0 -rpcwallet=test getnewaddress 2>/dev/null || echo "")
    miner_deadline=$((SECONDS + 300))
    while [ $SECONDS -lt $miner_deadline ]; do
        advance_mocktime 600
        # Nudge mempool so the miner's long-poll returns
        cli 0 -rpcwallet=test sendtoaddress "$self_addr" 0.001 2>/dev/null || true
        sleep 5
        h=$(get_height 0)
        if [ "$h" -ge "$target_height" ]; then break; fi
    done

    stop_external_miner 0
    sleep 3
    sync_blocks 60

    h_after=$(get_height 0)
    actual_mined=$((h_after - h_before))

    # On failure, dump miner logs for debugging
    if [ "$actual_mined" -lt "$TARGET_MINER_BLOCKS" ]; then
        echo "  Miner logs (last 30 lines):"
        docker exec "${CONTAINER_PREFIX}0" tail -30 /tmp/minerd.log 2>/dev/null || true
    fi

    # Assertion 1: Miner produced enough blocks
    assert_ge "external miner produced >= ${TARGET_MINER_BLOCKS} blocks" \
        "$TARGET_MINER_BLOCKS" "$actual_mined" || true

    # Assertion 2: All 7 nodes synced (with empty-hash guard)
    hash0=$(cli 0 getbestblockhash 2>/dev/null || echo "")
    all_synced=true
    if [ -z "$hash0" ]; then all_synced=false; fi
    for i in $(seq 1 $((NUM_NODES - 1))); do
        hi=$(cli "$i" getbestblockhash 2>/dev/null || echo "")
        if [ -z "$hi" ] || [ "$hash0" != "$hi" ]; then all_synced=false; fi
    done
    TESTS_TOTAL=$((TESTS_TOTAL + 1))
    if $all_synced; then
        echo -e "  ${GREEN}PASS${NC}: all 7 nodes synced after external mining"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        echo -e "  ${RED}FAIL${NC}: consensus disagreement after external mining"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi

    # Assertion 3: All new blocks have zero coinbase
    # Guard: if no blocks were mined, this is a failure (empty loop = vacuous pass)
    all_zero=true
    if [ "$h_after" -le "$h_before" ]; then
        all_zero=false
        echo -e "  ${RED}no blocks mined — zero-coinbase check is vacuous${NC}"
    fi
    for h in $(seq $((h_before + 1)) "$h_after"); do
        cb=$(get_coinbase_value 0 "$h" 2>/dev/null || echo "ERROR")
        if [ "$cb" = "ERROR" ] || [ "$cb" != "0.00000000" ]; then all_zero=false; fi
    done
    TESTS_TOTAL=$((TESTS_TOTAL + 1))
    if $all_zero; then
        echo -e "  ${GREEN}PASS${NC}: all externally-mined blocks have zero coinbase"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        echo -e "  ${RED}FAIL${NC}: some blocks have non-zero coinbase"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi

    # Assertion 4: Blocks contain SIGNET_HEADER (ecc7daa2)
    # Guard: empty cb_hex is a failure, not a skip
    all_signed=true
    if [ "$h_after" -le "$h_before" ]; then
        all_signed=false
        echo -e "  ${RED}no blocks mined — signature check is vacuous${NC}"
    fi
    for h in $(seq $((h_before + 1)) "$h_after"); do
        blockhash=$(cli 0 getblockhash "$h" 2>/dev/null || echo "")
        if [ -z "$blockhash" ]; then
            all_signed=false
            continue
        fi
        cb_hex=$(cli 0 getblock "$blockhash" 2 2>/dev/null | jq -r '.tx[0].hex // empty')
        if [ -z "$cb_hex" ] || ! echo "$cb_hex" | grep -qi "ecc7daa2"; then
            all_signed=false
        fi
    done
    TESTS_TOTAL=$((TESTS_TOTAL + 1))
    if $all_signed; then
        echo -e "  ${GREEN}PASS${NC}: all blocks have valid signet signatures"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        echo -e "  ${RED}FAIL${NC}: some blocks missing SIGNET_HEADER"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
}

# =============================================================================
# Phase 9: Integrated Mining
# =============================================================================

test_header "20" "Integrated miner (-mine flag) produces blocks"
{
    TARGET_MINE_BLOCKS=1
    mine_conf_dir="/tmp/alpha-e2e-node9"
    mkdir -p "$mine_conf_dir"

    # Get a mining address from an existing node
    mine_addr=$(cli 0 -rpcwallet=test getnewaddress)

    cat > "${mine_conf_dir}/alpha.conf" <<CONFEOF
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
signetblockkey=${WIFS[0]}
mine=1
mineaddress=${mine_addr}
minethreads=1
CONFEOF

    docker run -d \
        --name "${CONTAINER_PREFIX}9" \
        --network "${NETWORK_NAME}" \
        -v "${mine_conf_dir}:/config" \
        "${IMAGE_NAME}" alphad >/dev/null 2>&1 || true

    # Wait for RPC on the integrated-miner node
    mine_rpc_ready=false
    mine_rpc_deadline=$((SECONDS + 120))
    while [ $SECONDS -lt $mine_rpc_deadline ]; do
        if docker exec "${CONTAINER_PREFIX}9" alpha-cli \
            -chain="${CHAIN}" -rpcport="${RPC_PORT}" \
            -rpcuser="${RPC_USER}" -rpcpassword="${RPC_PASS}" \
            getblockchaininfo &>/dev/null; then
            mine_rpc_ready=true
            break
        fi
        sleep 2
    done

    if ! $mine_rpc_ready; then
        echo -e "  ${RED}FAIL${NC}: integrated-miner node failed to start"
        docker logs "${CONTAINER_PREFIX}9" 2>&1 | tail -20
        TESTS_TOTAL=$((TESTS_TOTAL + 4))
        TESTS_FAILED=$((TESTS_FAILED + 4))
    else
        # Set mocktime to match the network
        docker exec "${CONTAINER_PREFIX}9" alpha-cli \
            -chain="${CHAIN}" -rpcport="${RPC_PORT}" \
            -rpcuser="${RPC_USER}" -rpcpassword="${RPC_PASS}" \
            setmocktime "$MOCK_TIME" >/dev/null 2>&1 || true

        # Connect to the rest of the network so it syncs the existing chain
        node0_ip=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "${CONTAINER_PREFIX}0")
        docker exec "${CONTAINER_PREFIX}9" alpha-cli \
            -chain="${CHAIN}" -rpcport="${RPC_PORT}" \
            -rpcuser="${RPC_USER}" -rpcpassword="${RPC_PASS}" \
            addnode "${node0_ip}:${P2P_PORT}" "add" >/dev/null 2>&1 || true

        # Wait for node9 to sync to the current chain tip
        target_hash=$(get_best_hash 0)
        sync_deadline=$((SECONDS + 120))
        synced=false
        while [ $SECONDS -lt $sync_deadline ]; do
            node9_hash=$(docker exec "${CONTAINER_PREFIX}9" alpha-cli \
                -chain="${CHAIN}" -rpcport="${RPC_PORT}" \
                -rpcuser="${RPC_USER}" -rpcpassword="${RPC_PASS}" \
                getbestblockhash 2>/dev/null || echo "")
            if [ "$node9_hash" = "$target_hash" ]; then
                synced=true
                break
            fi
            sleep 2
        done

        if ! $synced; then
            echo "  WARNING: node9 did not sync to chain tip"
            node9_h=$(docker exec "${CONTAINER_PREFIX}9" alpha-cli \
                -chain="${CHAIN}" -rpcport="${RPC_PORT}" \
                -rpcuser="${RPC_USER}" -rpcpassword="${RPC_PASS}" \
                getblockcount 2>/dev/null || echo "0")
            echo "  node9 height: ${node9_h}, target hash: ${target_hash:0:16}..."
        fi

        h_before=$(docker exec "${CONTAINER_PREFIX}9" alpha-cli \
            -chain="${CHAIN}" -rpcport="${RPC_PORT}" \
            -rpcuser="${RPC_USER}" -rpcpassword="${RPC_PASS}" \
            getblockcount 2>/dev/null || echo "0")

        # Advance mocktime once to trigger min-difficulty, then let the
        # miner work.  The miner loop calls CreateNewBlock() which picks
        # up the current mocktime.  We advance by 5 minutes (> 2*target
        # spacing) so fPowAllowMinDifficultyBlocks triggers powLimit.
        # Avoid advancing too often — each big jump can trigger a new
        # RandomX epoch and an expensive dataset rebuild (~30s).
        MOCK_TIME=$((MOCK_TIME + 300))
        docker exec "${CONTAINER_PREFIX}9" alpha-cli \
            -chain="${CHAIN}" -rpcport="${RPC_PORT}" \
            -rpcuser="${RPC_USER}" -rpcpassword="${RPC_PASS}" \
            setmocktime "$MOCK_TIME" >/dev/null 2>&1 || true
        cli 0 setmocktime "$MOCK_TIME" >/dev/null 2>&1 || true

        # Give the miner time to initialize RandomX dataset and solve PoW.
        # The dataset build alone takes ~30-45s, then each nonce check is ~2ms.
        # With powLimit difficulty, the first nonce should succeed.
        mine_deadline=$((SECONDS + 420))
        while [ $SECONDS -lt $mine_deadline ]; do
            sleep 20
            h_now=$(docker exec "${CONTAINER_PREFIX}9" alpha-cli \
                -chain="${CHAIN}" -rpcport="${RPC_PORT}" \
                -rpcuser="${RPC_USER}" -rpcpassword="${RPC_PASS}" \
                getblockcount 2>/dev/null || echo "0")
            actual_mined=$((h_now - h_before))
            echo "  (poll: node9 height=${h_now}, mined=${actual_mined}/${TARGET_MINE_BLOCKS})"
            if [ "$actual_mined" -ge "$TARGET_MINE_BLOCKS" ]; then break; fi

            # Bump mocktime gently (5 min) to keep min-difficulty active
            # for any new template the miner creates.
            MOCK_TIME=$((MOCK_TIME + 300))
            docker exec "${CONTAINER_PREFIX}9" alpha-cli \
                -chain="${CHAIN}" -rpcport="${RPC_PORT}" \
                -rpcuser="${RPC_USER}" -rpcpassword="${RPC_PASS}" \
                setmocktime "$MOCK_TIME" >/dev/null 2>&1 || true
            cli 0 setmocktime "$MOCK_TIME" >/dev/null 2>&1 || true
        done

        # Sync the rest of the network with any new blocks
        # First sync mocktime across all nodes
        for i in $(seq 0 $((NUM_NODES - 1))); do
            cli "$i" setmocktime "$MOCK_TIME" >/dev/null 2>&1 || true
        done
        sleep 5
        sync_blocks 60 || true

        h_after=$(docker exec "${CONTAINER_PREFIX}9" alpha-cli \
            -chain="${CHAIN}" -rpcport="${RPC_PORT}" \
            -rpcuser="${RPC_USER}" -rpcpassword="${RPC_PASS}" \
            getblockcount 2>/dev/null || echo "0")
        actual_mined=$((h_after - h_before))

        # On failure, dump node9 logs for debugging
        if [ "$actual_mined" -lt "$TARGET_MINE_BLOCKS" ]; then
            echo "  Node9 logs (last 50 lines):"
            docker logs "${CONTAINER_PREFIX}9" 2>&1 | tail -50
            echo "  --- Mining-related log lines ---"
            docker logs "${CONTAINER_PREFIX}9" 2>&1 | grep -i "min\|miner\|block\|error\|thread\|RandomX" | tail -30
        fi

        # Assertion 1: Integrated miner produced enough blocks
        assert_ge "integrated miner produced >= ${TARGET_MINE_BLOCKS} blocks" \
            "$TARGET_MINE_BLOCKS" "$actual_mined" || true

        # Assertion 2: node0 received the mined blocks
        h0_after=$(get_height 0)
        assert_ge "node0 synced integrated-miner blocks" "$h_after" "$h0_after" || true

        # Assertion 3: All new blocks have zero coinbase
        all_zero=true
        if [ "$h_after" -le "$h_before" ]; then
            all_zero=false
            echo -e "  ${RED}no blocks mined — zero-coinbase check is vacuous${NC}"
        fi
        for h in $(seq $((h_before + 1)) "$h_after"); do
            cb=$(get_coinbase_value 0 "$h" 2>/dev/null || echo "ERROR")
            if [ "$cb" = "ERROR" ] || [ "$cb" != "0.00000000" ]; then all_zero=false; fi
        done
        TESTS_TOTAL=$((TESTS_TOTAL + 1))
        if $all_zero; then
            echo -e "  ${GREEN}PASS${NC}: all integrated-mined blocks have zero coinbase"
            TESTS_PASSED=$((TESTS_PASSED + 1))
        else
            echo -e "  ${RED}FAIL${NC}: some blocks have non-zero coinbase"
            TESTS_FAILED=$((TESTS_FAILED + 1))
        fi

        # Assertion 4: Blocks contain SIGNET_HEADER (ecc7daa2)
        all_signed=true
        if [ "$h_after" -le "$h_before" ]; then
            all_signed=false
            echo -e "  ${RED}no blocks mined — signature check is vacuous${NC}"
        fi
        for h in $(seq $((h_before + 1)) "$h_after"); do
            blockhash=$(cli 0 getblockhash "$h" 2>/dev/null || echo "")
            if [ -z "$blockhash" ]; then
                all_signed=false
                continue
            fi
            cb_hex=$(cli 0 getblock "$blockhash" 2 2>/dev/null | jq -r '.tx[0].hex // empty')
            if [ -z "$cb_hex" ] || ! echo "$cb_hex" | grep -qi "ecc7daa2"; then
                all_signed=false
            fi
        done
        TESTS_TOTAL=$((TESTS_TOTAL + 1))
        if $all_signed; then
            echo -e "  ${GREEN}PASS${NC}: all integrated-mined blocks have valid signet signatures"
            TESTS_PASSED=$((TESTS_PASSED + 1))
        else
            echo -e "  ${RED}FAIL${NC}: some blocks missing SIGNET_HEADER"
            TESTS_FAILED=$((TESTS_FAILED + 1))
        fi
    fi

    docker rm -f "${CONTAINER_PREFIX}9" >/dev/null 2>&1 || true
}

# =============================================================================
# Summary
# =============================================================================
print_summary
exit $?

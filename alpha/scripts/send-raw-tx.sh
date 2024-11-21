#!/bin/bash

# Check arguments
if [ $# -lt 2 ] || [ $# -gt 3 ]; then
    echo "Usage: $0 <raw_tx_file> <wallet_name> [--dry-run]"
    echo "Example: $0 raw_transactions.txt mywallet"
    echo "Add --dry-run to simulate sending without actually sending transactions"
    exit 1
fi

TX_FILE="$1"
WALLET="$2"
DRY_RUN=0

if [ "$3" = "--dry-run" ]; then
    DRY_RUN=1
    echo "DRY RUN MODE - No transactions will be sent"
    echo
fi

BATCH_SIZE=50
SENT_FILE="sent_transactions.txt"
SKIPPED_FILE="skipped_transactions.txt"
TEMP_FILE=".tx_processing.tmp"

# Function to get block height
get_block_height() {
    alpha-cli -rpcwallet="$WALLET" getblockcount
}

# Function to get all unspent vouts for a txid
get_unspent_vouts() {
    local txid=$1
    alpha-cli -rpcwallet="$WALLET" listunspent | jq -r ".[] | select(.txid==\"$txid\") | .vout"
}

# Function to check if specific UTXO is spent
check_utxo_spent() {
    local txid=$1
    local vout=$2
    local result=$(alpha-cli -rpcwallet="$WALLET" gettxout "$txid" "$vout" 2>/dev/null)
    if [ -z "$result" ] || [ "$result" = "null" ]; then
        return 0  # UTXO is spent
    else
        return 1  # UTXO is unspent
    fi
}

# Initialize counters
tx_count=0
processed_count=0
skipped_count=0
current_block=$(get_block_height)
last_processed_block=$current_block

echo "Starting from block height: $current_block"
echo "Will process $BATCH_SIZE transactions per block"
echo

# Calculate total transactions
total_tx=$(wc -l < "$TX_FILE")
echo "Total transactions to process: $total_tx"
echo "Total batches needed: $(( (total_tx + BATCH_SIZE - 1) / BATCH_SIZE ))"
echo

# Create or clear output files (only in real mode)
if [ $DRY_RUN -eq 0 ]; then
    > "$SENT_FILE"
    > "$SKIPPED_FILE"
fi

# Process transactions
while IFS=$'\t' read -r txid raw_tx; do
    tx_count=$((tx_count + 1))
    
    echo "Processing transaction $tx_count of $total_tx"
    echo "TXID: $txid"
    
    # Debug output for UTXO info
    echo "Available UTXOs for this txid:"
    alpha-cli -rpcwallet="$WALLET" listunspent | jq -r ".[] | select(.txid==\"$txid\")" | jq '.'
    
    # Get all unspent vouts for this txid
    vouts=$(get_unspent_vouts "$txid")
    
    if [ -z "$vouts" ]; then
        echo "No unspent vouts found - skipping"
        echo -e "$txid\tno_unspent_vouts" >> "$SKIPPED_FILE"
        skipped_count=$((skipped_count + 1))
        echo "----------------------------------------"
        continue
    fi
    
    # Process each vout
    echo "$vouts" | while read -r vout; do
        echo "Checking vout: $vout"
        
        # Check if this specific vout is spent
        if check_utxo_spent "$txid" "$vout"; then
            echo "UTXO vout $vout already spent - skipping"
            echo -e "$txid\t$vout\tspent" >> "$SKIPPED_FILE"
            skipped_count=$((skipped_count + 1))
            continue
        fi
        
        # Wait for new block if we've hit batch size
        if [ $((processed_count % BATCH_SIZE)) -eq 0 ] && [ $processed_count -ne 0 ]; then
            echo "Waiting for next block..."
            while true; do
                current_block=$(get_block_height)
                if [ "$current_block" -gt "$last_processed_block" ]; then
                    break
                fi
                sleep 10
            done
            last_processed_block=$current_block
            echo "New block height: $current_block. Continuing with next batch..."
        fi
        
        # Try to send the transaction
        if [ $DRY_RUN -eq 1 ]; then
            echo "DRY RUN: Would send transaction for vout $vout"
        else
            result=$(alpha-cli -rpcwallet="$WALLET" sendrawtransaction "$raw_tx" 2>&1)
            if [ $? -ne 0 ]; then
                echo "Error sending transaction for vout $vout: $result"
                echo -e "$txid\t$vout\terror\t$result" >> "$SKIPPED_FILE"
                continue
            fi
            echo "Success - Transaction sent with hash: $result"
            echo -e "$txid\t$vout\t$result" >> "$SENT_FILE"
            processed_count=$((processed_count + 1))
        fi
    done
    
    echo "----------------------------------------"
    sleep 1
    
done < "$TX_FILE"

echo "Finished processing transactions"
echo "Total transactions checked: $tx_count"
if [ $DRY_RUN -eq 0 ]; then
    echo "Successfully sent: $processed_count"
    echo "Skipped (already spent): $skipped_count"
    echo "Results saved to:"
    echo "- Sent transactions: $SENT_FILE"
    echo "- Skipped transactions: $SKIPPED_FILE"
else
    echo "DRY RUN COMPLETE - No transactions were actually sent"
fi

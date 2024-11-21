#!/bin/bash

# Check arguments
if [ $# -lt 2 ]; then
    echo "Usage: $0 <wallet_name> <min_amount>"
    echo "Example: $0 mywallet 0.1"
    echo "This will only list UTXOs with amount >= 0.1"
    exit 1
fi

WALLET="$1"
MIN_AMOUNT="$2"

# Store unspent list once to avoid multiple RPC calls
UNSPENT_LIST=$(alpha-cli -rpcwallet="$WALLET" listunspent)
if [ $? -ne 0 ]; then
    echo "Error: Failed to get unspent outputs"
    exit 1
fi

# Print header
echo "TXID                                                             Vout    Amount              Address"
echo "------------------------------------------------------------------------------------------------"

# List all unspent outputs and filter by minimum amount
echo "$UNSPENT_LIST" | \
jq -r --arg min "$MIN_AMOUNT" \
'[.[] | select(.amount >= ($min|tonumber))] | sort_by(.txid, .vout) | .[] | 
"\(.txid) \(.vout) \(.amount) \(.address)"' | \
while read -r txid vout amount address; do
    printf "%-64s %-7d %-18.8f %s\n" "$txid" "$vout" "$amount" "$address"
done

# Print footer with summary
echo "------------------------------------------------------------------------------------------------"

# Calculate totals
total_unique_txids=$(echo "$UNSPENT_LIST" | \
jq --arg min "$MIN_AMOUNT" '[.[] | select(.amount >= ($min|tonumber)) | .txid] | unique | length')

total_vouts=$(echo "$UNSPENT_LIST" | \
jq --arg min "$MIN_AMOUNT" '[.[] | select(.amount >= ($min|tonumber))] | length')

total_amount=$(echo "$UNSPENT_LIST" | \
jq --arg min "$MIN_AMOUNT" '[.[] | select(.amount >= ($min|tonumber)) | .amount] | add')

echo "Total Unique TXIDs: $total_unique_txids"
echo "Total Vouts: $total_vouts"
printf "Total Amount: %.8f\n" "$total_amount"
echo "------------------------------------------------------------------------------------------------"

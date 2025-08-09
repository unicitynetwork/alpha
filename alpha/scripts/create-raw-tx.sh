#!/bin/bash

# Check arguments
if [ $# -ne 4 ]; then
    echo "Usage: $0 <utxo_file> <destination_address> <wallet_name> <output_file>"
    echo "Example: $0 utxos.txt alpha23... mywallet signed_tx.txt"
    exit 1
fi

UTXO_FILE="$1"
DEST_ADDRESS="$2"
WALLET="$3"
OUTPUT_FILE="$4"

# Set a reasonable fee rate (in BTC/kB)
FEERATE=0.00001  # Adjust this value as needed

# Check if input file exists
if [ ! -f "$UTXO_FILE" ]; then
    echo "Error: Transaction file not found: $UTXO_FILE"
    exit 1
fi

# Check if output file already exists
if [ -f "$OUTPUT_FILE" ]; then
    echo "Warning: Output file $OUTPUT_FILE already exists. Do you want to overwrite it? (y/n)"
    read -r response
    if [[ ! "$response" =~ ^[Yy]$ ]]; then
        echo "Enter a new output file name:"
        read -r OUTPUT_FILE
    fi
    : > "$OUTPUT_FILE"
fi

# Process each UTXO
echo "Creating and signing transactions..."
echo "Using fee rate: $FEERATE BTC/kB"
echo

# Use a temporary file to store the count
temp_count="/tmp/tx_count.$$"
echo 0 > "$temp_count"

# Skip first two lines (header)
tail -n +3 "$UTXO_FILE" | while read -r line; do
    # Skip if line is empty, starts with "Total", or contains only dashes
    if [[ -z "$line" ]] || [[ "$line" =~ ^Total ]] || [[ "$line" =~ ^-+$ ]]; then
        continue
    fi

    read -r txid vout amount address <<< "$line"
    
    # Validate TXID and amount
    if [[ ${#txid} -eq 64 ]] && [[ "$amount" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
        count=$(cat "$temp_count")
        count=$((count + 1))
        echo $count > "$temp_count"
        
        # Use fixed fee rate instead of estimating
        FEE=$FEERATE

        # Calculate amount minus fee
	SEND_AMOUNT=$(printf "%.8f" $(echo "$amount - $FEE" | bc))
        if (( $(echo "$SEND_AMOUNT <= 0" | bc -l) )); then
            echo "Error: Output amount for TXID $txid vout $vout is less than or equal to zero after fees."
            continue
        fi
        
        # Create single input JSON with specific vout
        INPUTS="[{\"txid\":\"$txid\",\"vout\":$vout}]"
        
        # Create the outputs JSON
        OUTPUTS="{\"$DEST_ADDRESS\":$SEND_AMOUNT}"
        
        echo "Creating transaction #$count"
        echo "TXID: $txid"
        echo "Vout: $vout"
        echo "Input amount: $amount"
        echo "Output amount: $SEND_AMOUNT"
        echo "Fee: $FEE"
        
        # Create raw transaction with explicit fee rate
        raw_tx=$(alpha-cli -rpcwallet="$WALLET" createrawtransaction "$INPUTS" "$OUTPUTS" 2>&1)
        if [ $? -ne 0 ]; then
            echo "Error creating raw transaction: $raw_tx"
            continue
        fi

        # Sign the transaction
        echo "Signing transaction..."
        signed_result=$(alpha-cli -rpcwallet="$WALLET" signrawtransactionwithwallet "$raw_tx" 2>&1)
        if [ $? -ne 0 ]; then
            echo "Error signing transaction: $signed_result"
            continue
        fi

        # Extract the hex from the json result
        signed_hex=$(echo "$signed_result" | jq -r '.hex')
        complete=$(echo "$signed_result" | jq -r '.complete')

        # Check if signing was complete
        if [ "$complete" != "true" ]; then
            echo "Transaction signing was not complete for TXID: $txid vout: $vout"
            echo "$signed_result"
            continue
        fi

        # Save signed transaction in format expected by send-raw-tx.sh
        printf "%s\t%s\n" "$txid" "$signed_hex" >> "$OUTPUT_FILE"
        echo "Saved signed transaction for TXID: $txid vout: $vout"
        echo "----------------------------------------"
    else
        echo "Skipping invalid line: $line"
    fi
done

# Get final count and clean up
FINAL_COUNT=$(cat "$temp_count")
rm "$temp_count"

echo "Created and signed $FINAL_COUNT transactions"
echo "Saved to $OUTPUT_FILE"
echo "Format: TXID<tab>SIGNED_TRANSACTION_HEX"

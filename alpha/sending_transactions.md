# UTXO Processing Guide

## Prerequisites
- Access to Alpha node
- `alpha-cli` is on the path
- Wallet with UTXOs
- Destination address for transactions
- Three scripts:
  1. `list-utxos.sh`
  2. `create-raw-tx.sh`
  3. `send-raw-tx.sh`

## Step-by-Step Process

### 1. List UTXOs
```bash
./list-utxos.sh <wallet_name> <min_amount>
```
- Lists UTXOs for `wallet_name` and amount >= `min_amount`
- Outputs to utxos.txt
- Review output to verify UTXOs listed correctly

```bash
# Example: ./list-utxos.sh MY_WALLET 0.01 > utxos.txt
```
Lists UTXOs greater than 0.01 for wallet named `MY_WALLET` and outputs to utxos.txt

### 2. Create and Sign Transactions
```bash
./create-raw-tx.sh <utxo_file> <destination_address> <wallet_name> <output_file>
```
- Creates raw transaction for each UTXO
- Outputs results to file named output_file
- Signs each transaction


```bash
# Example: ./create-raw-tx.sh utxos.txt alpha139.. MY_WALLET signed_txs.txt 
```

- Review output file to ensure transactions are created correctly


### 3. Send Transactions

```
./send-raw-tx.sh <raw_tx_file> <wallet_name> [--dry-run]
```

broadcasts raw transactions to the network for processsing

```bash
# Example: ./send-raw-tx.sh signed_txs.txt MY_WALLET --dry-run
```
- Simulates sending without actual transactions
- Verify script behavior

```
# Example: ./send-raw-tx.sh signed_txs.txt MY_WALLET
```
- Sends transactions in batches of 50 per block
- Creates two output files:

  - sent_transactions.txt: Successfully sent
  - skipped_transactions.txt: Already spent UTXOs

## Important Notes
- Backup wallet before starting
- Keep all output files for reference
- Can stop/restart send script safely
- Monitor progress in terminal output
- Check output files after completion

## Troubleshooting
- If send script stops, check error message
- Can restart send script - will skip already processed transactions
- Review skipped_transactions.txt for already spent UTXOs
- Verify destination address is correct before creating transactions

# Wallet Migration Guide 

## Prerequisites
- Access to Alpha node
- Access to AlphacashD
- `alpha-cli` is on the path
- [Bitcoin Explorer (bx)](https://github.com/libbitcoin/libbitcoin-explorer) is on the path
- Two scripts:
  1. `convkeys.sh`
  2. `import.sh`


## Step-by-Step Process

### 1. Legacy wallet support

To allow your Alpha node to create a legacy wallet add the following to your alpha.conf file

```deprecatedrpc=create_bdb```


### 2. Export private keys

Run the Alphacash gui with the wallet you want to migrate in the data dir. Check the balance

Run the Alpahcash command line ```alphacash printkeys```

This will export all the private keys in the wallet one per line into a file called keys.dat in your data dir


### 4. Create a new Alpha "legacy wallet 

```alpha-cli createwallet "YOUR_WALLET_NAME" false false "" false false```

This creates a legacy (non-descriptor) wallet that we can import the keys to

### 3. Import Keys 

Run ```importkeys.sh``` This will import the WIF keys into the wallet.


## Important Notes
- Backup wallet before starting
- Check the two balances match in the old and new wallets
- Make sure to erase properly the intermediate files
- Monitor progress in terminal output


## Support Unicity Development
- Consider transferring a percentage of your coins to the project community address to support development. Your contributions are appreciated.

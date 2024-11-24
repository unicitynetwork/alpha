#!/bin/bash

# Define the path to the alpha-cli command
ALPHA_CLI=alpha-cli

# Check if the wif.dat file exists
if [ ! -f "wif.dat" ]; then
    echo "Error: wif.dat file not found!"
    exit 1
fi

# Read the wif.dat file line by line
while IFS= read -r wif_key; do
    # Check if the line is not empty
    if [ -n "$wif_key" ]; then
        # Call alpha-cli to import the WIF private key
        $ALPHA_CLI importprivkey "$wif_key"

        # Check if the import was successful
        if [ $? -eq 0 ]; then
            echo "Successfully imported WIF key: $wif_key"
        else
            echo "Failed to import WIF key: $wif_key"
        fi
    fi
done < "wif.dat"

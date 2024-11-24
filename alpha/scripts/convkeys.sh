#!/bin/bash

# Check if the input file is provided as an argument
if [ "$#" -ne 1 ]; then
    echo "Usage: $0 <input_file>"
    exit 1
fi

input_file=$1

# Check if the input file exists
if [ ! -f "$input_file" ]; then
    echo "Error: File '$input_file' not found!"
    exit 1
fi

# Read the file line by line
while IFS= read -r private_key; do
    # Check if the line is not empty
    if [ -n "$private_key" ]; then
        # Use bx to convert to uncompressed WIF format
        wif_key=$(bx ec-to-wif --uncompressed "$private_key")

        # Output only the WIF key
        echo "$wif_key"
    fi
done < "$input_file"

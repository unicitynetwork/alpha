#!/usr/bin/env python3
"""
Convert a WIF private key between network version bytes.

The raw 32-byte private key is chain-agnostic; only the WIF encoding
(version byte + optional compression flag + checksum) differs.

Version bytes:
  0x80 (128) = mainnet  (WIF starts with K/L for compressed, 5 for uncompressed)
  0xef (239) = testnet/regtest (WIF starts with c for compressed, 9 for uncompressed)

Usage:
  python3 wif_convert.py <WIF_key> <target_version_hex>

Examples:
  python3 wif_convert.py KwDi... ef       # mainnet -> regtest
  python3 wif_convert.py cNkG... 80       # regtest -> mainnet
"""
import sys
import hashlib


def sha256(data: bytes) -> bytes:
    return hashlib.sha256(data).digest()


def double_sha256(data: bytes) -> bytes:
    return sha256(sha256(data))


# Base58 alphabet (Bitcoin standard)
B58_ALPHABET = b"123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz"


def b58encode(data: bytes) -> str:
    """Encode bytes to Base58."""
    n = int.from_bytes(data, "big")
    result = []
    while n > 0:
        n, r = divmod(n, 58)
        result.append(B58_ALPHABET[r:r + 1])
    # Preserve leading zero bytes
    for byte in data:
        if byte == 0:
            result.append(B58_ALPHABET[0:1])
        else:
            break
    return b"".join(reversed(result)).decode("ascii")


def b58decode(s: str) -> bytes:
    """Decode a Base58 string to bytes."""
    n = 0
    for ch in s:
        idx = B58_ALPHABET.index(ch.encode("ascii"))
        n = n * 58 + idx
    # Determine output length: version(1) + payload + checksum(4)
    # For compressed WIF: 1 + 32 + 1 + 4 = 38 bytes
    # For uncompressed WIF: 1 + 32 + 4 = 37 bytes
    length = (n.bit_length() + 7) // 8
    result = n.to_bytes(length, "big")
    # Restore leading zero bytes
    pad = 0
    for ch in s:
        if ch == "1":
            pad += 1
        else:
            break
    return b"\x00" * pad + result


def wif_decode(wif: str) -> tuple:
    """Decode WIF -> (version_byte, privkey_32bytes, compressed_flag)."""
    raw = b58decode(wif)
    checksum = raw[-4:]
    payload = raw[:-4]
    if double_sha256(payload)[:4] != checksum:
        raise ValueError("Invalid WIF checksum")
    version = payload[0]
    if len(payload) == 34 and payload[-1] == 0x01:
        # Compressed
        return version, payload[1:33], True
    elif len(payload) == 33:
        # Uncompressed
        return version, payload[1:33], False
    else:
        raise ValueError(f"Unexpected WIF payload length: {len(payload)}")


def wif_encode(version: int, privkey: bytes, compressed: bool) -> str:
    """Encode (version, privkey, compressed) -> WIF string."""
    payload = bytes([version]) + privkey
    if compressed:
        payload += b"\x01"
    checksum = double_sha256(payload)[:4]
    return b58encode(payload + checksum)


def main():
    if len(sys.argv) != 3:
        print(f"Usage: {sys.argv[0]} <WIF_key> <target_version_hex>")
        print(f"Example: {sys.argv[0]} KwDi...  ef")
        sys.exit(1)

    wif_in = sys.argv[1]
    target_version = int(sys.argv[2], 16)

    _version, privkey, compressed = wif_decode(wif_in)
    wif_out = wif_encode(target_version, privkey, compressed)
    print(wif_out)


if __name__ == "__main__":
    main()

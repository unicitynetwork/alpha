# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview
Alpha is a fork of Bitcoin Core v27.0 that serves as the trust anchor layer for the Unicity platform. It uses RandomX (ASIC-resistant) mining with 2-minute block times and implements single-input transactions for local verifiability.

Key differences from Bitcoin:
- **Single input transactions only** - Enables coin extraction for off-chain agent layer
- **RandomX mining** (switched from SHA256 at block 70228) 
- **2-minute blocks** with 10 ALPHA subsidy
- **ASERT difficulty adjustment** (activated block 70232)
- **Programmatic hard forks** every 50,000 blocks

## Build Commands
- Basic build: `./autogen.sh && ./configure && make`
- With GUI: `./autogen.sh && make -C depends && ./configure --prefix=$PWD/depends/x86_64-pc-linux-gnu --program-transform-name='s/bitcoin/alpha/g' && make && make install`
- Without GUI: `./autogen.sh && make -C depends NO_QT=1 && ./configure --without-gui --prefix=$PWD/depends/x86_64-pc-linux-gnu --program-transform-name='s/bitcoin/alpha/g' && make && make install`
- Debug build: `./configure --enable-debug && make`
- Windows cross-compile: `make HOST=x86_64-w64-mingw32 -C depends && ./configure --prefix=$PWD/depends/x86_64-w64-mingw32 --program-transform-name='s/bitcoin/alpha/g' && make`
- MacOS: Check `depends/` for platform-specific directory (e.g., `aarch64-apple-darwin*` or `x86_64-apple-darwin*`)

Executables will be in `depends/<platform>/bin/` with names transformed from `bitcoin*` to `alpha*`.

## Test Commands
- All unit tests: `make check`
- Single unit test: `src/test/test_bitcoin --run_test=getarg_tests/doubledash`
- All functional tests: `test/functional/test_runner.py`
- Single functional test: `test/functional/feature_rbf.py`
- Test coverage: `./configure --enable-lcov && make && make cov`

## Lint Commands
- Run all lint checks: `ci/lint_run_all.sh`
- Run clang-tidy: `bear --config src/.bear-tidy-config -- make -j $(nproc) && cd ./src/ && run-clang-tidy -j $(nproc)`

## Code Architecture
The codebase is a fork of Bitcoin Core with the following key components:

### Core Directories
- `src/consensus/` - Consensus rules including single-input transaction validation
- `src/crypto/randomx/` - RandomX mining algorithm implementation
- `src/wallet/` - Wallet functionality (mostly inherited from Bitcoin)
- `src/qt/` - GUI implementation
- `src/policy/` - Transaction relay policies
- `src/test/` - Unit tests
- `test/functional/` - Python-based functional tests

### Key Configuration
- Default data directory: `$HOME/.alpha/`
- Configuration file: `alpha.conf` (same format as bitcoin.conf)
- Chain parameters: See `src/chainparams.cpp` for Alpha-specific parameters
- Default chain: `alpha` (use `-chain=` for alphatestnet, alpharegtest, main, test, signet, regtest)

### Validation Changes
The main consensus change is in transaction validation requiring exactly one input per transaction. This is enforced in the validation logic to ensure coin sub-ledgers can be extracted for off-chain use.

## Code Style
- C++: 4-space indentation, braces on new lines for functions/classes
- Variables: `snake_case`, class members with `m_` prefix, constants in `ALL_CAPS`, globals with `g_` prefix
- Class/methods: `UpperCamelCase` for classes, no `C` prefix
- Commit messages: 50 chars title + blank line + description
- PR titles: Prefix with component (consensus, doc, qt, wallet, etc.)
- Python: Follow PEP-8, use f-strings, include docstrings
- Include guards: `BITCOIN_FOO_BAR_H` format
- Imports: No `using namespace` in global scope
- Error handling: Use `assert`/`Assert` for assumptions, `CHECK_NONFATAL` for recoverable errors
- Use init lists for member initialization: `int x{0};` instead of `int x = 0;`
- Always use full namespace specifiers for function calls
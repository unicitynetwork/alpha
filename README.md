
Alphacash
=====================================

Build instructions here [doc/build-alpha.md](doc/build-alpha.md).
Alphacash is released under the terms of the MIT license.



**Abstract**: Alphacash is a censorship resistant peer-to-peer electronic cash system. Similar to Bitcoin, it uses a fixed emission schedule and longest chain Proof of Work consensus protocol. Unlike Bitcoin it supports unlimited blocksize  without sacrificing security or censorship resistance. The Alphacash coins replicate the self-verifiability property of physical cash, i.e. the coins are compact, authenticated data structures which can be passed through any medium peer-to-peer, chain-to-chain and verified without bridges or trusted third parties. Alphacash completes the Bitcoin vision, functioning as an Internet currency, a medium of exchange and a genuine alternative to physical cash.

Alphacash is designed to the native currency of Unicity, a new blockchain architecture that supports parallel execution of smart contracts. However as a standalone digital currency it has some useful properties:

1. genuine decentralization: zero-premine with ASIC resistant hash function
2. massively parallel client side execution of smart contracts
3. perfect privacy 
4. unlimited throughput



The design is a layered architecture 
			
						Proof of Work Trust Anchor
						Unicity and ZK Aggregation
						Smart Contracts


The top layer provides a Proof of Work trust anchor i.e. it mints new coins which can then be extracted and used "off-chain" in the Smart Contract layer.

This codebase implements the top layer and uses a fork of Bitcoin (Scash). It is not designed to be a transaction system and 99% of the codebase is redundant - transactions are executed at the smart contract layer not in the Proof of Work layer. Transactions are still needed (coinbase, mining pool shares) but discouraged. 

The major changes from the Bitcoin codebase

**Single input transactions only**

    if (tx.vin.size() != 1)
            return state.Invalid(TxValidationResult::TX_CONSENSUS, "bad-txns-too-many-inputs", "Alpha Transactions must have exactly one input");

This ensures local verifability i.e. each coin sub-ledger can be extracted from the ledger and used off-chain in the smart contract layer.

**RandomX Hash Function**

To democratize mining we use the RandomX ASIC resistance hash function as used in Monero https://github.com/tevador/RandomX 

The hashing algorithm switched from SHA25D to RandomX on block 70228
Difficulty was reduced by a factor of 100,000


**10 ALPHA subsidy and 2 minute block time**

The subsidy is 10 ALPHA with a target block time of 2 minutes. Halving period measured in time is the same as Bitcoin or 210000*5 blocks

**ASERT**

The Bitcoin Cash implementation of an exponential moving average approach to difficulty adjustments is implemented to theoretically always target a correction toward a 2 minute block time. 

ASERT was initiated on block 70232
half-life 30 minutes


**GENESIS BLOCK**

Script: "Financial Times 25/May/2024 What went wrong with capitalism"
Time Sun Jun 16 07:54:52 UTC 2024
nBits: 0x1d0fffff








Bitcoin Core integration/staging tree
=====================================

https://bitcoincore.org

For an immediately usable, binary version of the Bitcoin Core software, see
https://bitcoincore.org/en/download/.

What is Bitcoin Core?
---------------------

Bitcoin Core connects to the Bitcoin peer-to-peer network to download and fully
validate blocks and transactions. It also includes a wallet and graphical user
interface, which can be optionally built.

Further information about Bitcoin Core is available in the [doc folder](/doc).

License
-------

Bitcoin Core is released under the terms of the MIT license. See [COPYING](COPYING) for more
information or see https://opensource.org/licenses/MIT.

Development Process
-------------------

The `master` branch is regularly built (see `doc/build-*.md` for instructions) and tested, but it is not guaranteed to be
completely stable. [Tags](https://github.com/bitcoin/bitcoin/tags) are created
regularly from release branches to indicate new official, stable release versions of Bitcoin Core.

The https://github.com/bitcoin-core/gui repository is used exclusively for the
development of the GUI. Its master branch is identical in all monotree
repositories. Release branches and tags do not exist, so please do not fork
that repository unless it is for development reasons.

The contribution workflow is described in [CONTRIBUTING.md](CONTRIBUTING.md)
and useful hints for developers can be found in [doc/developer-notes.md](doc/developer-notes.md).

Testing
-------

Testing and code review is the bottleneck for development; we get more pull
requests than we can review and test on short notice. Please be patient and help out by testing
other people's pull requests, and remember this is a security-critical project where any mistake might cost people
lots of money.

### Automated Testing

Developers are strongly encouraged to write [unit tests](src/test/README.md) for new code, and to
submit new unit tests for old code. Unit tests can be compiled and run
(assuming they weren't disabled in configure) with: `make check`. Further details on running
and extending unit tests can be found in [/src/test/README.md](/src/test/README.md).

There are also [regression and integration tests](/test), written
in Python.
These tests can be run (if the [test dependencies](/test) are installed) with: `test/functional/test_runner.py`

The CI (Continuous Integration) systems make sure that every pull request is built for Windows, Linux, and macOS,
and that unit/sanity tests are run automatically.

### Manual Quality Assurance (QA) Testing

Changes should be tested by somebody other than the developer who wrote the
code. This is especially important for large or high-risk changes. It is useful
to add a test plan to the pull request description if testing the changes is
not straightforward.

Translations
------------

Changes to translations as well as new translations can be submitted to
[Bitcoin Core's Transifex page](https://www.transifex.com/bitcoin/bitcoin/).

Translations are periodically pulled from Transifex and merged into the git repository. See the
[translation process](doc/translation_process.md) for details on how this works.

**Important**: We do not accept translation changes as GitHub pull requests because the next
pull from Transifex would automatically overwrite them again.

# ALPHA BUILD NOTES

Building Alpha follows the same instructions as building Bitcoin. The Alpha network shares the same features and rules as Bitcoin mainnet, as specified in Bitcoin Core v27.0.

The Linux version of the node `alphad` and GUI app `alpha-qt` are both supported, with Windows binaries also  available (cross-compiled on Linux). Note that Windows users can build from source by following the Linux instructions when building in Ubuntu on [Windows Subsystem for Linux (WSL)](https://learn.microsoft.com/en-us/windows/wsl/about).

For more specific instructions on building, see [`build-unix.md`](build-unix.md) in this directory.

Also see the latest [Alpha release notes](release-notes/alpha/).

## Getting started 

Update your system and install the following tools required to build software.

```bash
sudo apt update
sudo apt upgrade
sudo apt install build-essential libtool autotools-dev automake pkg-config bsdmainutils curl git cmake bison
```

## WSL for Windows

Ignore this step if building on native Linux. The following only applies when building in WSL for Windows.

Open the WSL configuration file:
```bash
sudo nano /etc/wsl.conf
```
Add the following lines to the file:
```
[interop]
appendWindowsPath=false
```
Exit WSL and then restart WSL.

## Downloading the code

Download the latest version of Alpha and checkout the version you intend to build. If you want to build a specific version, you can replace `alpha_master` with the version tag.

```bash
git clone https://github.com/sakuyama2024/alpha.git
cd alpha
git checkout alpha_master
```

## Building for Linux

Alpha requires building with the depends system.

When calling `make` use `-j N` for N parallel jobs.

### Node software without the GUI

To build just the node software `alphad` and not the QT GUI app:

```bash
./autogen.sh
make -C depends NO_QT=1
./configure --without-gui --prefix=$PWD/depends/x86_64-pc-linux-gnu --program-transform-name='s/bitcoin/alpha/g'
make
make install
```

### Node software with the GUI

To build both the node software `alphad` and the QT GUI app `alphad-qt`

```bash
./autogen.sh
make -C depends
./configure --prefix=$PWD/depends/x86_64-pc-linux-gnu --program-transform-name='s/bitcoin/alpha/g'
make
make install
```

### Executables
The compiled executables will be found in `depends/x86_64-pc-linux-gnu/bin/` and can be copied to a folder on your path, typically `/usr/local/bin/` or `$HOME/.local/bin/`.


## Building for Windows (by cross-compiling on Linux)

Build on Linux and generate executables which run on Windows.

```
sudo apt install g++-mingw-w64-x86-64-posix 
cd depends/
make HOST=x86_64-w64-mingw32
cd ..
./autogen.sh
./configure --prefix=$PWD/depends/x86_64-w64-mingw32 --program-transform-name='s/bitcoin/alpha/g'
make
make install
```

The windows executables will be found in `depends/x86_64-w64-mingw32/bin/`.

To generate a Windows installer:

```
sudo apt install nsis
make deploy
```

## Config file

The alpha configuration file is the same as bitcoin.conf.

By default, alpha looks for a configuration file here:
`$HOME/.alpha/alpha.conf`

The following is a sample `alpha.conf`.
```
rpcuser=user
rpcpassword=password
chain=alpha
daemon=1
debug=1
txindex=1

[alpha]
adddnsseed=

[alphatestnet]
adddnsseed=
```

### Connecting to the network

To help find other nodes on the network, a [DNS seed](https://bitcoin.stackexchange.com/questions/14371/what-is-a-dns-seed-node-vs-a-seed-node) has been specified. The DNS seed shown above is for testing purposes and may not always be online. Users are advised to ask the community for a list of [reliable DNS seeds](https://github.com/bitcoin/bitcoin/blob/master/doc/dnsseed-policy.md) to use, as well as the IP addresses of stable nodes on the network which can be used with the `-addnode` and `-seednode` RPC calls.

If you intend to use the same configuration file with multiple networks, the config sections are named as follows:
```
[btc]
[btctestnet3]
[btcsignet]
[btcregtest]
[alpha]
[alpharegtest]
[alphatestnet]
```

## Running a node

To run the alpha node:
```bash
alphad
```

To send commands to the Alpha node:
```
alpha-cli [COMMAND] [PARAMETERS]
```

To run the desktop GUI app:
```bash
alpha-qt
```

On WSL for Windows, launching `alpha-qt` may require installing the following dependencies. Also see [WSL gui apps](https://learn.microsoft.com/en-us/windows/wsl/tutorials/gui-apps).
```bash
sudo apt install libxcb-* libxkbcommon-x11-0
```

Also note that in WSL for Windows, by default only half of the memory is available to WSL. You can [configure the memory limit](https://learn.microsoft.com/en-us/windows/wsl/wsl-config#main-wsl-settings) by creating `.wslconfig` file in your user folder.
```
[wsl2]
memory=16GB
```

## Connecting to different chains

When running executables with the name `bitcoin...` if no chain is configured, the default chain will be Bitcoin mainnet.

When running executables with the name `alpha...` if no chain is configured, the default chain will be alpha mainnet.

Option `-chain=` accepts the following values: `alpha` `alphatestnet` `alpharegtest` and for Bitcoin networks: `main` `test` `signet` `regtest`

## Mining Alpha

There are a few ways to mine Alpha.

### Testnet and Regtest chain

Mining takes place inside the alpha node, using the RPC `generatetoaddress` which is single-threaded. For example:
```bash
alpha-cli createwallet myfirstwallet
alpha-cli getnewaddress
alpha-cli generatetoaddress 1 newminingaddress 10000
```

To speed up mining in the alpha node, at the expense of using more memory (at least 2GB more), enable the option `randomxfastmode` by adding to the `alpha.conf` configuration file:

```
randomxfastmode=1
```

### Main network and Testnet chain

Mining takes place inside [cpuminer-alpha](https://github.com/sakuyama2024/cpuminer-alpha) which is dedicated mining software that connects to the alpha node and retrieves mining jobs via RPC `getblocktemplate`. The 'randomxfastmode' configuration option is not required for the Alpha node, since mining occurs inside `cpuminer-alpha` which always runs in fast mode.

### Mining Pools

Third-party software exists for mining at pools.


Getting Help
---------------------

Please file a Github issue if build problems are not resolved after reviewing the available Alpha and Bitcoin documentation.

# ALPHA BUILD NOTES

Building Alpha follows the same instructions as building Bitcoin. The Alpha network shares the same features and rules as Bitcoin mainnet, as specified in Bitcoin Core v27.0.

The Linux version of the node `alphad` and GUI app `alpha-qt` are both supported. Macos versions have been tested on x86 and Arm. Windows binaries are also available (cross-compiled on Linux). Note that Windows users can build from source by following the Linux instructions when building in Ubuntu on [Windows Subsystem for Linux (WSL)](https://learn.microsoft.com/en-us/windows/wsl/about).

For more specific instructions on building see the specific build notes for each operating system in this directory.


## Building for Linux

### Getting started

Update your system and install the following tools required to build software.

```bash
sudo apt update
sudo apt upgrade
sudo apt install build-essential libtool autotools-dev automake pkg-config bsdmainutils curl git cmake bison
```

make sure that you are using g++ version > 10
You can check with 

```bash
g++ --version
```
download the latest version of the source code

```bash
git clone https://github.com/sakuyama2024/alpha_test1 alpha
cd alpha
```


### WSL for Windows

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

###Building Alpha


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

## Building for MacOS

Install xcode and brew (see instructions here 
[OSX build instructions](build-osx.md).

`brew install git automake libtool pkg-config cmake bison`


download the latest version of Alpha 

```bash
git clone https://github.com/sakuyama2024/alpha_test1 alpha
cd alpha
```

Alpha requires building with the depends system.

When calling `make` use `-j N` for N parallel jobs.


```bash
./autogen.sh
make -C depends
```

You should see a directory in `depends` something similiar to one of the folloiwng depending on whether your mac is x86 or ARM. The exact name may be different. 
  
`aarch64-apple-darwin23.3.0`  or `x86_64-apple-darwin23.4.0`

Copy the directory name and use it in the configure command. For example:

```bash
./configure --prefix=$PWD/depends/aarch64-apple-darwin23.3.0 --program-transform-name='s/bitcoin/alpha/g'
make
make install
```

or 

```bash
./configure --prefix=$PWD/depends/x86_64-apple-darwin23.4.0 --program-transform-name='s/bitcoin/alpha/g'
make
make install
```


### Executables
The compiled executables will be found in `depends/aarch64-apple-darwin23.3.0` (change to correct name)  and can be copied to a folder on your path, typically `/usr/local/bin/` or `$HOME/.local/bin/`.


## Building for Windows (by cross-compiling on Linux)

Build on Linux and generate executables which run on Windows.

Follow the same steps above for Linux. Then install the cross compiler and build.

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
daemon=1
debug=1
txindex=1

[alpha]
adddnsseed=

[alphatestnet]
adddnsseed=
```

### Connecting to the network

To help find other nodes on the network, a list of fixed seed nodes are hardwired in the code. They may or may not be avaialble.  If you know the IP addresses of a stable node use the `-addnode` and `-seednode` RPC calls.

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

Mining takes place using [Alphaminer](https://github.com/sakuyama2024/Alphaminer) which is dedicated mining software that connects to the alpha node and retrieves mining jobs via RPC `getblocktemplate`. The 'randomxfastmode' configuration option is not required for the Alpha node, since mining occurs inside `Alphaminer` which always runs in fast mode.

### Mining Pools

Third-party software exists for mining at pools.


Getting Help
---------------------

Please file a Github issue if build problems are not resolved after reviewing the available Alpha and Bitcoin documentation.

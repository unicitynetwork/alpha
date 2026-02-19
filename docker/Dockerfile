FROM ubuntu:22.04 AS builder

# Set environment variables
ENV DEBIAN_FRONTEND=noninteractive

# Install build dependencies
RUN apt-get update && apt-get install -y \
    build-essential libtool autotools-dev automake pkg-config bsdmainutils python3 \
    libssl-dev libevent-dev libboost-system-dev libboost-filesystem-dev \
    libboost-chrono-dev libboost-test-dev libboost-thread-dev \
    libminiupnpc-dev libzmq3-dev libdb-dev libdb++-dev git \
    cmake bison curl\
    && rm -rf /var/lib/apt/lists/*

# Set working directory
WORKDIR /alpha

# Copy the source code
COPY . .

# Build Dependencies and Alpha
RUN ./autogen.sh 
RUN make -C depends NO_QT=1 -j$(nproc)
RUN ./configure --without-gui --prefix=$PWD/depends/x86_64-pc-linux-gnu --program-transform-name='s/bitcoin/alpha/g'
RUN make -j$(nproc)
RUN make install

# --- Build alpha-miner (external miner for E2E testing) ---
FROM ubuntu:22.04 AS miner-builder
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y \
    build-essential autoconf automake libtool pkg-config \
    libcurl4-openssl-dev cmake git \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /miner
RUN git clone --depth 1 --recursive https://github.com/unicitynetwork/alpha-miner.git . \
    && ./autogen.sh && ./configure && make -j$(nproc) && strip minerd

# Second stage: create minimal runtime image
FROM ubuntu:22.04

# Install runtime dependencies
RUN apt-get update && apt-get install -y \
    libboost-system1.74.0 libboost-filesystem1.74.0 libboost-thread1.74.0 \
    libboost-chrono1.74.0 libevent-2.1-7 libzmq5 libminiupnpc17 \
    libcurl4 \
    && rm -rf /var/lib/apt/lists/*

# Update library path
RUN ldconfig /usr/local/lib

# Copy binaries from builder stage
COPY --from=builder /alpha/depends/x86_64-pc-linux-gnu/bin/alphad /usr/local/bin/
COPY --from=builder /alpha/depends/x86_64-pc-linux-gnu/bin/alpha-cli /usr/local/bin/
COPY --from=miner-builder /miner/minerd /usr/local/bin/

# Copy required libraries
COPY --from=builder /alpha/depends/x86_64-pc-linux-gnu/lib/librandomx.* /usr/local/lib/

# Configure library paths
RUN echo "/usr/local/lib" > /etc/ld.so.conf.d/local.conf && ldconfig

# Create directory for alpha config and data
RUN mkdir -p /etc/alpha /root/.alpha

# Copy the default configuration file from the docker directory
COPY docker/alpha.conf.default /etc/alpha/alpha.conf.default
COPY docker/entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

# Expose ports - P2P and RPC
EXPOSE 8590 8589

# This directory was already created above

# Set entrypoint
ENTRYPOINT ["/entrypoint.sh"]
CMD ["alphad"]
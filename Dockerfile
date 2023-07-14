FROM debian:bookworm

ENV DEBIAN_FRONTEND noninteractive
ENV DEBCONF_NONINTERACTIVE_SEEN true

WORKDIR /artifact

## Install dependencies

# Install standard utility + opam + binaryen + wabt + rakudo + clang-14 from the
# Debian repository
RUN apt-get update && \
    apt-get install -y opam git curl wget time \
                       binaryen wabt rakudo \
                       clang-14 llvm-14-dev lld-14 libclang-14-dev

# Install and setup OCaml environment
RUN opam init -y --disable-sandboxing --bare
RUN echo "test -r $HOME/.opam/opam-init/init.sh && . $HOME/.opam/opam-init/init.sh > /dev/null 2> /dev/null || true" >> $HOME/.profile
RUN opam switch create 4.14.1
RUN eval $(opam env) && opam install ocamlbuild

# Install and setup rust environment
RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
RUN "$HOME/.cargo/bin/rustup" target add wasm32-wasi

# Download WASI SDK 20.0
RUN curl -sL https://github.com/WebAssembly/wasi-sdk/releases/download/wasi-sdk-20/wasi-sdk-20.0-linux.tar.gz | tar xvz

# Download and install Go 18
RUN curl -sL https://go.dev/dl/go1.18.10.linux-amd64.tar.gz | tar xzf - -C /usr/local
ENV PATH="${PATH}:/usr/local/go/bin:/root/go/bin"

## Copy and build local sources
# Copy reference interpreter
COPY wasm-spec ./wasm-spec
WORKDIR /artifact/wasm-spec/interpreter
RUN eval $(opam env) && make opt
RUN ln -s /artifact/wasm-spec/interpreter/wasm /artifact/wasm-spec/interpreter/effect-handlers-wasm
ENV PATH="${PATH}:/artifact/wasm-spec/interpreter"

# Copy wasm-tools sources
WORKDIR /artifact
COPY wasm-tools ./wasm-tools

# Copy wasmtime sources
WORKDIR /artifact
COPY wasmtime ./wasmtime
WORKDIR /artifact/wasmtime
RUN "$HOME/.cargo/bin/cargo" build --release --features=default,unsafe_disable_continuation_linearity_check
ENV PATH="${PATH}:/artifact/wasmtime/target/release"

# Copy our patched TinyGo
WORKDIR /artifact
COPY tinygo tinygo
WORKDIR /artifact/tinygo
RUN go install
RUN make wasi-libc

# Copy benchmarks
WORKDIR /artifact
COPY benchmarks/c ./switching-throughput
RUN mv wasi-sdk-20.0 ./switching-throughput/wasi-sdk-20.0
COPY benchmarks/go ./go-compile-and-size
WORKDIR /artifact/switching-throughput
RUN make all

## Copy scripts
# Copy in the experiments and tests runner scripts
WORKDIR /artifact
COPY run-experiments.sh .
COPY run-tests.sh .

## Configure the environment
# Configure environment variables
ENV REFINTERP="/artifact/wasm-spec/interpreter"
ENV WASMTOOLS="/artifact/wasm-tools"
ENV WASMTIME="/artifact/wasmtime"
ENV TINYGO="/artifact/tinygo"
ENV CBENCH="/artifact/switching-throughput"

## Final steps
ENV DEBIAN_FRONTEND teletype
CMD ["/bin/bash"]

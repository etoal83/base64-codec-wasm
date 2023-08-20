# Base64 encoder/decoder in WebAssembly text format

This repository provides a WASM-compiled Base64 encoder/decoder coded in WebAssembly text format for my learning purpose.

## How to use

For example, to invoke Base64 encoder from command line via Wasmer runtime:

```
wasmer b64encode.wasm "Hello world!"
# SGVsbG8gd29ybGQh
```

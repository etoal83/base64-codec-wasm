# Base64 encoder/decoder in WASM

A command line tool of encoding/decoding string to/from Base64 string.
The source is written in WebAssembly text format (wat) for my learning purpose.

## How to use

This package is now available in [WebAssembly Package Manager (WAPM)](https://wasmer.io/etoal/base64@latest).
If you have [wasmer CLI](https://docs.wasmer.io/runtime/cli) installed on your machine, you can run the command like:

```
wasmer run etoal/base64 -e encode "Lorem ipsum"
# TG9yZW0gaXBzdW0=
```

This package provides two commands or entrypoints that can be specified with the `-e` option.

- `encode`
- `decode`

Or, you can execute the commands by cloning the repository and directly specifying the wasm file:

```
wasmer b64decode.wasm SGVsbG8gd29ybGQh
# Hello world!
```

## Caveats

- This project is nothing more than a beginner's practice. Don't use these commands in productions.
- The commands accept only the first argment as their input and the following arguments are discarded. To pass a whitespace-separated string as input, you should quote it.
- Since these WASM packages reserve 1 page (64KB) of linear memory on initialization, a too-long string of input is not tested and may cause unexpected result.

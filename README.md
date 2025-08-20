# Popping an alert from a sandboxed WebAssembly module

Corresponding Phrack article: https://phrack.org/issues/72/10_md#article

## Run

The `.wasm` is included, so running this PoC requires just a local web server:

```sh
python -m http.server 8080
```

Then navigate to http://localhost:8080/payload.htm

## Compile

To build the `.wat` yourself, use a recent version of binaryen, and run:

```sh
wasm-as -all payload.wat
```
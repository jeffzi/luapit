# LuaBench

CLI companion to [LuaMark](https://github.com/jeffzi/luamark) for comparing Lua library performance across git references.

**Status:** Under development. Not yet published to luarocks.

## Install (dev)

```sh
luarocks make luabench-dev-1.rockspec
```

## Usage

```sh
luabench ref benchmarks/ -r .#main -r .#feature
```

## License

MIT

# Luau syntax highlighting for TTT

`ttt-lang-luau` adds highlighting for `.luau` files. It is installed at `~/.config/ttt/plugins/ttt-lang-luau/` and needs no Lua code or permissions.

Restart TTT and select Allow when the plugin approval dialog appears. Open a `.luau` file, or `examples/highlighting.luau` for a sample. TTT registers the grammar automatically; no manual settings changes are needed.

The plugin leaves ordinary `.lua` highlighting unchanged. To use Luau highlighting for `.lua` too, change the manifest's `fileTypes` to `["luau", "lua"]`, then run Plugins: Reload from the command palette.

The bundled grammar comes from [JohnnyMorganz/Luau.tmLanguage](https://github.com/JohnnyMorganz/Luau.tmLanguage) at commit `350b8a6ef8ab7d0de843fa08f85b759ca76531dc`. It is unmodified. `LICENSE.md` retains the upstream MIT notices.

# Load every Claude Code plugin sync.py linked into ~/.local/share/claude-plugins,
# for the personal and work accounts alike (claudew only changes CLAUDE_CONFIG_DIR).
set -l plugins ~/.local/share/claude-plugins/*
if set -q plugins[1]
    set -gx CLAUDE_CODE_PLUGIN_DIRS (string join : $plugins)
end

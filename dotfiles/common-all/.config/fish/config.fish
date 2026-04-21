# Custom greeting with useful system info
function fish_greeting
    set_color bryellow
    echo -n (date "+%a %d %b %H:%M")
    set_color normal
    echo -n " | "
    set_color brmagenta
    echo -n (uptime | sed 's/.*up *//' | sed 's/,.*user.*//' | string trim)
    set_color normal
    echo -n " | "
    set_color brcyan
    echo -n (uptime | sed 's/.*load average: //' | cut -d',' -f1)
    set_color normal
    echo -n " | "
    set_color brgreen
    echo -n (free -h | awk '/^Mem:/ {print $3"/"$2}')
    set_color normal
    echo -n " | "
    set_color brblue
    echo -n (df -h / | awk 'NR==2 {print $3"/"$2}')
    set_color normal
    echo -n " | "
    set_color bryellow
    echo (ip -4 route get 1 2>/dev/null | awk '{print $7; exit}' || echo "n/a")
    set_color normal
end

set -x COLORTERM truecolor

# Add cargo to PATH
fish_add_path $HOME/.cargo/bin

# Set default editor
set -gx EDITOR hx

# Initialize direnv
direnv hook fish | source

# Use fish in nix-shell
any-nix-shell fish | source

# Tailscale exit node configuration
set -gx TAILSCALE_EXIT_NODE 'redline.tail2ec174.ts.net.'
alias ts-exit-on "sudo tailscale set --exit-node=$TAILSCALE_EXIT_NODE"
alias ts-exit-off 'sudo tailscale set --exit-node='

# Git aliases (oh-my-zsh style)
alias ga 'git add'
alias gaa 'git add --all'
alias gap 'git add -p'
alias gb 'git branch'
alias gbr 'git branch --remote'
alias gc 'git commit'
alias gca 'git commit -a'
alias gcamend 'git commit --amend'
alias gcam 'git commit -a -m'
alias gcm 'git commit -m'
alias gco 'git checkout'
alias gcop 'git checkout -p'
alias gd 'git diff'
alias gdc 'git diff --cached'
alias gf 'git fetch'
alias gfa 'git fetch --all'
alias gl 'git pull'
alias glr 'git pull --rebase'
alias glog 'git log'
alias gm 'git merge'
alias gp 'git push'
alias gpf 'git push -f'
alias grbc 'git rebase --continue'
alias grh 'git reset --hard'
alias gst 'git status'
alias gsta 'git stash'
alias gstp 'git stash pop'

function gfp --description 'Force pull from origin (fetch + reset --hard)'
    git fetch origin && git reset --hard origin/(git branch --show-current)
end

function dlretry --argument-names url filename
    if test -z "$url"
        echo "Usage: dlretry <url> [filename]" >&2
        return 1
    end

    # Default filename from URL if not provided
    if test -z "$filename"
        set filename (basename "$url" | string replace -r '\?.*' '')
    end

    set -l max_attempts 20
    set -l attempt 0
    while test $attempt -lt $max_attempts
        set attempt (math $attempt + 1)
        echo "Attempt $attempt/$max_attempts: $filename"
        curl -L -C - -o "$filename" "$url" \
            --retry 5 \
            --retry-delay 5 \
            --retry-all-errors \
            --connect-timeout 30
        and break
        echo "Failed, retrying in 10s..."
        sleep 10
    end
end

# Other miscellaneous aliases
alias clauded 'claude --dangerously-skip-permissions'
alias claudew 'CLAUDE_CONFIG_DIR=~/.claude-work claude'
alias claudewd 'CLAUDE_CONFIG_DIR=~/.claude-work claude --dangerously-skip-permissions'

# Initialize zoxide
zoxide init fish | source
export PATH="$HOME/.local/bin:$PATH"

# opencode
fish_add_path $HOME/.opencode/bin

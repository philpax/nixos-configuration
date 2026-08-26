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

# Steel cog root for the plugin-enabled Helix (forest.hx etc). Steel's own default is
# ambiguous (~/.steel if it happens to exist, else ~/.local/share/steel), so pin it.
set -gx STEEL_HOME $HOME/.config/steel

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

# Git worktrees, kept in <repo root>/.worktrees/
function _gwt_root --description 'Print the main worktree root, or fail'
    set -l root (git rev-parse --path-format=absolute --git-common-dir 2>/dev/null)
    or begin
        echo "Not in a git repository" >&2
        return 1
    end
    # .git dir of the main worktree; its parent is the main checkout
    dirname $root
end

function gwti --description 'Initialise .worktrees/ (gitignored) in the current repo'
    set -l root (_gwt_root); or return 1
    mkdir -p $root/.worktrees
    echo '*' >$root/.worktrees/.gitignore
    echo "Initialised $root/.worktrees"
end

function _gwt_cd --argument-names path
    cd $path; or return 1
    test -f .envrc; and direnv allow
end

function gwta --argument-names name ref --description 'Add a worktree at .worktrees/<name> on a new branch <name>'
    if test -z "$name"
        echo "Usage: gwta <name> [ref]" >&2
        return 1
    end
    set -l root (_gwt_root); or return 1
    test -d $root/.worktrees; or gwti; or return 1
    set -l path $root/.worktrees/$name
    if test -d $path
        echo "Worktree $name already exists" >&2
        _gwt_cd $path
        return 0
    end
    if git show-ref --verify --quiet refs/heads/$name
        git worktree add $path $name; or return 1
    else
        if test -z "$ref"
            set ref $name
        end
        if git rev-parse --verify --quiet "$ref^{commit}" >/dev/null
            git worktree add -b $name $path $ref; or return 1
        else
            git worktree add -b $name $path HEAD; or return 1
        end
    end
    _gwt_cd $path
end

function gwtl --description 'List the worktrees of the current repo'
    git worktree list $argv
end

function gwtc --argument-names name --description 'cd to .worktrees/<name>, or to the repo root if omitted'
    set -l root (_gwt_root); or return 1
    if test -z "$name"
        _gwt_cd $root
    else if test -d $root/.worktrees/$name
        _gwt_cd $root/.worktrees/$name
    else
        echo "No worktree at $root/.worktrees/$name" >&2
        return 1
    end
end

function gwtr --argument-names name --description 'Remove the worktree at .worktrees/<name>'
    if test -z "$name"
        echo "Usage: gwtr <name> [git worktree remove options]" >&2
        return 1
    end
    set -l root (_gwt_root); or return 1
    set -l path $root/.worktrees/$name
    # Can't remove the worktree we're standing in
    string match -q "$path*" (pwd -P); and cd $root
    git worktree remove $path $argv[2..]
end

function gwtp --description 'Prune worktree metadata for directories that are gone'
    git worktree prune -v $argv
end

function __gwta_branches
    git for-each-ref --format='%(refname:short)' refs/heads refs/remotes 2>/dev/null \
        | string match -v '*/HEAD'
end

function __gwtr_worktrees
    git worktree list --porcelain 2>/dev/null \
        | string match -r '^worktree .*/\\.worktrees/[^/]+$' \
        | string replace -r '^worktree .*/' ''
end

complete -c gwta -f -n 'test (count (commandline -opc)) -eq 1' \
    -a '(__gwta_branches)' -d 'Branch / worktree name'
complete -c gwta -f -n 'test (count (commandline -opc)) -eq 2' \
    -a '(__gwta_branches)' -d 'Starting branch'
complete -c gwtr -f -n 'test (count (commandline -opc)) -eq 1' \
    -a '(__gwtr_worktrees)' -d 'Worktree'

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
alias claudeumansd 'ANTHROPIC_AUTH_TOKEN=(head -1 ~/.tokens/umans-token) ANTHROPIC_BASE_URL="https://api.code.umans.ai" claude --dangerously-skip-permissions'
alias claudew 'CLAUDE_CONFIG_DIR=~/.claude-work claude'
alias claudewd 'CLAUDE_CONFIG_DIR=~/.claude-work claude --dangerously-skip-permissions'

# Initialize zoxide
zoxide init fish | source
export PATH="$HOME/.local/bin:$PATH"

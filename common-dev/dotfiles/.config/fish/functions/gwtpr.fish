function gwtpr --argument-names pr --description 'Check out a GitHub PR into .worktrees/pr-<number>'
    if test -z "$pr"
        echo "Usage: gwtpr <number-or-url>" >&2
        return 1
    end

    set -l root (_gwt_root); or return 1
    test -d $root/.worktrees; or gwti; or return 1

    set -l number (gh pr view $pr --json number --jq .number)
    or return 1

    set -l name pr-$number
    set -l path $root/.worktrees/$name

    if test -d $path
        echo "Worktree $name already exists" >&2
        cd $path
        return
    end

    gh pr checkout $pr --branch $name --worktree $path
    or return 1

    # Do not automatically trust a contributor-controlled .envrc.
    cd $path
end

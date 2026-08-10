function hermes-ssh --description 'SSH into the sandboxed Hermes Agent VM (host-only br-hermes bridge)'
    # The guest address is derived from redline/hermes/net.nix (guestAddr),
    # the single source of truth. The repo lives at $HOME/nixos-configuration
    # on redline; if it moves, update the path here.
    set -l repo "$HOME/nixos-configuration"
    set -l guest (sed -n 's/^  guestAddr = "\([^"]*\)";/\1/p' "$repo/redline/hermes/net.nix")
    if test -z "$guest"
        echo "hermes-ssh: could not read guestAddr from $repo/redline/hermes/net.nix" >&2
        return 1
    end
    ssh root@$guest $argv
end
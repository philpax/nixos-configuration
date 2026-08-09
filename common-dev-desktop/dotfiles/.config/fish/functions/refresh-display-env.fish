function refresh-display-env --description 'Re-sync display/session env vars from the running compositor'
    # Multiplexer servers (zellij, tmux) capture their environment when the server
    # starts and never update it. If the compositor restarts, or the server outlives
    # the login session, every shell inside inherits a stale WAYLAND_DISPLAY and GUI
    # programs fail with "NoCompositorListening". niri-session imports the live values
    # into the systemd user manager, so that's the authoritative source to re-read.

    set -l vars WAYLAND_DISPLAY DISPLAY XDG_RUNTIME_DIR XAUTHORITY \
        XDG_SESSION_TYPE XDG_CURRENT_DESKTOP XDG_SESSION_ID \
        DBUS_SESSION_BUS_ADDRESS

    set -l env_output (systemctl --user show-environment 2>/dev/null)
    if test $status -ne 0; or test -z "$env_output"
        echo "refresh-display-env: could not read the systemd user environment" >&2
        return 1
    end

    set -l changed 0
    for line in $env_output
        set -l parts (string split -m1 '=' -- $line)
        test (count $parts) -eq 2; or continue

        set -l key $parts[1]
        set -l value $parts[2]
        contains -- $key $vars; or continue

        # systemd quotes values that contain shell-special characters.
        if string match -qr '^".*"$' -- $value
            set value (string sub -s 2 -e -1 -- $value)
            set value (string replace -a '\\"' '"' -- $value)
            set value (string replace -a '\\\\' '\\' -- $value)
        end

        set -l old $$key
        if test "$value" != "$old"
            set -gx $key $value
            test -n "$old"; or set old '(unset)'
            printf '%s: %s -> %s\n' $key $old $value
            set changed 1
        end
    end

    if test $changed -eq 0
        echo "refresh-display-env: already up to date"
    end
end

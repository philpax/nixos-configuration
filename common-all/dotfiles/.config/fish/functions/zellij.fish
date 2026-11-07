function zellij --wraps zellij --description 'Share live sessions across compositors'
    set -l runtime /run/user/(id -u)
    if test -d $runtime; and not set -q ZELLIJ_SOCKET_DIR
        set -fx ZELLIJ_SOCKET_DIR $runtime/zellij
    end

    if test -S $runtime/bus; and command -q systemd-run
        set -l session_env -u DBUS_SESSION_BUS_ADDRESS -u XDG_RUNTIME_DIR
        for key in DBUS_SESSION_BUS_ADDRESS XDG_RUNTIME_DIR
            if set -q $key
                set -a session_env "$key=$$key"
            end
        end
        command env XDG_RUNTIME_DIR=$runtime DBUS_SESSION_BUS_ADDRESS=unix:path=$runtime/bus \
            systemd-run --user --scope --quiet --collect --expand-environment=no -- \
            env $session_env (command -s zellij) $argv
    else
        command zellij $argv
    end
end

function polytoken-set-models --description 'Set polytoken full/mini/nano defaults and reload all daemons'
    # $argv[1] = full model, $argv[2] = mini model, $argv[3] = nano model
    if test (count $argv) -ne 3
        echo "Usage: polytoken-set-models <full> <mini> <nano>" >&2
        return 1
    end

    python3 -c '
import re, sys, pathlib
p = pathlib.Path(sys.argv[1])
t = p.read_text()
t = re.sub(r"^  full: .*$", "  full: " + sys.argv[2], t, flags=re.M)
t = re.sub(r"^  mini: .*$", "  mini: " + sys.argv[3], t, flags=re.M)
t = re.sub(r"^  nano: .*$", "  nano: " + sys.argv[4], t, flags=re.M)
p.write_text(t)
' "$HOME/.config/polytoken/config.yaml" "$argv[1]" "$argv[2]" "$argv[3]"
    if test $status -ne 0
        echo "polytoken-set-models: failed to update config" >&2
        return 1
    end

    # Reload all active daemons
    for line in (polytoken sessions 2>/dev/null | string replace -r '^\s*' '' | grep -v '^SESSION_ID')
        set parts (string split ' ' -- "$line")
        set port $parts[2]
        set session_dir $parts[1]
        set token (jq -r .token ~/.local/share/polytoken/sessions/$session_dir/credential.json 2>/dev/null)
        if test -n "$token"
            set reload_status (curl -s -o /dev/null -w "%{http_code}" -X POST http://localhost:$port/reload \
                -H "Authorization: Bearer $token")
            if test "$reload_status" = "409"
                echo "  polytoken-set-models: session $session_dir busy (turn in flight) — skip reload" >&2
            else if test "$reload_status" != "200"
                echo "  polytoken-set-models: session $session_dir reload failed ($reload_status)" >&2
            end
        end
    end

    echo "polytoken-set-models: full=$argv[1], mini=$argv[2], nano=$argv[3]"
end
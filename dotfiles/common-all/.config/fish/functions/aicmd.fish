function aicmd --description 'Generate a NixOS/Linux shell command from a prompt, then run/discard/refine it'
    set -l sys "You are a Linux and NixOS systems administrator. Host: "(uname -n)", OS: NixOS, Shell: fish. Given a task, respond with exactly one shell command that accomplishes it. Output ONLY the raw command — no markdown, no code fences, no backticks, no explanation, no leading or trailing text. Join multiple commands with && or ; if truly necessary. Prefer modern tools over legacy: fd (find), rg (grep), bat (cat), eza (ls), dust (du), duf (df), procs (ps), btm (top/htop), z (cd), delta (diff), hyperfine (benchmark), tokei (count code), parallel (batch), fzf (fuzzy search), broot (tree). Also available: jq, python3, lsof, smartctl, sensors, dig, tailscale, croc, ffmpeg, yt-dlp, imagemagick, exiftool, git, gh, hx. NixOS tools: nixos-rebuild, nix profile, nh, nvd, nix-collect-garbage, systemctl, journalctl."

    set -l content (_ai_request aicmd \
        'Generate a NixOS/Linux shell command, then run (y), discard (n), or refine with a follow-up (f). Default: no.' \
        "$sys" '' $argv)
    if test $status -ne 0
        return 1
    end
    if test -z "$content"
        return
    end

    while true
        set -l cmd (string trim -- "$content")
        set cmd (string replace -r -- '^```[a-zA-Z]*\n' '' "$cmd")
        set cmd (string replace -r -- '\n```$' '' "$cmd")
        set cmd (string trim -- "$cmd")

        if test -z "$cmd"
            echo "aicmd: model returned an empty command" >&2
            return 1
        end

        echo
        set_color green
        echo "Command:"
        set_color cyan
        printf '%s\n' "$cmd"
        set_color normal
        echo

        if not read -l -P 'Run it? [y/N/f] ' confirm
            echo "Not running (no input)."
            return 1
        end

        if string match -qi 'y*' -- "$confirm"
            eval "$cmd"
            return
        else if string match -qi 'f*' -- "$confirm"
            if not read -l -P 'Follow-up: ' followup
                echo "Not running (no input)."
                return 1
            end
            if test -z "$followup"
                continue
            end
            set _ai_messages (echo "$_ai_messages" | jq -c --arg f "$followup" \
                '. + [{role: "user", content: $f}]')
            set content (_ai_chat "$_ai_model" "$temperature" "$_ai_messages")
            if test $status -ne 0
                return 1
            end
            set _ai_messages (echo "$_ai_messages" | jq -c --arg c "$content" \
                '. + [{role: "assistant", content: $c}]')
        else
            echo "Not running."
            return
        end
    end
end

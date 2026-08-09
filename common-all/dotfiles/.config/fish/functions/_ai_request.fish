function _ai_request --description 'Internal: shared LLM request logic for ai/aicmd'
    # Args: name description system temperature user_args...
    # name        — function name, for help/error text
    # description — one-line summary shown in --help
    # system      — system message, or empty for none
    # temperature — sampling temperature, or empty for server default
    # Exports $_ai_model and $_ai_messages (with assistant reply appended) for follow-ups.
    set -l DEFAULT_MODEL 'gemma-4-31b-it-qat'

    set -l name $argv[1]
    set -l desc $argv[2]
    set -l system_msg $argv[3]
    set -l temperature $argv[4]
    set -l user_args $argv[5..]

    set -l model $DEFAULT_MODEL
    set -l prompt_parts

    set -l i 1
    while test $i -le (count $user_args)
        switch $user_args[$i]
            case -m --model
                set i (math $i + 1)
                if test $i -gt (count $user_args)
                    echo "$name: --model requires a value" >&2
                    return 1
                end
                set model $user_args[$i]
            case -h --help
                echo "Usage: $name [-m|--model MODEL] <prompt>" >&2
                echo >&2
                echo "$desc" >&2
                echo >&2
                echo "Options:" >&2
                echo "  -m, --model MODEL  Model to use (default: $DEFAULT_MODEL)" >&2
                echo "  -h, --help         Show this help" >&2
                echo >&2
                echo "Endpoint: http://redline:7070/v1" >&2
                return
            case --
                set i (math $i + 1)
                set -a prompt_parts $user_args[$i..]
                break
            case '*'
                set -a prompt_parts $user_args[$i]
        end
        set i (math $i + 1)
    end

    set -l prompt (string join ' ' -- $prompt_parts)

    if test -z "$prompt"
        echo "Usage: $name [-m|--model MODEL] <prompt>" >&2
        echo "Run '$name --help' for details." >&2
        return 1
    end

    set -l messages (jq -nc --arg prompt "$prompt" '[{role: "user", content: $prompt}]')
    if test -n "$system_msg"
        set messages (echo "$messages" | jq -c --arg sys "$system_msg" \
            '[{role: "system", content: $sys}] + .')
    end

    set -g _ai_model $model
    set -g _ai_messages $messages

    set -l content (_ai_chat "$model" "$temperature" "$messages")
    if test $status -ne 0
        return 1
    end

    set _ai_messages (echo "$_ai_messages" | jq -c --arg c "$content" \
        '. + [{role: "assistant", content: $c}]')

    printf '%s\n' "$content"
end

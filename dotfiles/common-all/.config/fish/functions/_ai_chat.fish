function _ai_chat --description 'Internal: send a chat completion request and return content'
    # Args: model temperature messages_json
    set -l ENDPOINT 'http://redline:7070/v1'

    set -l model $argv[1]
    set -l temperature $argv[2]
    set -l messages $argv[3]

    set -l payload (jq -nc --arg model "$model" --argjson messages "$messages" \
        '{model: $model, messages: $messages}')
    if test -n "$temperature"
        set payload (echo "$payload" | jq -c --argjson temp "$temperature" \
            '. + {temperature: $temp}')
    end

    set -l response (curl -sS --max-time 600 -X POST "$ENDPOINT/chat/completions" \
        -H 'Content-Type: application/json' \
        -d "$payload")
    if test $status -ne 0
        return 1
    end

    set -l content (echo "$response" | jq -r '.choices[0].message.content // empty' 2>/dev/null)
    if test -z "$content" -o "$content" = null
        echo "_ai_chat: no content in response:" >&2
        printf '%s\n' "$response" >&2
        return 1
    end

    printf '%s\n' "$content"
end

function ai --description 'Ask the local LLM (ananke) a question and print the response'
    _ai_request ai \
        'Send a prompt to the local LLM and print the response.' \
        '' '' $argv
end

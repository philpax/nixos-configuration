function polytoken-gpt --description 'Switch polytoken config to GPT models and reload all daemons'
    polytoken-set-models \
        codex/gpt-5.6-luna(xhigh) \
        codex/gpt-5.6-luna(medium) \
        codex/gpt-5.6-luna(low)
end
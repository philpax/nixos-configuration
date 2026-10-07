function polytoken-gpt-ladder --description 'Switch polytoken config to the GPT model ladder and reload all daemons'
    polytoken-set-models \
        "codex/gpt-6.1-sol(xhigh)" \
        "codex/gpt-6-luna(xhigh)" \
        "codex/gpt-6-luna(low)"
end

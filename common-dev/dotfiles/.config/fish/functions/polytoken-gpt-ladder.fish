function polytoken-gpt-ladder --description 'Switch polytoken config to the GPT model ladder and reload all daemons'
    polytoken-set-models \
        "codex/gpt-5.6-sol(xhigh)" \
        "codex/gpt-5.6-luna(xhigh)" \
        "codex/gpt-5.6-luna(low)"
end

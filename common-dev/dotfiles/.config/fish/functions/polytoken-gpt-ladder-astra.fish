function polytoken-gpt-ladder-astra --description 'Switch polytoken config to the GPT Astra model ladder and reload all daemons'
    polytoken-set-models \
        "codex/gpt-6-astra(medium)" \
        "codex/gpt-5.6-sol(xhigh)" \
        "codex/gpt-5.6-luna(xhigh)"
end

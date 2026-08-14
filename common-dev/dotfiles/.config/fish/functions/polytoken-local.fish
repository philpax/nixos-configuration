function polytoken-local --description 'Switch polytoken config to local models and reload all daemons'
    polytoken-set-models \
        ananke-mindgame/qwen3.6-27b-ninfer-mtp3 \
        ananke-mindgame/qwen3.6-27b-ninfer-mtp3 \
        ananke-mindgame/qwen3.6-35b-a3b-ninfer-dflash7
end
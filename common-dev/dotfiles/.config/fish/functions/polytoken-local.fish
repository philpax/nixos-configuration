function polytoken-local --description 'Switch polytoken config to local models and reload all daemons'
    polytoken-set-models \
        ananke-mindgame/qwen3.8-27b-nvfp4-ninfer-mtp3 \
        ananke-mindgame/qwen3.8-27b-nvfp4-ninfer-mtp3 \
        ananke-mindgame/qwen3.8-flash-next-iq3s-basalt-c6
end
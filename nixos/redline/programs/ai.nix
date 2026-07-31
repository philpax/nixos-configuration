{ config, pkgs, ... }:

{
  environment.systemPackages = with pkgs; [
    # AI/ML tools
    (whisper-cpp.override { cudaSupport = true; })
    config.ai.llamaCppCuda
    # ik_llama.cpp shares binary names with mainline llama.cpp, so expose
    # it under an `ik-` prefix (ik-llama-server, ik-llama-cli, ...).
    # Referencing it here is also what causes it to be built at all —
    # nothing else consumes the package until an ananke service points
    # its `llama_server` at it.
    (pkgs.runCommand "ik-llama-cpp-prefixed" { } ''
      mkdir -p $out/bin
      for f in ${config.ai.ikLlamaCppCuda}/bin/*; do
        ln -s "$f" "$out/bin/ik-$(basename "$f")"
      done
    '')
  ];
}
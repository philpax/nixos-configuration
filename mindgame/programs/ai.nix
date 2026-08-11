{ config, pkgs, ... }:

{
  environment.systemPackages = [
    # Referencing it here is what causes it to actually be built — nothing
    # else on mindgame consumes ai.llamaCppCuda yet.
    config.ai.llamaCppCuda
  ];
}

{ config, pkgs, ... }:

{
  environment.systemPackages = [
    # Also on ananke's PATH; listed here for interactive use.
    config.ai.llamaCppCuda
  ];
}

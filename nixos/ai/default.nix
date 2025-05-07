{ config, pkgs, unstable, ... }:

let
  llamaCppCuda = (unstable.llama-cpp.override { cudaSupport = true; });
  largeModelProxy = import ./large-model-proxy-config.nix { inherit pkgs; };
in
{
  imports = [
    ./users.nix
    ./services.nix
  ];

  options = {
    ai = {
      llamaCppCuda = pkgs.lib.mkOption {
        type = pkgs.lib.types.package;
        description = "CUDA-enabled llama-cpp package";
        default = llamaCppCuda;
      };
      largeModelProxy = pkgs.lib.mkOption {
        type = pkgs.lib.types.attrs;
        description = "Large model proxy configuration";
        default = largeModelProxy;
      };
    };
  };

  config = {
    ai = {
      inherit llamaCppCuda largeModelProxy;
    };

    # Automatically add the ports to the firewall
    networking.firewall.allowedTCPPorts = largeModelProxy.ports;
  };
}
{ config, unstable, ... }:

{
  services.wivrn = {
    enable = true;
    openFirewall = true;
    autoStart = true;
    package = (unstable.wivrn.override { cudaSupport = true; });
  };
}

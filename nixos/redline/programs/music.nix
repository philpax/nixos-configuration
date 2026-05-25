{ config, pkgs, unstable, ... }:

{
  environment.systemPackages = with pkgs; [
    unstable.beets
    chromaprint
  ];
}

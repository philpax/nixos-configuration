{ config, pkgs, ... }:

{
  # The `ai` user owns every service under `/mnt/ssd0/ai/*` (ananke,
  # ComfyUI, paxcord, etc.). Those directories are traditionally
  # group-owned by `editabledata` with `g+w` so multiple services plus
  # human maintainers can read/write them; membership here is what
  # lets the `ai` user open files in them under its own systemd unit.
  #
  # If you add a new ai-service directory, run this on the filesystem
  # to match the convention (nix doesn't manage content outside the
  # store):
  #
  # ```sh
  # sudo chgrp -R editabledata <dir> && sudo chmod -R g+w <dir>
  # ```
  users.users.ai = {
    isNormalUser = true;
    description = "AI Services User";
    home = "/home/ai";
    group = "ai";
    extraGroups = [ "docker" "editabledata" ];
  };

  users.groups.ai = {};
}

{ ... }:

{
  fileSystems."/mnt/ssd1" = {
    device = "/dev/disk/by-uuid/8da747ad-fa7c-4b66-9782-5a52fa8f3960";
    fsType = "btrfs";
    options = [
      "compress=zstd"
      "noatime"
      "nofail"
    ];
  };
}

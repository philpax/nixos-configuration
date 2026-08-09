{ ... }:

let
  src = import ./lib/books-source.nix;
in
{
  fileSystems.${src.mountPoint} = {
    device = "//${src.smbHost}/${src.smbShare}";
    fsType = "cifs";
    options = [
      "guest"
      "ro"
      "uid=1000"
      "gid=100"
      "iocharset=utf8"
      "vers=3.0"
      "noauto"
      "x-systemd.automount"
      "x-systemd.idle-timeout=60"
      "x-systemd.mount-timeout=15s"
    ];
  };
}

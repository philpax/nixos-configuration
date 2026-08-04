{ pkgs, ... }:

# `boot-windows` — make the *next* boot go to Windows, then back to NixOS after.
#
# systemd-boot auto-discovers the Windows Boot Manager on the ESP; `bootctl
# set-oneshot` writes the volatile LoaderEntryOneShot EFI variable, which the
# loader consumes (and clears) on the next boot. Everything here needs root
# because the ESP is mounted 0700 root, so the script re-execs itself via sudo.
let
  boot-windows = pkgs.writeShellApplication {
    name = "boot-windows";
    runtimeInputs = with pkgs; [ systemd jq ];
    text = ''
      reboot_now=0
      for arg in "$@"; do
        case "$arg" in
          -r|--reboot) reboot_now=1 ;;
          -h|--help)
            echo "usage: boot-windows [-r|--reboot]"
            echo "  Sets the next boot to Windows (one-shot); -r reboots immediately."
            exit 0
            ;;
          *) echo "boot-windows: unknown argument: $arg" >&2; exit 2 ;;
        esac
      done

      if [ "$(id -u)" -ne 0 ]; then
        exec sudo "$0" "$@"
      fi

      entry=$(bootctl list --json=short \
        | jq -r 'map(select(.id == "auto-windows" or (.title // "" | test("windows"; "i"))))
                 | .[0].id // empty')

      if [ -z "$entry" ]; then
        echo "boot-windows: no Windows boot entry found. Available entries:" >&2
        bootctl list >&2
        exit 1
      fi

      bootctl set-oneshot "$entry"
      echo "boot-windows: next boot will use '$entry'."

      if [ "$reboot_now" -eq 1 ]; then
        systemctl reboot
      fi
    '';
  };
in
{
  environment.systemPackages = [ boot-windows ];
}

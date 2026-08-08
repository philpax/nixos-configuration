rec {
  # Primary mount points (source of truth)
  mounts = {
    ssd0 = "/mnt/ssd0"; # btrfs SSD - primary user data
    storage = "/storage"; # ZFS pool - bulk storage
  };

  # Backup destinations
  backups = {
    data = "/data"; # secondary SSD - local backup
    external = "/mnt/external"; # NTFS external drive - offsite backup
  };

  # User data directories (on primary SSD)
  audiomuse = "${mounts.ssd0}/audiomuse";
  immich = "${mounts.ssd0}/immich";
  music = "${mounts.ssd0}/music";
  music_inbox = "${mounts.ssd0}/music_inbox";
  notes = "${mounts.ssd0}/notes/Main";
  photos = "${mounts.ssd0}/photos";
  photos_icloud = "${photos}/iCloud";
  written = "${mounts.ssd0}/written";

  # User data directories (on ZFS pool - primary)
  backup = "${mounts.storage}/backup";
  datasets = "${mounts.storage}/datasets";
  documents = "${mounts.storage}/documents";
  downloads = "${mounts.storage}/downloads";
  games = "${mounts.storage}/games";
  installers = "${mounts.storage}/installers";
  videos = "${mounts.storage}/videos";

  # User data directories (on ZFS pool - backup copies from SSD)
  storageBackup = {
    photos = "${mounts.storage}/photos";
    music = "${mounts.storage}/music";
    written = "${mounts.storage}/written";
    notes = "${mounts.storage}/notes";
  };

  # AI directories
  ai = {
    base = "${mounts.ssd0}/ai";
    llm = "${mounts.ssd0}/ai/llm";
    comfyui = "${mounts.ssd0}/ai/ComfyUI";
    ananke = "${mounts.ssd0}/ai/ananke";
    paxcord = "${mounts.ssd0}/ai/paxcord";
    vllm = "${mounts.ssd0}/ai/vllm";
  };

  # Sandboxed Hermes Agent VM (see hermes/).
  #
  # `images` and `drop` are siblings rather than nested, because `images` is set
  # nodatacow for the qcow2 files and nodatacow also disables btrfs checksums.
  # The backups must keep their checksums, on a filesystem that silently
  # corrupted in August 2026.
  hermes = {
    base = "${mounts.ssd0}/hermes";
    images = "${mounts.ssd0}/hermes/images";
    drop = "${mounts.ssd0}/hermes/drop";
  };

  # Service directories
  paxboard = "${mounts.ssd0}/paxboard";
  minecraft = "${mounts.ssd0}/minecraft";
  fivem = "${mounts.ssd0}/fivem";
}

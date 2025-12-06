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
  };

  # AI directories
  ai = {
    base = "${mounts.ssd0}/ai";
    llm = "${mounts.ssd0}/ai/llm";
    comfyui = "${mounts.ssd0}/ai/ComfyUI";
    largeModelProxy = "${mounts.ssd0}/ai/large-model-proxy";
    paxcord = "${mounts.ssd0}/ai/paxcord";
  };

  # Service directories
  paxboard = "${mounts.ssd0}/paxboard";
}

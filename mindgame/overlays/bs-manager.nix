# Three bugs in bs-manager on Linux:
#
# 1. Desktop file missing %u — URL scheme handlers launch BSManager without
#    passing the URL, so OneClick links do nothing.
#    Fixed by overriding desktopItems with exec = "bs-manager %u".
#
# 2. Download Observable completes before file is flushed to disk —
#    request.service.ts's downloadFile() calls subscriber.complete() in the
#    got stream's "end" handler, which fires before pipeline(stream, file)
#    has finished writing. downloadMapZip returns, extraction starts on a
#    truncated zip, and yauzl hangs after the first entry.
#    Fixed by moving completion into pipeline().then() and gutting the
#    premature "end" handler (pipeline already calls file.end()).
#
# 3. yauzl extraction loses data — BsmZipExtractorEntry.extract() uses an
#    async openReadStream callback that awaits ensureDir() before creating
#    the write stream and calling pipe(). yauzl starts emitting data during
#    that await, so the first chunk(s) are lost, truncating the extracted
#    file. This also hangs the next readEntry() because yauzl's internal
#    state is left inconsistent.
#    Fixed by replacing the pipe-based extract() with a buffer-based approach:
#    read the entire entry into a Buffer using the existing read() method,
#    then write it to disk with writeFile(). No streaming races possible.
#
# Upstream issues: Zagrios/bs-manager#651 (OneClick), #932 (related hang)
final: prev:
{
  bs-manager = prev.bs-manager.overrideAttrs (old: {
    postPatch = (old.postPatch or "") + ''
      # Fix 2: complete the download Observable after pipeline finishes flushing,
      # not on the premature stream "end" event. Only gut downloadFile's end
      # handler, not downloadBuffer's.
      python3 ${./patch-request-service.py}

      # Fix 3: replace the streaming-based extract() with a zlib-based one.
      # The async openReadStream callback loses data during the await before pipe().
      # yauzl's lazyEntries + openReadStream hangs in this Electron environment.
      python3 ${./patch-zip-extractor.py}
    '';

    desktopItems = [
      (final.makeDesktopItem {
        desktopName = "BSManager";
        name = "BSManager";
        exec = "bs-manager %u";
        terminal = false;
        type = "Application";
        icon = "bs-manager";
        mimeTypes = [
          "x-scheme-handler/bsmanager"
          "x-scheme-handler/beatsaver"
          "x-scheme-handler/bsplaylist"
          "x-scheme-handler/modelsaber"
          "x-scheme-handler/web+bsmap"
        ];
        categories = [ "Utility" "Game" ];
      })
    ];
  });
}

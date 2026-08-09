# ruff: noqa: E501

# Fix request.service.ts: move subscriber completion from the premature
# stream "end" event into pipeline().then(), so the download Observable
# only completes after the file is fully flushed to disk.
# Also: ONLY gut the downloadFile end handler, not downloadBuffer's.
f = "src/main/services/request.service.ts"
s = open(f).read()

# Add .then() to pipeline call in downloadFile
s = s.replace(
    "pipeline(stream, file).catch(err => {",
    "pipeline(stream, file).then(() => { subscriber.next(progress); subscriber.complete(); }).catch(err => {",
)

# Remove the premature end handler in downloadFile ONLY.
# downloadFile's end handler has file?.end(); — downloadBuffer's doesn't.
# We remove the three lines: file?.end();, subscriber.next(progress);, subscriber.complete();
# but only from the block that contains file?.end();
lines = s.split("\n")
out = []
i = 0
while i < len(lines):
    # Detect the downloadFile end handler block: "stream.on('end', () => {"
    # followed by "file?.end();"
    if (
        "stream.on('end', () => {" in lines[i]
        and i + 1 < len(lines)
        and "file?.end();" in lines[i + 1]
    ):
        # Skip the entire block: on('end' ... { ... });
        # Find the closing });
        j = i
        while j < len(lines) and "});" not in lines[j]:
            j += 1
        # Skip lines i through j (inclusive)
        i = j + 1
        continue
    out.append(lines[i])
    i += 1

s = "\n".join(out)
open(f, "w").write(s)

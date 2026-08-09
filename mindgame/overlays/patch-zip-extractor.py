# ruff: noqa: E501
import sys

f = "src/main/models/bsm-zip-extractor.class.ts"
s = open(f).read()

# Add imports
s = s.replace(
    'import { createWriteStream, ensureDir } from "fs-extra";',
    'import { createWriteStream, ensureDir, writeFile } from "fs-extra";\nimport { inflateRawSync } from "zlib";\nimport { readFileSync } from "fs";',
)

# Store the zip file path for zlib-based extraction
s = s.replace(
    "private constructor(zip: ZipFile) {\n        this.zip = zip;\n    }",
    "private zipPath: string;\n    private constructor(zip: ZipFile, zipPath?: string) {\n        this.zip = zip;\n        this.zipPath = zipPath;\n    }",
)
s = s.replace("resolve(new BsmZipExtractor(zip));", "resolve(new BsmZipExtractor(zip, path));")

# Replace the batch extract() method to use zlib directly, bypassing yauzl streaming
old_method_start = "    public async extract(destination: string, opt?: { entriesNames?: (string|RegExp)[], abortToken?: AbortController }): Promise<string[]> {"
old_method_end = "        return Array.from(extracted);\n    }"
start = s.find(old_method_start)
end = s.find(old_method_end, start) + len(old_method_end)
if start < 0 or end < len(old_method_start):
    sys.exit("ERROR: could not find batch extract() method")

new_method = """    public async extract(destination: string, opt?: { entriesNames?: (string|RegExp)[], abortToken?: AbortController }): Promise<string[]> {
        const entriesNames = opt?.entriesNames;
        const abortToken = opt?.abortToken;

        if (abortToken?.signal?.aborted) {
            return [];
        }

        // Read all entry metadata via yauzl's readEntry (no streaming)
        const allEntries: BsmZipExtractorEntry[] = [];
        let entry = await this.readEntry();
        while (entry) {
            allEntries.push(entry);
            entry = await this.readEntry();
        }

        await ensureDir(destination);

        const extracted = new Set<string>();

        // If we have the zip file path, use pure Node zlib to bypass yauzl's
        // openReadStream which hangs in this Electron environment.
        if (this.zipPath) {
            const zipBuf = readFileSync(this.zipPath);
            for (const entryWrapper of allEntries) {
                if (abortToken?.signal?.aborted) break;
                const fileName = entryWrapper.fileName;
                if (entriesNames && !entriesNames.some(n => typeof n === "string" ? fileName === n : n.test(fileName))) continue;

                if (entryWrapper.isDirectory) {
                    await ensureDir(path.join(destination, fileName));
                    extracted.add(fileName);
                    continue;
                }

                const rawEntry = (entryWrapper as any).entry;
                const localHeaderOffset = rawEntry.relativeOffsetOfLocalHeader;
                if (localHeaderOffset === undefined) continue;

                const lhNameLen = zipBuf.readUInt16LE(localHeaderOffset + 26);
                const lhExtraLen = zipBuf.readUInt16LE(localHeaderOffset + 28);
                const dataOffset = localHeaderOffset + 30 + lhNameLen + lhExtraLen;
                const compMethod = rawEntry.compressionMethod;
                const compSize = rawEntry.compressedSize;

                let data: Buffer;
                if (compMethod === 0) {
                    data = zipBuf.subarray(dataOffset, dataOffset + compSize);
                } else {
                    data = inflateRawSync(zipBuf.subarray(dataOffset, dataOffset + compSize));
                }

                const destPath = path.join(destination, fileName);
                await ensureDir(path.dirname(destPath));
                await writeFile(destPath, data);
                extracted.add(fileName);
            }
            return Array.from(extracted);
        }

        // Fallback: use read() (may hang, but here for compatibility)
        for (const entryWrapper of allEntries) {
            if (abortToken?.signal?.aborted) break;
            const fileName = entryWrapper.fileName;
            if (entriesNames && !entriesNames.some(n => typeof n === "string" ? fileName === n : n.test(fileName))) continue;

            if (entryWrapper.isDirectory) {
                await ensureDir(path.join(destination, fileName));
                extracted.add(fileName);
                continue;
            }
            const data = await entryWrapper.read();
            const destPath = path.join(destination, fileName);
            await ensureDir(path.dirname(destPath));
            await writeFile(destPath, data);
            extracted.add(fileName);
        }

        return Array.from(extracted);
    }"""

s = s[:start] + new_method + s[end:]
open(f, "w").write(s)

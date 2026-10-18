import Foundation

/// A bounded, breadth-first file walk with explicit depth tracking.
///
/// Symbolic links are never followed (no loops, no escaping the folder), hidden
/// files are skipped, and the walk stops after `maxEntries` items so a huge
/// game folder cannot stall the app.
enum DirectoryWalker {
    struct Entry {
        let url: URL
        /// 1 for the root's direct children.
        let depth: Int
        let size: Int
    }

    static func files(
        under root: URL,
        maxDepth: Int,
        maxEntries: Int = 20_000,
        shouldDescend: (URL) -> Bool = { _ in true }
    ) -> [Entry] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey]
        var files: [Entry] = []
        var queue: [(URL, Int)] = [(root, 0)]
        var visited = 0

        while !queue.isEmpty {
            let (folder, depth) = queue.removeFirst()
            let children = (try? FileManager.default.contentsOfDirectory(
                at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]
            )) ?? []
            for child in children.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                visited += 1
                if visited > maxEntries { return files }
                let values = try? child.resourceValues(forKeys: Set(keys))
                if values?.isSymbolicLink == true { continue }
                if values?.isDirectory == true {
                    if depth + 1 < maxDepth, shouldDescend(child) {
                        queue.append((child, depth + 1))
                    }
                } else {
                    files.append(Entry(url: child, depth: depth + 1, size: values?.fileSize ?? 0))
                }
            }
        }
        return files
    }
}

import Foundation

/// The ordered set of local media accepted by one playback session.
struct PlaybackQueue: Equatable, Sendable {
    private(set) var items: [URL] = []
    private(set) var currentIndex: Int?

    var currentURL: URL? {
        guard let currentIndex, items.indices.contains(currentIndex) else { return nil }
        return items[currentIndex]
    }

    var nextURL: URL? {
        guard let currentIndex, items.indices.contains(currentIndex + 1) else { return nil }
        return items[currentIndex + 1]
    }

    var previousURL: URL? {
        guard let currentIndex, currentIndex > 0 else { return nil }
        return items[currentIndex - 1]
    }

    init(urls: [URL] = [], startingAt url: URL? = nil) {
        var uniqueByPath: [String: URL] = [:]
        for url in urls where url.isFileURL {
            let standardized = url.standardizedFileURL
            uniqueByPath[standardized.path] = standardized
        }
        items = uniqueByPath.values.sorted(by: Self.precedes)
        if let url {
            currentIndex = items.firstIndex { $0.standardizedFileURL.path == url.standardizedFileURL.path }
        } else if !items.isEmpty {
            currentIndex = 0
        }
    }

    mutating func select(_ index: Int) -> URL? {
        guard items.indices.contains(index) else { return nil }
        currentIndex = index
        return items[index]
    }

    /// Sorts the new batch, preserving both the existing order and current selection.
    mutating func append(_ urls: [URL]) {
        let existing = Set(items.map(\.path))
        items.append(contentsOf: Self(urls: urls).items.filter { !existing.contains($0.path) })
        if currentIndex == nil, !items.isEmpty { currentIndex = 0 }
    }

    @discardableResult
    mutating func advance() -> URL? {
        guard let currentIndex else { return nil }
        return select(currentIndex + 1)
    }

    @discardableResult
    mutating func goBack() -> URL? {
        guard let currentIndex else { return nil }
        return select(currentIndex - 1)
    }

    private static func precedes(_ lhs: URL, _ rhs: URL) -> Bool {
        let comparison = lhs.lastPathComponent.localizedStandardCompare(rhs.lastPathComponent)
        if comparison == .orderedSame { return lhs.path.localizedStandardCompare(rhs.path) == .orderedAscending }
        return comparison == .orderedAscending
    }
}

enum MediaFileDiscovery {
    /// Expands dropped/opened folders without following symlinks or entering packages.
    static func expand(
        _ inputs: [URL],
        fileManager: FileManager = .default,
        checkCancellation: () throws -> Void = { try Task.checkCancellation() }
    ) throws -> [URL] {
        var files: [URL] = []
        for input in inputs {
            try checkCancellation()
            guard input.isFileURL else { continue }
            let values = try input.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .isPackageKey])
            guard values.isSymbolicLink != true else { continue }
            guard values.isDirectory == true else {
                files.append(input.standardizedFileURL)
                continue
            }

            guard values.isPackage != true else { continue }
            var enumerationError: Error?
            guard let enumerator = fileManager.enumerator(
                at: input,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .isPackageKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants],
                errorHandler: { _, error in
                    enumerationError = error
                    return false
                }
            ) else {
                throw CocoaError(.fileReadUnknown, userInfo: [NSURLErrorKey: input])
            }

            while let candidate = enumerator.nextObject() as? URL {
                try checkCancellation()
                let candidateValues = try candidate.resourceValues(
                    forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .isPackageKey]
                )
                if candidateValues.isSymbolicLink == true || candidateValues.isPackage == true {
                    enumerator.skipDescendants()
                    continue
                }
                guard candidateValues.isDirectory != true, MediaFileType.supports(candidate) else { continue }
                files.append(candidate.standardizedFileURL)
            }
            try checkCancellation()
            // FileManager otherwise skips unreadable descendants silently. A partial
            // result must not replace the current queue as if every input was read.
            if let enumerationError { throw enumerationError }
        }
        try checkCancellation()
        return PlaybackQueue(urls: files).items
    }
}

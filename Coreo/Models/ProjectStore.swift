// ProjectStore.swift
// Coreo
//
// JSON project persistence rooted in Application Support/Coreo/Projects.

import Foundation

/// Errors thrown while reading or writing project documents.
enum ProjectStoreError: Error, LocalizedError {
    case missingProjectFile
    case unsupportedSchemaVersion
    case mediaCopyFailed(String)

    var errorDescription: String? {
        switch self {
        case .missingProjectFile:
            "Project file is missing."
        case .unsupportedSchemaVersion:
            "Project file uses an unsupported schema version."
        case let .mediaCopyFailed(filename):
            "Couldn't copy \(filename) into the project."
        }
    }
}

/// Loaded project plus the directory that contains its media files.
struct LoadedProject {
    /// Decoded project document.
    var project: CoreoProject

    /// Project directory containing `project.json` and copied media.
    let projectDirectory: URL
}

/// Persists Coreo projects as self-contained directories.
/// Shared coder state is only accessed while `codingLock` is held.
struct ProjectStore: @unchecked Sendable {
    /// Directory that contains every saved project directory.
    let projectsRoot: URL

    /// File manager used for disk operations.
    private let fileManager: FileManager

    /// JSON encoder used for project documents.
    private let encoder: JSONEncoder

    /// JSON decoder used for project documents.
    private let decoder: JSONDecoder

    /// Lock protecting shared JSON coder instances.
    private let codingLock = NSLock()

    /// Creates a project store.
    ///
    /// - Parameters:
    ///   - projectsRoot: Optional root for tests. Defaults to Application Support/Coreo/Projects.
    ///   - fileManager: File manager used for disk operations.
    init(projectsRoot: URL? = nil, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        self.projectsRoot = projectsRoot ?? Self.defaultProjectsRoot(fileManager: fileManager)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        self.encoder = encoder

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
    }

    /// Default Projects root in Application Support.
    ///
    /// - Parameter fileManager: File manager used to resolve Application Support.
    /// - Returns: Application Support/Coreo/Projects URL.
    static func defaultProjectsRoot(fileManager: FileManager = .default) -> URL {
        let applicationSupport = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? fileManager.temporaryDirectory
        return applicationSupport
            .appendingPathComponent("Coreo", isDirectory: true)
            .appendingPathComponent("Projects", isDirectory: true)
    }

    /// Legacy Documents/coreo_project.json URL retired by Wave 3.
    ///
    /// - Parameter fileManager: File manager used to resolve Documents.
    /// - Returns: Legacy project file URL.
    static func legacyProjectURL(fileManager: FileManager = .default) -> URL {
        let documents = fileManager.urls(
            for: .documentDirectory,
            in: .userDomainMask
        ).first ?? fileManager.temporaryDirectory
        return documents.appendingPathComponent("coreo_project.json")
    }

    /// Deletes the retired legacy project file if it exists.
    func removeLegacyProjectFile() {
        try? fileManager.removeItem(at: Self.legacyProjectURL(fileManager: fileManager))
    }

    /// Project directory URL for a project ID.
    ///
    /// - Parameter id: Project identity.
    /// - Returns: Directory URL.
    func projectDirectory(for id: UUID) -> URL {
        projectsRoot.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    /// Media directory URL for a project ID.
    ///
    /// - Parameter id: Project identity.
    /// - Returns: Media directory URL.
    func mediaDirectory(for id: UUID) -> URL {
        projectDirectory(for: id).appendingPathComponent("media", isDirectory: true)
    }

    /// Absolute project media URL for a video.
    ///
    /// - Parameters:
    ///   - video: Video asset with a relative path.
    ///   - projectID: Project identity.
    /// - Returns: Absolute file URL.
    func mediaURL(for video: VideoAsset, projectID: UUID) -> URL {
        projectDirectory(for: projectID).appendingPathComponent(video.relativePath)
    }

    /// Copies source media into the project media directory and builds a video asset.
    ///
    /// - Parameters:
    ///   - sourceURL: Source media selected by the user.
    ///   - projectID: Project identity.
    /// - Returns: Video metadata referencing a project-relative media path.
    func importVideo(from sourceURL: URL, projectID: UUID) async throws -> VideoAsset {
        let copiedURL = try copyMedia(from: sourceURL, projectID: projectID)
        let relativePath = "media/\(copiedURL.lastPathComponent)"
        return try await VideoAsset.from(url: copiedURL, relativePath: relativePath)
    }

    /// Copies replacement media into the project directory and preserves the existing asset ID.
    ///
    /// - Parameters:
    ///   - sourceURL: Replacement video selected by the user.
    ///   - existing: Missing asset whose identity and edits should be retained.
    ///   - projectID: Project identity.
    /// - Returns: Replacement asset plus copied file URL for cancellation cleanup.
    func importReplacementVideo(
        from sourceURL: URL,
        replacing existing: VideoAsset,
        projectID: UUID
    ) async throws -> (asset: VideoAsset, copiedURL: URL) {
        let copiedURL = try copyMedia(from: sourceURL, projectID: projectID)
        let relativePath = "media/\(copiedURL.lastPathComponent)"
        do {
            let imported = try await VideoAsset.from(url: copiedURL, relativePath: relativePath)
            return (existing.replacingMedia(with: imported), copiedURL)
        } catch {
            try? fileManager.removeItem(at: copiedURL)
            throw error
        }
    }

    /// Copies source media into a project directory.
    ///
    /// - Parameters:
    ///   - sourceURL: Source file URL.
    ///   - projectID: Project identity.
    /// - Returns: Destination URL inside the project media directory.
    func copyMedia(from sourceURL: URL, projectID: UUID) throws -> URL {
        let mediaDirectory = mediaDirectory(for: projectID)
        try fileManager.createDirectory(at: mediaDirectory, withIntermediateDirectories: true)
        let sanitizedName = Self.sanitizedFilename(sourceURL.lastPathComponent)
        let destination = mediaDirectory.appendingPathComponent("\(UUID().uuidString)-\(sanitizedName)")
        do {
            try fileManager.copyItem(at: sourceURL, to: destination)
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            var mutableDestination = destination
            try? mutableDestination.setResourceValues(values)
            return destination
        } catch {
            throw ProjectStoreError.mediaCopyFailed(sourceURL.lastPathComponent)
        }
    }

    /// Deletes copied media for a video.
    ///
    /// - Parameters:
    ///   - video: Video whose media should be removed.
    ///   - projectID: Project identity.
    func deleteMedia(for video: VideoAsset, projectID: UUID) {
        try? fileManager.removeItem(at: mediaURL(for: video, projectID: projectID))
    }

    /// Deletes an entire project directory.
    ///
    /// - Parameter projectID: Project identity.
    func deleteProject(projectID: UUID) {
        try? fileManager.removeItem(at: projectDirectory(for: projectID))
    }

    /// Saves a project using atomic replacement.
    ///
    /// - Parameter project: Project document to write.
    func save(_ project: CoreoProject) throws {
        let encodedData = try encode(project)
        try save(project, encodedData: encodedData)
    }

    /// Saves pre-encoded data atomically. Internal seam for tests.
    ///
    /// - Parameters:
    ///   - project: Project identity and directory owner.
    ///   - encodedData: JSON data to write.
    func save(
        _ project: CoreoProject,
        encodedData: Data,
        simulateFailureAfterTemporaryWrite: Bool = false
    ) throws {
        let directory = projectDirectory(for: project.id)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent("project.json")
        let temporary = directory.appendingPathComponent(".project-\(UUID().uuidString).tmp")
        try encodedData.write(to: temporary, options: .completeFileProtectionUnlessOpen)
        if simulateFailureAfterTemporaryWrite {
            try? fileManager.removeItem(at: temporary)
            throw CocoaError(.fileWriteUnknown)
        }

        if fileManager.fileExists(atPath: destination.path) {
            _ = try fileManager.replaceItemAt(destination, withItemAt: temporary)
        } else {
            try fileManager.moveItem(at: temporary, to: destination)
        }
    }

    /// Loads the most recently modified project, validating schema and media.
    ///
    /// - Returns: Loaded project or nil if none can be read.
    func loadMostRecentProject() -> LoadedProject? {
        removeLegacyProjectFile()
        guard let projectDirectories = try? fileManager.contentsOfDirectory(
            at: projectsRoot,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }

        let sortedDirectories = projectDirectories.sorted { lhs, rhs in
            let keys: Set<URLResourceKey> = [.contentModificationDateKey]
            let lhsDate = (try? lhs.resourceValues(forKeys: keys))?.contentModificationDate ?? .distantPast
            let rhsDate = (try? rhs.resourceValues(forKeys: keys))?.contentModificationDate ?? .distantPast
            return lhsDate > rhsDate
        }

        for directory in sortedDirectories {
            if let loaded = loadProject(at: directory) {
                return loaded
            }
        }
        return nil
    }

    /// Loads a project from a specific project directory.
    ///
    /// - Parameter directory: Directory containing `project.json`.
    /// - Returns: Loaded project or nil if missing/corrupt.
    func loadProject(at directory: URL) -> LoadedProject? {
        let url = directory.appendingPathComponent("project.json")
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        do {
            let data = try Data(contentsOf: url)
            let schema = try decode(ProjectSchemaProbe.self, from: data)
            guard schema.schemaVersion == CoreoProject.currentSchemaVersion else {
                renameStaleProjectFile(url)
                return nil
            }
            var project = try decode(CoreoProject.self, from: data)
            project.sanitizeReferences()
            markMissingMedia(in: &project, projectDirectory: directory)
            return LoadedProject(project: project, projectDirectory: directory)
        } catch {
            renameStaleProjectFile(url)
            return nil
        }
    }

    /// Marks videos whose copied media files are unavailable.
    ///
    /// - Parameters:
    ///   - project: Project whose videos will be updated.
    ///   - projectDirectory: Directory containing media files.
    func markMissingMedia(in project: inout CoreoProject, projectDirectory: URL) {
        for index in project.videos.indices {
            let mediaURL = project.videos[index].mediaURL(projectRoot: projectDirectory)
            project.videos[index].mediaAvailability = fileManager.fileExists(atPath: mediaURL.path)
                ? .available
                : .missing
        }
    }

    /// Removes unavailable videos from a project and deletes their copied media.
    ///
    /// - Parameters:
    ///   - project: Project to mutate.
    ///   - projectID: Project identity.
    /// - Returns: Removed videos.
    @discardableResult
    func removeMissingMedia(from project: inout CoreoProject, projectID: UUID) -> [VideoAsset] {
        let missing = project.videos.filter { $0.mediaAvailability == .missing }
        project.videos.removeAll { $0.mediaAvailability == .missing }
        for video in missing {
            deleteMedia(for: video, projectID: projectID)
        }
        project.sanitizeReferences()
        return missing
    }

    /// Replaces corrupt/stale project files with a renamed copy for inspection.
    ///
    /// - Parameter url: Project JSON URL to rename.
    func renameStaleProjectFile(_ url: URL) {
        guard fileManager.fileExists(atPath: url.path) else { return }
        let staleURL = url
            .deletingLastPathComponent()
            .appendingPathComponent("project.stale-\(Int(Date().timeIntervalSince1970)).json")
        try? fileManager.moveItem(at: url, to: staleURL)
    }

    /// Builds a filesystem-safe filename.
    ///
    /// - Parameter filename: Original filename.
    /// - Returns: Sanitized filename.
    static func sanitizedFilename(_ filename: String) -> String {
        let fallback = "video.mov"
        let cleaned = filename
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? fallback : cleaned
    }

    /// Encodes a project document using the shared encoder.
    ///
    /// - Parameter project: Project to encode.
    /// - Returns: JSON data.
    private func encode(_ project: CoreoProject) throws -> Data {
        codingLock.lock()
        defer { codingLock.unlock() }
        return try encoder.encode(project)
    }

    /// Decodes a project document using the shared decoder.
    ///
    /// - Parameters:
    ///   - type: Decodable result type.
    ///   - data: JSON data.
    /// - Returns: Decoded value.
    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        codingLock.lock()
        defer { codingLock.unlock() }
        return try decoder.decode(type, from: data)
    }
}

private struct ProjectSchemaProbe: Decodable {
    let schemaVersion: Int?
}

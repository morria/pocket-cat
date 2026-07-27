// Profile persistence: files in the app's iCloud Drive Documents folder
// (visible in the Files app) with a local-Documents fallback when iCloud
// is unavailable. Enumeration is on-demand; coordination uses
// NSFileCoordinator so we play nicely with iCloud sync.

import Foundation

public struct StoredProfile: Sendable, Identifiable, Equatable {
    public let url: URL
    public let profile: RadioProfile

    public var id: UUID { profile.id }
}

public actor ProfileStore {
    public enum Location: Sendable, Equatable {
        case iCloud
        case localFallback
    }

    private let directory: URL
    public nonisolated let location: Location

    /// Resolves the iCloud ubiquity container (entitlement required); falls
    /// back to local Documents so the app works signed-out too.
    public init() {
        let manager = FileManager.default
        if let container = manager.url(forUbiquityContainerIdentifier: nil) {
            let docs = container.appendingPathComponent("Documents",
                                                        isDirectory: true)
            try? manager.createDirectory(at: docs,
                                         withIntermediateDirectories: true)
            directory = docs
            location = .iCloud
        } else {
            let docs = URL.documentsDirectory
                .appendingPathComponent("Profiles", isDirectory: true)
            try? manager.createDirectory(at: docs,
                                         withIntermediateDirectories: true)
            directory = docs
            location = .localFallback
        }
    }

    /// Test seam: store rooted at an arbitrary directory.
    public init(directory: URL) {
        self.directory = directory
        self.location = .localFallback
        try? FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
    }

    public func list() throws -> [StoredProfile] {
        let manager = FileManager.default
        let urls = try manager.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil)
        return urls
            .filter { $0.pathExtension == RadioProfile.fileExtension }
            .compactMap { url in
                guard let data = coordinatedRead(url),
                      let profile = try? RadioProfile.decode(data) else {
                    return nil
                }
                return StoredProfile(url: url, profile: profile)
            }
            .sorted { $0.profile.savedAt > $1.profile.savedAt }
    }

    @discardableResult
    public func save(_ profile: RadioProfile) throws -> StoredProfile {
        let base = profile.name.isEmpty ? "profile" : profile.name
        let safe = base.components(
            separatedBy: CharacterSet(charactersIn: "/\\:?%*|\"<>"))
            .joined(separator: "-")
        let url = uniqueURL(stem: safe)
        try coordinatedWrite(try profile.encoded(), to: url)
        return StoredProfile(url: url, profile: profile)
    }

    public func delete(_ stored: StoredProfile) throws {
        var coordinatorError: NSError?
        var innerError: Error?
        NSFileCoordinator().coordinate(
            writingItemAt: stored.url, options: .forDeleting,
            error: &coordinatorError) { url in
            do { try FileManager.default.removeItem(at: url) }
            catch { innerError = error }
        }
        if let error = coordinatorError ?? (innerError as NSError?) {
            throw error
        }
    }

    public func rename(_ stored: StoredProfile,
                       to name: String) throws -> StoredProfile {
        var profile = stored.profile
        profile.name = name
        try coordinatedWrite(try profile.encoded(), to: stored.url)
        return StoredProfile(url: stored.url, profile: profile)
    }

    // MARK: - Coordination plumbing

    private func uniqueURL(stem: String) -> URL {
        let manager = FileManager.default
        var candidate = directory.appendingPathComponent(stem)
            .appendingPathExtension(RadioProfile.fileExtension)
        var counter = 2
        while manager.fileExists(atPath: candidate.path) {
            candidate = directory.appendingPathComponent("\(stem) \(counter)")
                .appendingPathExtension(RadioProfile.fileExtension)
            counter += 1
        }
        return candidate
    }

    private func coordinatedRead(_ url: URL) -> Data? {
        var data: Data?
        NSFileCoordinator().coordinate(
            readingItemAt: url, error: nil) { url in
            data = try? Data(contentsOf: url)
        }
        return data
    }

    private func coordinatedWrite(_ data: Data, to url: URL) throws {
        var coordinatorError: NSError?
        var innerError: Error?
        NSFileCoordinator().coordinate(
            writingItemAt: url, options: .forReplacing,
            error: &coordinatorError) { url in
            do { try data.write(to: url, options: .atomic) }
            catch { innerError = error }
        }
        if let error = coordinatorError ?? (innerError as NSError?) {
            throw error
        }
    }
}

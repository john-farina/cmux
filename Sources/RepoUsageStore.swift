import Foundation

/// Tracks how often repos are worked in, for the fork's project menus:
/// terminal cwd reports (normalized to the git root) and explicit project
/// opens bump a per-repo counter persisted at `~/.cmuxterm/repo-usage.json`.
/// Menus merge these auto-detected repos with saved `projects` and sort both
/// by usage.
@MainActor
final class RepoUsageStore {
    static let shared = RepoUsageStore()

    struct Entry: Codable, Equatable {
        var count: Int
        var lastUsed: TimeInterval
    }

    private(set) var repos: [String: Entry] = [:]
    private let fileURL: URL
    private var loaded = false
    private var saveScheduled = false
    // why: cd-ing around inside one repo shouldn't inflate its count — one
    // bump per repo per cooldown window.
    private var lastBumpAt: [String: TimeInterval] = [:]
    private let bumpCooldown: TimeInterval = 30 * 60

    init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cmuxterm", isDirectory: true)
            .appendingPathComponent("repo-usage.json")
    }

    /// Records activity in `directory`, normalized to its git root. Non-repo
    /// directories are ignored — the auto-detected list is repos only.
    func recordActivity(directory: String, now: Date = Date()) {
        guard let root = Self.gitRoot(of: directory) else { return }
        loadIfNeeded()
        let timestamp = now.timeIntervalSince1970
        if let last = lastBumpAt[root], timestamp - last < bumpCooldown { return }
        lastBumpAt[root] = timestamp
        bump(root, timestamp: timestamp)
    }

    /// Records an explicit project open (menu/palette). Not cooldown-gated and
    /// not repo-gated — saved projects may point at non-git directories.
    func recordOpen(path: String, now: Date = Date()) {
        loadIfNeeded()
        let root = Self.gitRoot(of: path) ?? (path as NSString).expandingTildeInPath
        bump(root, timestamp: now.timeIntervalSince1970)
    }

    func usageCount(path: String) -> Int {
        loadIfNeeded()
        return repos[path]?.count ?? 0
    }

    /// Auto-detected repos by usage, highest first, excluding `excluding` paths.
    func topRepos(excluding: Set<String> = [], limit: Int = 8) -> [String] {
        loadIfNeeded()
        return repos
            .filter { !excluding.contains($0.key) }
            .sorted { ($0.value.count, $0.value.lastUsed) > ($1.value.count, $1.value.lastUsed) }
            .prefix(limit)
            .map(\.key)
    }

    /// Walks up from `directory` to the enclosing `.git` directory. Returns
    /// nil outside a repo, for the home directory itself, and for `/`.
    nonisolated static func gitRoot(of directory: String, fileManager: FileManager = .default) -> String? {
        var current = (directory as NSString).expandingTildeInPath
        let home = fileManager.homeDirectoryForCurrentUser.path
        for _ in 0..<16 {
            if current == "/" || current == home { return nil }
            if fileManager.fileExists(atPath: (current as NSString).appendingPathComponent(".git")) {
                return current
            }
            let parent = (current as NSString).deletingLastPathComponent
            if parent == current { return nil }
            current = parent
        }
        return nil
    }

    // MARK: - Private

    private func bump(_ path: String, timestamp: TimeInterval) {
        var entry = repos[path] ?? Entry(count: 0, lastUsed: 0)
        entry.count += 1
        entry.lastUsed = timestamp
        repos[path] = entry
        scheduleSave()
    }

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([String: Entry].self, from: data) else { return }
        repos = decoded
    }

    private func scheduleSave() {
        guard !saveScheduled else { return }
        saveScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            guard let self else { return }
            self.saveScheduled = false
            self.saveNow()
        }
    }

    func saveNow() {
        guard let data = try? JSONEncoder().encode(repos) else { return }
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? data.write(to: fileURL, options: [.atomic])
    }
}

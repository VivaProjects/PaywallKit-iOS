import Foundation

/// 仅扫描和删除已隔离目录；是否可淘汰仍由持有租约的所有者决定。
enum WebPaywallCacheMaintenance {
    struct Entry: Sendable {
        let directory: URL
        let size: Int
        let date: Date
    }

    /// 磁盘遍历在后台执行，不占用资源仓库或主线程执行器。
    static func entries(at root: URL, measureSize: Bool) async -> [Entry] {
        await Task.detached(priority: .utility) {
            let fm = FileManager.default
            let directories = (try? fm.contentsOfDirectory(at: root,
                includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
            // 进程中断遗留的隔离目录也只在后台回收，不交给启动路径递归删除。
            for directory in directories where directory.lastPathComponent.hasPrefix("trash-") {
                try? fm.removeItem(at: directory)
            }
            return directories.compactMap { directory -> Entry? in
                guard directory.lastPathComponent.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil else { return nil }
                var size = 0
                if measureSize, let files = fm.enumerator(at: directory, includingPropertiesForKeys: [.fileSizeKey]) {
                    for case let file as URL in files {
                        size += (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                    }
                }
                let date = (try? directory.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return Entry(directory: directory, size: size, date: date)
            }.sorted { $0.date < $1.date }
        }.value
    }

    /// 所有者在无挂起区间检查租约并改名，新使用者只能取得新的原路径。
    static func quarantine(_ directory: URL) -> URL? {
        let trash = directory.deletingLastPathComponent().appendingPathComponent("trash-" + UUID().uuidString)
        do {
            try FileManager.default.moveItem(at: directory, to: trash)
            return trash
        } catch { return nil }
    }

    /// 递归删除只接触独立隔离目录，允许原缓存路径同时重新下载。
    static func remove(_ directory: URL) async -> String? {
        await Task.detached(priority: .utility) {
            let bytes = try? Data(contentsOf: directory.appendingPathComponent("package.json"))
            let metadata = bytes.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            do {
                try FileManager.default.removeItem(at: directory)
                return metadata?["runtimeEnvironment"] as? String ?? ""
            } catch { return nil }
        }.value
    }
}

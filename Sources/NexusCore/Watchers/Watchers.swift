import Foundation
import CoreServices
import AppKit
import IOKit.ps

// MARK: - FSEvents folder watcher

public enum FileChangeKind: String { case created, modified, removed, renamed }

public struct FileChange {
    public var path: String
    public var kind: FileChangeKind
    public var isDirectory: Bool
    public var inode: UInt64?
}

/// Recursive FSEvents watcher with file-level events, extended data (inode) and self-ignore
/// (so Nexus' own moves never re-trigger rules).
public final class FileWatcher {
    public var onChange: (([FileChange]) -> Void)?
    private var stream: FSEventStreamRef?
    private let queue = DispatchQueue(label: "app.nexus.fsevents", qos: .utility)
    public private(set) var paths: [String] = []

    public init() {}
    deinit { stop() }

    private var lastEventId: FSEventStreamEventId = FSEventStreamEventId(kFSEventStreamEventIdSinceNow)

    public func start(paths: [String], latency: TimeInterval = 0.8) {
        // Resume from where the previous stream stopped so a restart never drops events
        if let s = stream { lastEventId = FSEventStreamGetLatestEventId(s) }
        stop()
        let existing = paths.filter { FileManager.default.fileExists(atPath: $0) }
        guard !existing.isEmpty else { return }
        self.paths = existing
        var ctx = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let flags = UInt32(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes |
                           kFSEventStreamCreateFlagUseExtendedData | kFSEventStreamCreateFlagIgnoreSelf | kFSEventStreamCreateFlagWatchRoot)
        let callback: FSEventStreamCallback = { _, info, count, eventPaths, eventFlags, eventIds in
            guard let info else { return }
            let watcher = Unmanaged<FileWatcher>.fromOpaque(info).takeUnretainedValue()
            let array = Unmanaged<CFArray>.fromOpaque(eventPaths).takeUnretainedValue() as NSArray
            var changes: [FileChange] = []
            for i in 0..<count {
                let flags = Int(eventFlags[i])
                var path: String?
                var inode: UInt64?
                if let dict = array[i] as? NSDictionary {
                    path = dict[kFSEventStreamEventExtendedDataPathKey] as? String
                    inode = (dict[kFSEventStreamEventExtendedFileIDKey] as? NSNumber)?.uint64Value
                } else {
                    path = array[i] as? String
                }
                if Int(eventFlags[i]) & kFSEventStreamEventFlagHistoryDone != 0 { continue }
                guard let raw = path else { continue }
                let p = Paths.canonical(raw)
                let isDir = flags & kFSEventStreamEventFlagItemIsDir != 0
                let exists = FileManager.default.fileExists(atPath: p)
                let kind: FileChangeKind
                if flags & kFSEventStreamEventFlagItemRenamed != 0 { kind = exists ? .renamed : .removed }
                else if flags & kFSEventStreamEventFlagItemRemoved != 0 && !exists { kind = .removed }
                else if flags & kFSEventStreamEventFlagItemCreated != 0 && exists { kind = .created }
                else if flags & (kFSEventStreamEventFlagItemModified | kFSEventStreamEventFlagItemInodeMetaMod) != 0 && exists { kind = .modified }
                else if !exists { kind = .removed }
                else { continue }
                changes.append(FileChange(path: p, kind: kind, isDirectory: isDir, inode: inode))
            }
            if count > 0 { watcher.lastEventId = eventIds[count - 1] }
            if !changes.isEmpty { watcher.onChange?(changes) }
        }
        stream = FSEventStreamCreate(kCFAllocatorDefault, callback, &ctx, existing as CFArray,
                                     lastEventId, latency, FSEventStreamCreateFlags(flags))
        guard let stream else { return }
        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
    }

    public func stop() {
        guard let s = stream else { return }
        FSEventStreamStop(s)
        FSEventStreamInvalidate(s)
        FSEventStreamRelease(s)
        stream = nil
    }
}

/// Waits until a file's size stops changing (downloads, copies, exports in progress).
public final class FileStabilizer {
    private var pending: [String: (size: Int64, checks: Int)] = [:]
    private let queue = DispatchQueue(label: "app.nexus.stabilizer", qos: .utility)
    public var onStable: ((String) -> Void)?
    public init() {}

    public func submit(_ path: String) {
        queue.async {
            if self.pending[path] == nil {
                self.pending[path] = (-1, 0)
                self.check(path)
            }
        }
    }

    private func check(_ path: String) {
        queue.asyncAfter(deadline: .now() + 1.5) {
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: path) else { self.pending[path] = nil; return }
            let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
            let prev = self.pending[path] ?? (-1, 0)
            if size == prev.size {
                if prev.checks >= 1 { self.pending[path] = nil; self.onStable?(path); return }
                self.pending[path] = (size, prev.checks + 1)
            } else {
                self.pending[path] = (size, 0)
            }
            if (self.pending[path]?.checks ?? 0) < 40 { self.check(path) } else { self.pending[path] = nil }
        }
    }
}

// MARK: - System monitor

public struct SystemSnapshot {
    public var diskFreeGB: Double
    public var diskTotalGB: Double
    public var idleSeconds: Double
    public var onACPower: Bool
    public var lowPowerMode: Bool
    public var thermalState: ProcessInfo.ThermalState
    public var mountedVolumes: [String]

    public var shouldThrottle: Bool { !onACPower || lowPowerMode || thermalState == .serious || thermalState == .critical }
}

public final class SystemMonitor {
    private let bus: EventBus
    private var observers: [NSObjectProtocol] = []
    private var timer: DispatchSourceTimer?
    private var wasIdle = false
    public private(set) var snapshot: SystemSnapshot
    public var idleThresholdMinutes = 15

    public init(bus: EventBus) {
        self.bus = bus
        snapshot = SystemMonitor.sample()
    }

    public func start() {
        let nc = NSWorkspace.shared.notificationCenter
        func app(_ n: Notification) -> NSRunningApplication? { n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication }
        observers.append(nc.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: nil) { [weak self] n in
            guard let a = app(n) else { return }
            self?.bus.post(.appLaunched(name: a.localizedName ?? "", bundleId: a.bundleIdentifier))
        })
        observers.append(nc.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: nil) { [weak self] n in
            guard let a = app(n) else { return }
            self?.bus.post(.appQuit(name: a.localizedName ?? "", bundleId: a.bundleIdentifier))
        })
        observers.append(nc.addObserver(forName: NSWorkspace.didMountNotification, object: nil, queue: nil) { [weak self] n in
            let url = n.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL
            let name = n.userInfo?[NSWorkspace.localizedVolumeNameUserInfoKey] as? String ?? url?.lastPathComponent ?? ""
            self?.bus.post(.volumeMounted(name: name, path: url?.path ?? ""))
        })
        observers.append(nc.addObserver(forName: NSWorkspace.didUnmountNotification, object: nil, queue: nil) { [weak self] n in
            let url = n.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL
            let name = n.userInfo?[NSWorkspace.localizedVolumeNameUserInfoKey] as? String ?? url?.lastPathComponent ?? ""
            self?.bus.post(.volumeUnmounted(name: name, path: url?.path ?? ""))
        })
        observers.append(nc.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: nil) { [weak self] _ in
            self?.bus.post(.wake)
        })

        let t = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        t.schedule(deadline: .now() + 5, repeating: 60, leeway: .seconds(10))
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
    }

    public func stop() {
        observers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        observers.removeAll()
        timer?.cancel(); timer = nil
    }

    private func tick() {
        snapshot = Self.sample()
        bus.post(.diskSpace(freeGB: snapshot.diskFreeGB))
        let idleMin = Int(snapshot.idleSeconds / 60)
        if idleMin >= idleThresholdMinutes && !wasIdle { wasIdle = true; bus.post(.idle(minutes: idleMin)) }
        if idleMin < 1 { wasIdle = false }
    }

    public static func sample() -> SystemSnapshot {
        let home = URL(fileURLWithPath: NSHomeDirectory())
        let vals = try? home.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey])
        let free = Double(vals?.volumeAvailableCapacityForImportantUsage ?? 0) / 1_000_000_000
        let total = Double(vals?.volumeTotalCapacity ?? 0) / 1_000_000_000
        let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: UInt32.max)!)
        var ac = true
        if let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
           let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String? {
            ac = type == kIOPMACPowerKey
        }
        let volumes = (FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: nil, options: [.skipHiddenVolumes]) ?? [])
            .map(\.lastPathComponent)
        return SystemSnapshot(diskFreeGB: free, diskTotalGB: total, idleSeconds: idle, onACPower: ac,
                              lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled,
                              thermalState: ProcessInfo.processInfo.thermalState, mountedVolumes: volumes)
    }

    /// Recursive folder size + file count (skips packages' internals quickly via allocated size keys).
    public static func folderStats(_ path: String, limit: Int = 200_000) -> (size: Int64, count: Int) {
        guard let en = FileManager.default.enumerator(at: URL(fileURLWithPath: path), includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey],
                                                      options: [.skipsHiddenFiles]) else { return (0, 0) }
        var size: Int64 = 0, count = 0
        for case let url as URL in en {
            guard let v = try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey]), v.isRegularFile == true else { continue }
            size += Int64(v.totalFileAllocatedSize ?? 0)
            count += 1
            if count > limit { break }
        }
        return (size, count)
    }

    public static func topLevelCount(_ path: String) -> Int {
        ((try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []).filter { !$0.hasPrefix(".") }.count
    }
}

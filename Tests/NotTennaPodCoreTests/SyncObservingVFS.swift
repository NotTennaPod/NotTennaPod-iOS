import Foundation
import SQLite3

/// A pass-through SQLite file system that watches what actually reaches the disk: for every write-ahead log it records
/// the log's length at its latest successful sync (`xSync`). A power loss keeps a log exactly up to its last sync, so
/// that length is the boundary a power-loss simulation cuts at, observed rather than inferred from which transactions
/// should have been durable. Every call is forwarded unchanged to the default file system.
///
/// `install()` makes it the default for connections opened afterwards (other connections are unaffected) until
/// `restoreDefault()`; it stays registered so that connections opened meanwhile keep working.
enum SyncObservingVFS {
    private struct ShimFile {
        var base: sqlite3_file
        var real: UnsafeMutablePointer<sqlite3_file>?
        var log: UnsafeMutablePointer<CChar>?
    }

    private struct Log { var end: Int64 = 0, synced: Int64 = 0, syncs = 0 }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var logs: [String: Log] = [:]
    nonisolated(unsafe) private static var base: UnsafeMutablePointer<sqlite3_vfs>?
    nonisolated(unsafe) private static var shim: UnsafeMutablePointer<sqlite3_vfs>?
    nonisolated(unsafe) private static var methods: UnsafeMutablePointer<sqlite3_io_methods>?

    static func install() {
        lock.lock(); defer { lock.unlock() }
        if shim == nil {
            guard let found = sqlite3_vfs_find(nil) else { return }
            base = found
            let vfs = UnsafeMutablePointer<sqlite3_vfs>.allocate(capacity: 1)
            vfs.initialize(to: found.pointee)
            vfs.pointee.zName = UnsafePointer(strdup("ntp-sync-observer"))
            vfs.pointee.szOsFile = Int32(MemoryLayout<ShimFile>.stride) + found.pointee.szOsFile
            vfs.pointee.pNext = nil
            vfs.pointee.xOpen = { _, name, file, flags, outFlags in
                guard let file, let base = SyncObservingVFS.base else { return SQLITE_ERROR }
                let shim = UnsafeMutableRawPointer(file).assumingMemoryBound(to: ShimFile.self)
                let real = UnsafeMutableRawPointer(file).advanced(by: MemoryLayout<ShimFile>.stride).assumingMemoryBound(to: sqlite3_file.self)
                let status = base.pointee.xOpen(base, name, real, flags, outFlags)
                guard status == SQLITE_OK else { file.pointee.pMethods = nil; return status }
                shim.pointee.real = real
                shim.pointee.log = nil
                if (flags & SQLITE_OPEN_WAL) != 0, let name { shim.pointee.log = strdup(SyncObservingVFS.canonical(String(cString: name))) }
                file.pointee.pMethods = UnsafePointer(SyncObservingVFS.methods)
                return SQLITE_OK
            }
            methods = makeMethods()
            shim = vfs
        }
        sqlite3_vfs_register(shim, 1)
    }

    static func restoreDefault() {
        lock.lock(); defer { lock.unlock() }
        if let base { sqlite3_vfs_register(base, 1) }
    }

    /// The log's length at its latest sync, the number of syncs, and whether the log was seen at all.
    static func synced(log path: String) -> (length: Int, syncs: Int, observed: Bool) {
        lock.lock(); defer { lock.unlock() }
        guard let log = logs[canonical(path)] else { return (0, 0, false) }
        return (Int(log.synced), log.syncs, true)
    }

    private static func canonical(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else { return URL(fileURLWithPath: path).standardizedFileURL.path }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    private static func note(_ file: UnsafeMutablePointer<sqlite3_file>?, _ change: (inout Log) -> Void) {
        guard let path = shimFile(file).pointee.log.map({ String(cString: $0) }) else { return }
        lock.lock(); defer { lock.unlock() }
        change(&logs[path, default: Log()])
    }

    private static func shimFile(_ file: UnsafeMutablePointer<sqlite3_file>?) -> UnsafeMutablePointer<ShimFile> {
        UnsafeMutableRawPointer(file!).assumingMemoryBound(to: ShimFile.self)
    }

    private static func real(_ file: UnsafeMutablePointer<sqlite3_file>?) -> UnsafeMutablePointer<sqlite3_file> {
        shimFile(file).pointee.real!
    }

    private static func makeMethods() -> UnsafeMutablePointer<sqlite3_io_methods> {
        var m = sqlite3_io_methods()
        m.iVersion = 3
        m.xClose = { file in
            let real = SyncObservingVFS.real(file)
            let status = real.pointee.pMethods.pointee.xClose(real)
            let shim = SyncObservingVFS.shimFile(file)
            free(shim.pointee.log); shim.pointee.log = nil
            return status
        }
        m.xRead = { file, buffer, amount, offset in
            let real = SyncObservingVFS.real(file); return real.pointee.pMethods.pointee.xRead(real, buffer, amount, offset)
        }
        m.xWrite = { file, buffer, amount, offset in
            let real = SyncObservingVFS.real(file)
            let status = real.pointee.pMethods.pointee.xWrite(real, buffer, amount, offset)
            // A log is written from its start again only when it restarts (its header); otherwise frames are appended
            // and earlier frame headers may be rewritten, so the log's end is the furthest write since the restart.
            if status == SQLITE_OK { SyncObservingVFS.note(file) { $0.end = offset == 0 ? Int64(amount) : max($0.end, offset + Int64(amount)) } }
            return status
        }
        m.xTruncate = { file, size in
            let real = SyncObservingVFS.real(file)
            let status = real.pointee.pMethods.pointee.xTruncate(real, size)
            if status == SQLITE_OK { SyncObservingVFS.note(file) { $0.end = min($0.end, size); $0.synced = min($0.synced, size) } }
            return status
        }
        m.xSync = { file, flags in
            let real = SyncObservingVFS.real(file)
            let status = real.pointee.pMethods.pointee.xSync(real, flags)
            if status == SQLITE_OK { SyncObservingVFS.note(file) { $0.synced = $0.end; $0.syncs += 1 } }
            return status
        }
        m.xFileSize = { file, size in
            let real = SyncObservingVFS.real(file); return real.pointee.pMethods.pointee.xFileSize(real, size)
        }
        m.xLock = { file, level in
            let real = SyncObservingVFS.real(file); return real.pointee.pMethods.pointee.xLock(real, level)
        }
        m.xUnlock = { file, level in
            let real = SyncObservingVFS.real(file); return real.pointee.pMethods.pointee.xUnlock(real, level)
        }
        m.xCheckReservedLock = { file, result in
            let real = SyncObservingVFS.real(file); return real.pointee.pMethods.pointee.xCheckReservedLock(real, result)
        }
        m.xFileControl = { file, operation, argument in
            let real = SyncObservingVFS.real(file); return real.pointee.pMethods.pointee.xFileControl(real, operation, argument)
        }
        m.xSectorSize = { file in
            let real = SyncObservingVFS.real(file); return real.pointee.pMethods.pointee.xSectorSize(real)
        }
        m.xDeviceCharacteristics = { file in
            let real = SyncObservingVFS.real(file); return real.pointee.pMethods.pointee.xDeviceCharacteristics(real)
        }
        m.xShmMap = { file, page, size, extend, pointer in
            let real = SyncObservingVFS.real(file); return real.pointee.pMethods.pointee.xShmMap(real, page, size, extend, pointer)
        }
        m.xShmLock = { file, offset, count, flags in
            let real = SyncObservingVFS.real(file); return real.pointee.pMethods.pointee.xShmLock(real, offset, count, flags)
        }
        m.xShmBarrier = { file in
            let real = SyncObservingVFS.real(file); real.pointee.pMethods.pointee.xShmBarrier(real)
        }
        m.xShmUnmap = { file, delete in
            let real = SyncObservingVFS.real(file); return real.pointee.pMethods.pointee.xShmUnmap(real, delete)
        }
        m.xFetch = { file, offset, amount, pointer in
            let real = SyncObservingVFS.real(file); return real.pointee.pMethods.pointee.xFetch(real, offset, amount, pointer)
        }
        m.xUnfetch = { file, offset, pointer in
            let real = SyncObservingVFS.real(file); return real.pointee.pMethods.pointee.xUnfetch(real, offset, pointer)
        }
        let pointer = UnsafeMutablePointer<sqlite3_io_methods>.allocate(capacity: 1)
        pointer.initialize(to: m)
        return pointer
    }
}

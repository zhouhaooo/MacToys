// SPDX-License-Identifier: MIT

import AppKit

/// 主线程上的有界图片缓存，内存压力时立即丢弃可重建的数据。
final class ImageCache<Key: Hashable> {
    private struct Entry {
        let image: NSImage
        let cost: Int
        var access: UInt64
    }
    private var entries: [Key: Entry] = [:]
    private var clock: UInt64 = 0
    private var bytes = 0
    private let countLimit: Int
    private let byteLimit: Int
    private var pressure: DispatchSourceMemoryPressure?

    init(countLimit: Int, byteLimit: Int, observeMemoryPressure: Bool = true) {
        self.countLimit = countLimit
        self.byteLimit = byteLimit
        if observeMemoryPressure {
            let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
            source.setEventHandler { [weak self] in self?.removeAll() }
            source.resume()
            pressure = source
        }
    }

    deinit { pressure?.cancel() }

    subscript(key: Key) -> NSImage? {
        get {
            guard var entry = entries[key] else { return nil }
            clock += 1
            entry.access = clock
            entries[key] = entry
            return entry.image
        }
        set {
            remove(key)
            guard let image = newValue else { return }
            clock += 1
            let cost = Self.cost(of: image)
            entries[key] = Entry(image: image, cost: cost, access: clock)
            bytes += cost
            while entries.count > countLimit || bytes > byteLimit {
                guard let oldest = entries.min(by: { $0.value.access < $1.value.access })?.key else { break }
                remove(oldest)
            }
        }
    }

    func remove(_ key: Key) {
        if let entry = entries.removeValue(forKey: key) { bytes -= entry.cost }
    }

    func remove(where predicate: (Key) -> Bool) {
        entries.keys.filter(predicate).forEach(remove)
    }

    func removeAll() { entries = [:]; bytes = 0 }

    static func cost(of image: NSImage) -> Int {
        let representations = image.representations
        guard !representations.isEmpty else {
            return max(1, Int(image.size.width)) * max(1, Int(image.size.height)) * 4
        }
        return representations.reduce(0) { total, representation in
            let pixels = max(1, representation.pixelsWide) * max(1, representation.pixelsHigh)
            return total + pixels * 4
        }
    }
}

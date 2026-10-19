// SPDX-License-Identifier: MIT

import Foundation
import Testing
@testable import MacToys

@Suite("剪贴板存储")
struct ClipboardStoreTests {
    private func tempDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("MacToysTests-\(UUID().uuidString)", isDirectory: true)
    }

    private func text(_ s: String) -> ClipboardCapture {
        ClipboardCapture(kind: .text, text: s, fingerprint: ClipboardStore.fingerprint([Data(s.utf8)]))
    }

    @Test func addDeduplicatesAndOrders() {
        let dir = tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = ClipboardStore(directory: dir)
        let t0 = Date(timeIntervalSince1970: 1000)
        store.add(text("一"), maxItems: 10, now: t0)
        store.add(text("二"), maxItems: 10, now: t0.addingTimeInterval(1))
        store.add(text("一"), maxItems: 10, now: t0.addingTimeInterval(2))
        #expect(store.items.count == 2)
        #expect(store.sortedItems.map(\.text) == ["一", "二"])
    }

    @Test func trimKeepsMostRecentlyUsed() {
        let dir = tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = ClipboardStore(directory: dir)
        let t0 = Date(timeIntervalSince1970: 1000)
        store.add(text("固定"), maxItems: 3, now: t0)
        for i in 1...5 {
            store.add(text("条目\(i)"), maxItems: 3, now: t0.addingTimeInterval(Double(i)))
        }
        #expect(store.items.count == 3)
        #expect(store.sortedItems.map(\.text) == ["条目5", "条目4", "条目3"])
    }

    @Test func searchUsesPinyin() {
        let dir = tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = ClipboardStore(directory: dir)
        store.add(text("剪贴板历史"), maxItems: 10)
        store.add(text("银行卡号 6222"), maxItems: 10)
        #expect(store.search("jtb").map(\.text) == ["剪贴板历史"])
        #expect(store.search("yhk").map(\.text) == ["银行卡号 6222"])
        #expect(store.search("").count == 2)
    }

    @Test func persistsToDisk() {
        let dir = tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = ClipboardStore(directory: dir)
        var capture = text("带格式")
        capture.extras = ["public.rtf": Data("{\\rtf1 x}".utf8)]
        store.add(capture, maxItems: 10)
        store.saveNow()

        let reloaded = ClipboardStore(directory: dir)
        #expect(reloaded.items.count == 1)
        #expect(reloaded.extraData(for: reloaded.items[0])["public.rtf"] == Data("{\\rtf1 x}".utf8))
    }

    @Test func clearAllRemovesFiles() throws {
        let dir = tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = ClipboardStore(directory: dir)
        var capture = ClipboardCapture(kind: .image, png: Data([0x89, 0x50, 0x4E, 0x47]), fingerprint: "img")
        capture.imageSize = CGSize(width: 1, height: 1)
        store.add(capture, maxItems: 10)
        let url = try #require(store.imageURL(for: store.items[0]))
        #expect(FileManager.default.fileExists(atPath: url.path))
        store.clearAll()
        store.saveNow()
        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(store.items.isEmpty)
    }
}

extension ClipboardStoreTests {
    @Test func clearAllNeedsConfirmationAndIncludesHiddenSearchResults() {
        let dir = tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = ClipboardStore(directory: dir)
        store.add(text("一"), maxItems: 10)
        store.add(text("二"), maxItems: 10)
        let model = ClipboardPanelModel(store: store)
        model.clearTapped()
        #expect(model.confirmingClear && store.items.count == 2)
        model.query = "一"
        #expect(!model.confirmingClear)
        model.clearTapped()
        #expect(model.confirmingClear && store.items.count == 2)
        model.clearTapped()
        #expect(!model.confirmingClear && store.items.isEmpty)
        #expect(model.query.isEmpty && model.results.isEmpty)
        model.clearTapped()
        #expect(!model.confirmingClear)
    }

    @Test func cleansUpOrphanedFiles() throws {
        let dir = tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = ClipboardStore(directory: dir)
        var capture = ClipboardCapture(kind: .image, png: Data([1, 2, 3]), fingerprint: "img")
        capture.imageSize = CGSize(width: 1, height: 1)
        store.add(capture, maxItems: 10)
        store.saveNow()
        let blobs = dir.appendingPathComponent("blobs")
        let orphan = blobs.appendingPathComponent("orphan.png")
        try Data([9]).write(to: orphan)

        let reloaded = ClipboardStore(directory: dir)
        #expect(!FileManager.default.fileExists(atPath: orphan.path))
        let image = try #require(reloaded.imageURL(for: reloaded.items[0]))
        #expect(FileManager.default.fileExists(atPath: image.path))
    }

    @Test func unreadableHistoryIsKept() throws {
        let dir = tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: dir.appendingPathComponent("history.json"))
        let store = ClipboardStore(directory: dir)
        #expect(store.items.isEmpty)
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        #expect(names.contains { $0.hasPrefix("history-unreadable-") })
    }

    @Test func clearAllRemovesEveryItem() {
        let dir = tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = ClipboardStore(directory: dir)
        store.add(text("固定"), maxItems: 10)
        store.add(text("一"), maxItems: 10)
        store.add(text("二"), maxItems: 10)
        #expect(store.items.count == 3)
        store.clearAll()
        #expect(store.items.isEmpty)
    }
}


extension ClipboardStoreTests {
    @Test func legacyPinnedHistoryLoadsAsOrdinaryHistory() throws {
        let dir = tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = ClipboardStore(directory: dir)
        store.add(text("旧记录"), maxItems: 10)
        store.saveNow()
        let history = dir.appendingPathComponent("history.json")
        var json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: history)) as? [[String: Any]])
        json[0]["pinned"] = true
        try JSONSerialization.data(withJSONObject: json).write(to: history)
        let reloaded = ClipboardStore(directory: dir)
        #expect(reloaded.items.first?.text == "旧记录")
        reloaded.clearAll()
        reloaded.saveNow()
        #expect(ClipboardStore(directory: dir).items.isEmpty)
    }

    @Test @MainActor func clearWhileLoadingDoesNotRestoreOldHistory() async throws {
        let dir = tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let seed = ClipboardStore(directory: dir)
        seed.add(text("旧记录"), maxItems: 10)
        seed.saveNow()
        let store = ClipboardStore(directory: dir, loadInBackground: true)
        store.clearAll()
        for _ in 0..<30 { try await Task.sleep(for: .milliseconds(10)) }
        store.saveNow()
        #expect(store.items.isEmpty)
        #expect(ClipboardStore(directory: dir).items.isEmpty)
    }
}

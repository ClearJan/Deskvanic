import AppKit
import DeskvanicCore

/// CaptureStudio 服务装配点（与 ClipVault 相同模式：组合根注入，可独立运行）。
@MainActor
public enum CaptureServices {
    public static var store: CaptureStore = makeDefaultStore()

    public static let capturesDirectory = AppEnvironment.capturesDirectory

    public static func inject(store newStore: CaptureStore) {
        store = newStore
    }

    private static func makeDefaultStore() -> CaptureStore {
        let db = Database(url: AppEnvironment.databaseURL)
        return CaptureStore(database: db, index: SearchIndex(database: db))
    }
}

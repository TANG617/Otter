import Foundation

struct RenderMemoryCacheStats: Equatable, Sendable {
    let entryCount: Int
    let pinnedEntryCount: Int
    let estimatedCost: Int
    let costLimit: Int
}

final class RenderMemoryCache: NSObject, NSCacheDelegate, @unchecked Sendable {
    static let defaultCostLimit = 128 * 1_024 * 1_024

    private final class KeyObject: NSObject {
        let value: RenderCacheKey

        init(_ value: RenderCacheKey) { self.value = value }

        override var hash: Int { value.hashValue }

        override func isEqual(_ object: Any?) -> Bool {
            (object as? KeyObject)?.value == value
        }
    }

    private final class EntryObject {
        let key: RenderCacheKey
        let surface: RenderSurface

        init(key: RenderCacheKey, surface: RenderSurface) {
            self.key = key
            self.surface = surface
        }
    }

    private let cache = NSCache<KeyObject, EntryObject>()
    private let lock = NSLock()
    private var keys: Set<RenderCacheKey> = []
    private var costs: [RenderCacheKey: Int] = [:]
    private var pinned: [RenderCacheKey: RenderSurface] = [:]

    let costLimit: Int

    init(costLimit: Int = RenderMemoryCache.defaultCostLimit) {
        self.costLimit = max(costLimit, 0)
        super.init()
        cache.totalCostLimit = self.costLimit
        cache.delegate = self
    }

    func value(for key: RenderCacheKey) -> RenderSurface? {
        cache.object(forKey: KeyObject(key))?.surface ?? lock.withLock { pinned[key] }
    }

    func insert(_ surface: RenderSurface, for key: RenderCacheKey) {
        cache.setObject(EntryObject(key: key, surface: surface), forKey: KeyObject(key), cost: surface.estimatedByteCost)
        lock.withLock {
            keys.insert(key)
            costs[key] = surface.estimatedByteCost
        }
    }

    func pin(_ key: RenderCacheKey) {
        guard let surface = value(for: key) else { return }
        lock.withLock { pinned[key] = surface }
    }

    func unpin(_ key: RenderCacheKey) {
        _ = lock.withLock { pinned.removeValue(forKey: key) }
    }

    func invalidate(accountNamespace: UUID, assetID: UUID) {
        let matching = lock.withLock {
            keys.filter {
                $0.byteKey.accountNamespace == accountNamespace && $0.byteKey.assetID == assetID
            }
        }
        for key in matching { remove(key) }
    }

    func removeAll(keepingPinned: Bool = false) {
        if keepingPinned {
            let retained = lock.withLock { pinned }
            cache.removeAllObjects()
            lock.withLock {
                keys = Set(retained.keys)
                costs = retained.mapValues(\.estimatedByteCost)
            }
            for (key, surface) in retained {
                cache.setObject(
                    EntryObject(key: key, surface: surface),
                    forKey: KeyObject(key),
                    cost: surface.estimatedByteCost
                )
            }
        } else {
            cache.removeAllObjects()
            lock.withLock {
                keys.removeAll()
                costs.removeAll()
                pinned.removeAll()
            }
        }
    }

    func stats() -> RenderMemoryCacheStats {
        lock.withLock {
            RenderMemoryCacheStats(
                entryCount: keys.count,
                pinnedEntryCount: pinned.count,
                estimatedCost: costs.values.reduce(0, +),
                costLimit: costLimit
            )
        }
    }

    private func remove(_ key: RenderCacheKey) {
        cache.removeObject(forKey: KeyObject(key))
        lock.withLock {
            keys.remove(key)
            costs.removeValue(forKey: key)
            pinned.removeValue(forKey: key)
        }
    }

    func cache(_ cache: NSCache<AnyObject, AnyObject>, willEvictObject object: Any) {
        guard let entry = object as? EntryObject else { return }
        lock.withLock {
            keys.remove(entry.key)
            costs.removeValue(forKey: entry.key)
            if pinned[entry.key] == nil { pinned.removeValue(forKey: entry.key) }
        }
    }
}

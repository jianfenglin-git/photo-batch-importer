import Foundation
import Combine

/// Monotonic sequence counter used for `{seq}` in naming templates. Persists
/// to iCloud key-value store so the counter keeps climbing across the
/// user's devices — a burst on one Mac bumps the number, and the other
/// Mac starts from there on its next import.
@MainActor
final class SequenceStore: ObservableObject {
    @Published private(set) var lastSeq: UInt64

    private let cloud: CloudKVStore
    private let key = "sequence.lastSeq"
    private var cancellables: Set<AnyCancellable> = []

    init(cloud: CloudKVStore) {
        self.cloud = cloud
        self.lastSeq = UInt64(cloud.int(forKey: key) ?? 0)
        cloud.externalChanges
            .sink { [weak self] keys in
                guard let self = self, keys.contains(self.key) else { return }
                let newVal = UInt64(self.cloud.int(forKey: self.key) ?? 0)
                if newVal > self.lastSeq {
                    self.lastSeq = newVal
                }
            }
            .store(in: &cancellables)
    }

    func nextStart() -> UInt64 { lastSeq &+ 1 }

    /// Raise the watermark. Idempotent: a value ≤ current is a no-op.
    func commit(highestUsed: UInt64) {
        guard highestUsed > lastSeq else { return }
        lastSeq = highestUsed
        cloud.set(Int64(bitPattern: UInt64(highestUsed)), forKey: key)
    }

    /// User-driven override of "the number the next import will start at".
    /// Setting next = N means `lastSeq = N - 1`. Unlike `commit`, this can
    /// move the counter BACKWARDS — useful when a returning user wants to
    /// align their starting number with an existing photo library.
    func setNextStart(_ nextValue: UInt64) {
        let v = max(1, nextValue)
        let newLast = v - 1
        guard newLast != lastSeq else { return }
        lastSeq = newLast
        cloud.set(Int64(bitPattern: newLast), forKey: key)
    }
}

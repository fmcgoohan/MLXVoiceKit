import Foundation

@MainActor
public final class NativeModelIdleUnloader {
    public static let defaultDelay: Duration = .seconds(600)

    private let delay: Duration
    private var task: Task<Void, Never>?

    public init(delay: Duration = defaultDelay) {
        self.delay = delay
    }

    public func reconcile(
        keepLoaded: Bool,
        isIdle: Bool,
        isLoaded: Bool,
        unload: @escaping @MainActor @Sendable () -> Void
    ) {
        task?.cancel()
        task = nil
        guard !keepLoaded, isIdle, isLoaded else { return }

        task = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await Task.sleep(for: delay)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            task = nil
            unload()
        }
    }

    public func cancel() {
        task?.cancel()
        task = nil
    }
}

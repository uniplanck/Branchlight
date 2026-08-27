import BranchlightCore
import CoreFoundation
import Foundation

private let branchlightFinderRequestSignalCallback: CFNotificationCallback = { _, observer, _, _, _ in
    guard let observer else { return }
    let owner = Unmanaged<FinderRequestSignalObserver>.fromOpaque(observer).takeUnretainedValue()
    owner.receiveSignal()
}

final class FinderRequestSignalObserver: @unchecked Sendable {
    private let handler: @Sendable () -> Void

    init(handler: @escaping @Sendable () -> Void) {
        self.handler = handler
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            Unmanaged.passUnretained(self).toOpaque(),
            branchlightFinderRequestSignalCallback,
            SharedStatusNotifications.finderRequestChanged.rawValue,
            nil,
            .deliverImmediately
        )
    }

    deinit {
        CFNotificationCenterRemoveObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            Unmanaged.passUnretained(self).toOpaque(),
            SharedStatusNotifications.finderRequestChanged,
            nil
        )
    }

    fileprivate func receiveSignal() {
        handler()
    }
}

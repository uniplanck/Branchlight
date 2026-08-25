import AppKit
import BranchlightCore
import CoreFoundation
import FinderSync

private let branchlightCacheChangedCallback: CFNotificationCallback = { _, observer, _, _, _ in
    guard let observer else { return }
    let finderSync = Unmanaged<FinderSync>.fromOpaque(observer).takeUnretainedValue()
    finderSync.reloadMonitoredRoots()
}

final class FinderSync: FIFinderSync {
    private let controller = FIFinderSyncController.default()
    private let cache = SharedStatusCache()

    override init() {
        super.init()
        registerBadges()
        reloadMonitoredRoots()
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            Unmanaged.passUnretained(self).toOpaque(),
            branchlightCacheChangedCallback,
            SharedStatusNotifications.cacheChanged.rawValue,
            nil,
            .deliverImmediately
        )
    }

    deinit {
        CFNotificationCenterRemoveObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            Unmanaged.passUnretained(self).toOpaque(),
            SharedStatusNotifications.cacheChanged,
            nil
        )
    }

    override func requestBadgeIdentifier(for url: URL) {
        guard let envelope = cache?.load() else { return }
        let kind = envelope.statusKind(forAbsolutePath: url.standardizedFileURL.path)
        controller.setBadgeIdentifier(kind == .clean || kind == .ignored ? "" : kind.rawValue, for: url)
    }

    override func menu(for menuKind: FIMenuKind) -> NSMenu? {
        switch menuKind {
        case .contextualMenuForItems, .contextualMenuForContainer, .contextualMenuForSidebar, .toolbarItemMenu:
            break
        @unknown default:
            return nil
        }

        let urls = urlsForCurrentContext()
        let menu = NSMenu(title: "Branchlight")

        if !urls.isEmpty, let envelope = cache?.load() {
            let aggregate = GitStatusClassifier.aggregate(
                urls.map { envelope.statusKind(forAbsolutePath: $0.standardizedFileURL.path) }
            )
            let statusItem = NSMenuItem(
                title: "Status: \(aggregate.rawValue.capitalized)",
                action: nil,
                keyEquivalent: ""
            )
            statusItem.isEnabled = false
            menu.addItem(statusItem)
            menu.addItem(.separator())

            let changesItem = NSMenuItem(
                title: "Show Changes",
                action: #selector(showChanges(_:)),
                keyEquivalent: ""
            )
            changesItem.target = self
            menu.addItem(changesItem)

            if let context = selectionPlan(for: urls, envelope: envelope) {
                if context.canStage {
                    let stageItem = NSMenuItem(
                        title: "Stage Selected",
                        action: #selector(stageSelected(_:)),
                        keyEquivalent: ""
                    )
                    stageItem.target = self
                    menu.addItem(stageItem)
                }

                if context.canUnstage {
                    let unstageItem = NSMenuItem(
                        title: "Unstage Selected",
                        action: #selector(unstageSelected(_:)),
                        keyEquivalent: ""
                    )
                    unstageItem.target = self
                    menu.addItem(unstageItem)
                }
            }
        }

        let openItem = NSMenuItem(
            title: "Open Branchlight",
            action: #selector(openBranchlight(_:)),
            keyEquivalent: ""
        )
        openItem.target = self
        menu.addItem(openItem)
        return menu
    }

    override var toolbarItemName: String { "Branchlight" }

    override var toolbarItemToolTip: String { "Open Branchlight Git status" }

    override var toolbarItemImage: NSImage {
        NSImage(systemSymbolName: "point.3.connected.trianglepath.dotted", accessibilityDescription: "Branchlight")
            ?? NSImage(size: NSSize(width: 18, height: 18))
    }

    @objc private func showChanges(_ sender: Any?) {
        enqueueFinderIntent(.showChanges)
    }

    @objc private func stageSelected(_ sender: Any?) {
        enqueueFinderIntent(.stage)
    }

    @objc private func unstageSelected(_ sender: Any?) {
        enqueueFinderIntent(.unstage)
    }

    @objc private func openBranchlight(_ sender: Any?) {
        openContainingApp()
    }

    fileprivate func reloadMonitoredRoots() {
        let roots = cache?.load().monitoredRoots ?? []
        controller.directoryURLs = Set(
            roots.map { URL(fileURLWithPath: $0, isDirectory: true).standardizedFileURL }
        )
    }

    private func registerBadges() {
        registerBadge(.conflicted, symbol: "exclamationmark.triangle.fill", label: "Conflict")
        registerBadge(.modified, symbol: "pencil.circle.fill", label: "Modified")
        registerBadge(.staged, symbol: "checkmark.circle.fill", label: "Staged")
        registerBadge(.untracked, symbol: "questionmark.circle.fill", label: "Untracked")
        registerBadge(.added, symbol: "plus.circle.fill", label: "Added")
        registerBadge(.deleted, symbol: "minus.circle.fill", label: "Deleted")
        registerBadge(.renamed, symbol: "arrow.right.circle.fill", label: "Renamed")
    }

    private func registerBadge(_ kind: GitStatusKind, symbol: String, label: String) {
        guard let image = NSImage(systemSymbolName: symbol, accessibilityDescription: label) else { return }
        controller.setBadgeImage(image, label: label, forBadgeIdentifier: kind.rawValue)
    }

    private func urlsForCurrentContext() -> [URL] {
        if let selected = controller.selectedItemURLs(), !selected.isEmpty {
            return selected
        }
        if let targeted = controller.targetedURL() {
            return [targeted]
        }
        return []
    }

    private func selectionPlan(
        for urls: [URL],
        envelope: StatusCacheEnvelope
    ) -> FinderSelectionPlan? {
        FinderSelectionPlanner.plan(
            absolutePaths: urls.map { $0.standardizedFileURL.path },
            envelope: envelope
        )
    }

    private func enqueueFinderIntent(_ action: FinderIntentAction) {
        let urls = urlsForCurrentContext()
        guard let envelope = cache?.load(),
              let context = selectionPlan(for: urls, envelope: envelope) else {
            openContainingApp()
            return
        }

        do {
            try cache?.setPendingFinderIntent(
                FinderIntent(
                    action: action,
                    repositoryRoot: context.repositoryRoot,
                    paths: context.paths
                )
            )
        } catch {
            return
        }
        openContainingApp()
    }

    private func openContainingApp() {
        guard let appURL = containingAppURL() else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: appURL, configuration: configuration, completionHandler: nil)
    }

    private func containingAppURL() -> URL? {
        let extensionURL = Bundle.main.bundleURL
        let plugInsURL = extensionURL.deletingLastPathComponent()
        let contentsURL = plugInsURL.deletingLastPathComponent()
        let appURL = contentsURL.deletingLastPathComponent()
        return appURL.pathExtension == "app" ? appURL : nil
    }
}

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
    private let envelopeLock = NSLock()
    private var cachedEnvelope = StatusCacheEnvelope()

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
        let workspaceNotifications = NSWorkspace.shared.notificationCenter
        workspaceNotifications.addObserver(
            self,
            selector: #selector(workspaceDidResume(_:)),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )
        workspaceNotifications.addObserver(
            self,
            selector: #selector(workspaceDidResume(_:)),
            name: NSWorkspace.sessionDidBecomeActiveNotification,
            object: nil
        )
    }

    deinit {
        CFNotificationCenterRemoveObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            Unmanaged.passUnretained(self).toOpaque(),
            SharedStatusNotifications.cacheChanged,
            nil
        )
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    override func requestBadgeIdentifier(for url: URL) {
        let envelope = currentEnvelope()
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

        if !urls.isEmpty {
            let envelope = currentEnvelope()
            let aggregate = GitStatusClassifier.aggregate(
                urls.map { envelope.statusKind(forAbsolutePath: $0.standardizedFileURL.path) }
            )
            let context = selectionPlan(for: urls, envelope: envelope)

            addDisabledItem(title: "Status: \(aggregate.rawValue.capitalized)", to: menu)

            if let context,
               let intelligence = envelope.intelligence(forRepositoryRoot: context.repositoryRoot) {
                var branchTitle = intelligence.isDetachedHead
                    ? "HEAD: \(intelligence.branch)"
                    : "Branch: \(intelligence.branch)"
                if let tracking = intelligence.tracking {
                    branchTitle += "  \(tracking.summary)"
                }
                addDisabledItem(title: branchTitle, to: menu)

                if intelligence.operationMode != .normal {
                    var operationTitle = "Operation: \(displayName(for: intelligence.operationMode))"
                    if intelligence.conflictCount > 0 {
                        operationTitle += "  •  \(intelligence.conflictCount) conflict\(intelligence.conflictCount == 1 ? "" : "s")"
                    }
                    addDisabledItem(title: operationTitle, to: menu)
                }

                let counts = [
                    "Changed \(intelligence.changedCount)",
                    "Staged \(intelligence.stagedCount)",
                    "Untracked \(intelligence.untrackedCount)",
                    "Conflicts \(intelligence.conflictCount)"
                ].joined(separator: "  •  ")
                addDisabledItem(title: counts, to: menu)
            }

            menu.addItem(.separator())

            let changesItem = NSMenuItem(
                title: "Show Changes",
                action: #selector(showChanges(_:)),
                keyEquivalent: ""
            )
            changesItem.target = self
            menu.addItem(changesItem)

            if let context {
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

    @objc private func workspaceDidResume(_ notification: Notification) {
        reloadMonitoredRoots()
    }

    fileprivate func reloadMonitoredRoots() {
        let envelope = cache?.load() ?? StatusCacheEnvelope()
        replaceCachedEnvelope(envelope)
        controller.directoryURLs = Set(
            envelope.monitoredRoots.map { URL(fileURLWithPath: $0, isDirectory: true).standardizedFileURL }
        )
    }

    private func replaceCachedEnvelope(_ envelope: StatusCacheEnvelope) {
        envelopeLock.lock()
        cachedEnvelope = envelope
        envelopeLock.unlock()
    }

    private func currentEnvelope() -> StatusCacheEnvelope {
        envelopeLock.lock()
        defer { envelopeLock.unlock() }
        return cachedEnvelope
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

    private func addDisabledItem(title: String, to menu: NSMenu) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        menu.addItem(item)
    }

    private func displayName(for mode: GitRepositoryOperationMode) -> String {
        switch mode {
        case .normal: return "Normal"
        case .merging: return "Merge in progress"
        case .rebasing: return "Rebase in progress"
        case .cherryPicking: return "Cherry-pick in progress"
        case .reverting: return "Revert in progress"
        case .bisecting: return "Bisect in progress"
        }
    }

    private func enqueueFinderIntent(_ action: FinderIntentAction) {
        let urls = urlsForCurrentContext()
        let envelope = currentEnvelope()
        guard let context = selectionPlan(for: urls, envelope: envelope) else {
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

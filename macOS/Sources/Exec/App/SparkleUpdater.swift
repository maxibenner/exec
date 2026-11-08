import Combine
import Sparkle

/// Owns Sparkle for the app lifetime. Quiet probes never present an update dialog.
@MainActor
final class SparkleUpdater: NSObject, ObservableObject, SPUUpdaterDelegate {
    @Published private(set) var canCheckForUpdates = false
    let notice = UpdateNotice()
    private lazy var controller = SPUStandardUpdaterController(
        startingUpdater: false, updaterDelegate: self, userDriverDelegate: nil)

    override init() {
        super.init()
        controller.startUpdater()
        controller.updater.publisher(for: \.canCheckForUpdates)
            .assign(to: &$canCheckForUpdates)
    }

    func checkForUpdates() {
        guard canCheckForUpdates else { return }
        controller.checkForUpdates(nil)
    }

    func checkSilentlyIfNeeded() {
        guard notice.beginSilentCheck(canCheck: canCheckForUpdates && !controller.updater.sessionInProgress) else { return }
        controller.updater.checkForUpdateInformation()
    }

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        notice.foundUpdate(build: item.versionString)
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        notice.foundNoUpdate()
    }

    func updater(_ updater: SPUUpdater, userDidMake choice: SPUUserUpdateChoice,
                 forUpdate updateItem: SUAppcastItem, state: SPUUserUpdateState) {
        if choice == .skip {
            notice.foundUpdate(build: updateItem.versionString)
            notice.dismiss()
        }
    }
}

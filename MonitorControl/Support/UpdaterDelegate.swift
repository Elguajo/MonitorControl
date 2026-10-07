//  Copyright © MonitorControl. @JoniVR, @theOneyouseek, @waydabber and others

import Foundation
import Sparkle

class UpdaterDelegate: NSObject, SPUUpdaterDelegate {
  /// This fork is updated with local builds; official releases omit its custom features.
  func updater(_: SPUUpdater, mayPerform _: SPUUpdateCheck) throws {
    throw NSError(domain: "app.monitorcontrol.MonitorControl.ForkUpdates", code: 1, userInfo: [
      NSLocalizedDescriptionKey: NSLocalizedString("Updates are installed manually in this fork.", comment: "Fork update policy"),
    ])
  }
}

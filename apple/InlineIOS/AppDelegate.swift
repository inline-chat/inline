import Foundation
import Sentry
import UIKit

class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool
    {
        SentrySDK.start { options in
            // usenoor/inline-ios
            options.dsn = "https://1bd867ae25150dd18dad6100789649fd@o124360.ingest.us.sentry.io/4508058293633024"
            options.debug = false
        }

        return true
    }
}

import Flutter
import UIKit
import UserNotifications

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    // Must be set before launch finishes, or a notification tap that
    // cold-starts the app is never delivered.
    UNUserNotificationCenter.current().delegate = PushBridge.shared
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "FamilygramPush") {
      PushBridge.shared.attach(registrar)
    }
  }

  override func application(
    _ application: UIApplication,
    didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
  ) {
    PushBridge.shared.didRegister(deviceToken)
    super.application(application, didRegisterForRemoteNotificationsWithDeviceToken: deviceToken)
  }

  override func application(
    _ application: UIApplication,
    didFailToRegisterForRemoteNotificationsWithError error: Error
  ) {
    PushBridge.shared.didFail(error)
    super.application(application, didFailToRegisterForRemoteNotificationsWithError: error)
  }
}

/// Apple push for Familygram without Firebase: asks permission, hands the APNs
/// device token to Dart, reports notification taps and sets the icon badge.
/// Dart side: lib/data/push.dart (channel "familygram/push").
final class PushBridge: NSObject, UNUserNotificationCenterDelegate {
  static let shared = PushBridge()

  private var channel: FlutterMethodChannel?
  private var pendingRegister: FlutterResult?
  /// Chat of the last tapped notification, until Dart takes it. Kept here
  /// because a tap can arrive before Dart is listening (cold start).
  private var tappedChat: Int?

  func attach(_ registrar: FlutterPluginRegistrar) {
    let ch = FlutterMethodChannel(name: "familygram/push", binaryMessenger: registrar.messenger())
    ch.setMethodCallHandler { [weak self] call, result in self?.handle(call, result) }
    channel = ch
  }

  private func handle(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
    switch call.method {
    case "register":
      UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound]) { granted, _ in
        DispatchQueue.main.async {
          guard granted else {
            result(nil)
            return
          }
          self.pendingRegister?(nil)
          self.pendingRegister = result
          UIApplication.shared.registerForRemoteNotifications()
        }
      }
    case "takeTappedChat":
      result(tappedChat)
      tappedChat = nil
    case "setBadge":
      let n = (call.arguments as? Int) ?? 0
      if #available(iOS 16.0, *) {
        UNUserNotificationCenter.current().setBadgeCount(n)
      } else {
        UIApplication.shared.applicationIconBadgeNumber = n
      }
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  func didRegister(_ token: Data) {
    let hex = token.map { String(format: "%02x", $0) }.joined()
    pendingRegister?(["token": hex, "sandbox": PushBridge.isSandbox])
    pendingRegister = nil
  }

  func didFail(_ error: Error) {
    pendingRegister?(FlutterError(code: "register_failed", message: error.localizedDescription, details: nil))
    pendingRegister = nil
  }

  /// Development-signed builds get tokens from the APNs sandbox; App Store and
  /// TestFlight builds from production. The signing profile says which.
  static let isSandbox: Bool = {
    guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
          let data = try? Data(contentsOf: url),
          let text = String(data: data, encoding: .isoLatin1),
          let key = text.range(of: "<key>aps-environment</key>")
    else { return false }  // no profile: App Store build
    return text[key.upperBound...].prefix(100).contains("development")
  }()

  // The app is open: new messages already appear in it, no banner on top.
  func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    willPresent notification: UNNotification,
    withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
  ) {
    completionHandler([])
  }

  func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    didReceive response: UNNotificationResponse,
    withCompletionHandler completionHandler: @escaping () -> Void
  ) {
    if let id = (response.notification.request.content.userInfo["chat_id"] as? NSNumber)?.intValue {
      tappedChat = id
      channel?.invokeMethod("tapped", arguments: nil)
    }
    completionHandler()
  }
}

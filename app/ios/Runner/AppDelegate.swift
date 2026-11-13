import Flutter
import PushKit
import UIKit
import UserNotifications
import flutter_callkit_incoming

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate, PKPushRegistryDelegate {
  private var voipRegistry: PKPushRegistry?
  /// Tiny engine that hosts the CallKit plugin when a VoIP push arrives
  /// before the app's UI (and its Flutter engine) has started.
  private var callkitHost: FlutterEngine?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    // Must be set before launch finishes, or a notification tap that
    // cold-starts the app is never delivered.
    UNUserNotificationCenter.current().delegate = PushBridge.shared
    // Incoming calls: PushKit wakes (or launches) the app for every call.
    let registry = PKPushRegistry(queue: .main)
    registry.delegate = self
    registry.desiredPushTypes = [.voIP]
    voipRegistry = registry
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  // ---- incoming calls: PushKit → CallKit ----

  /// The CallKit plugin. iOS kills an app (and soon stops waking it) if it
  /// does not show a VoIP push as a call right away, so when the push came
  /// before the UI started, host the plugin in a minimal engine first.
  private func callkit() -> SwiftFlutterCallkitIncomingPlugin {
    if SwiftFlutterCallkitIncomingPlugin.sharedInstance == nil {
      let engine = FlutterEngine(name: "callkit-host", project: nil, allowHeadlessExecution: true)
      // Runs an empty Dart function, not the app (see callkitHostMain).
      engine.run(withEntrypoint: "callkitHostMain")
      if let registrar = engine.registrar(forPlugin: "FlutterCallkitIncomingPlugin") {
        SwiftFlutterCallkitIncomingPlugin.register(with: registrar)
      }
      callkitHost = engine
    }
    return SwiftFlutterCallkitIncomingPlugin.sharedInstance
  }

  func pushRegistry(_ registry: PKPushRegistry, didUpdate credentials: PKPushCredentials, for type: PKPushType) {
    guard type == .voIP else { return }
    let token = credentials.token.map { String(format: "%02x", $0) }.joined()
    callkit().setDevicePushTokenVoIP(token)
  }

  func pushRegistry(_ registry: PKPushRegistry, didInvalidatePushTokenFor type: PKPushType) {
    guard type == .voIP else { return }
    callkit().setDevicePushTokenVoIP("")
  }

  func pushRegistry(
    _ registry: PKPushRegistry,
    didReceiveIncomingPushWith payload: PKPushPayload,
    for type: PKPushType,
    completion: @escaping () -> Void
  ) {
    guard type == .voIP else {
      completion()
      return
    }
    // Payload from the server's CallPush (server/push.go).
    let p = payload.dictionaryPayload
    let video = p["video"] as? Bool ?? false
    let call = flutter_callkit_incoming.Data(
      id: p["uuid"] as? String ?? UUID().uuidString,
      nameCaller: p["title"] as? String ?? "Familygram",
      handle: "",
      type: video ? 1 : 0)
    call.appName = "Familygram"
    call.supportsVideo = true
    call.duration = 45000  // the server stops ringing after 45 s
    call.extra = ["call_id": p["call_id"] ?? 0, "chat_id": p["chat_id"] ?? 0, "video": video]
    callkit().showCallkitIncoming(call, fromPushKit: true) { completion() }
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "FamilygramPush") {
      PushBridge.shared.attach(registrar)
    }
  }

  override func application(
    _ application: UIApplication,
    didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Foundation.Data
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

  func didRegister(_ token: Foundation.Data) {
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
          let data = try? Foundation.Data(contentsOf: url),
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

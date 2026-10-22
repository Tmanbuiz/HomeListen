import Flutter
import UIKit
import UserNotifications

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private var recordingChannel: FlutterMethodChannel?
  private var exportingRecording = false

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    UNUserNotificationCenter.current().delegate = self
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    let channel = FlutterMethodChannel(
      name: "com.wiantribe.home_listen/mic_service",
      binaryMessenger: engineBridge.applicationRegistrar.messenger()
    )
    recordingChannel = channel
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self = self else {
        result(FlutterError(code: "recordings_unavailable", message: "Open Home Listen again.", details: nil))
        return
      }
      switch call.method {
      case "recordingsDirectory":
        do {
          result(try self.recordingsDirectory().path)
        } catch {
          result(FlutterError(code: "recordings_unavailable", message: "Could not open private recordings storage.", details: nil))
        }
      case "exportRecording":
        self.exportRecording(call.arguments, result: result)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  /// App-private clips survive relaunch but never enter iCloud backups.
  private func recordingsDirectory() throws -> URL {
    let manager = FileManager.default
    let support = try manager.url(
      for: .applicationSupportDirectory, in: .userDomainMask,
      appropriateFor: nil, create: true
    )
    var directory = support.appendingPathComponent("alert-recordings", isDirectory: true)
    try manager.createDirectory(at: directory, withIntermediateDirectories: true)
    var values = URLResourceValues()
    values.isExcludedFromBackup = true
    try directory.setResourceValues(values)
    // Permit an ongoing, user-started receiving session to finish a clip while locked.
    try manager.setAttributes(
      [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
      ofItemAtPath: directory.path
    )
    return directory.resolvingSymlinksInPath().standardizedFileURL
  }

  private func recordingFile(_ arguments: Any?) throws -> URL? {
    guard let arguments = arguments as? [String: Any],
          let path = arguments["path"] as? String, path.count <= 4096,
          let name = arguments["name"] as? String, name.count <= 240,
          name.hasSuffix(".wav"), !name.contains("/"), !name.contains("\\") else {
      return nil
    }
    let url = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL
    let directory = try recordingsDirectory()
    guard url.deletingLastPathComponent().path == directory.path,
          url.lastPathComponent == name else { return nil }
    let values = try url.resourceValues(forKeys: [.isRegularFileKey])
    return values.isRegularFile == true ? url : nil
  }

  private func activeController() -> UIViewController? {
    let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
    let root = scenes.filter { $0.activationState == .foregroundActive }
      .flatMap { $0.windows }.first { $0.isKeyWindow }?.rootViewController
    var current = root
    while let presented = current?.presentedViewController {
      current = presented
    }
    return current
  }

  private func exportRecording(_ arguments: Any?, result: @escaping FlutterResult) {
    do {
      guard !exportingRecording, let url = try recordingFile(arguments),
            let controller = activeController(), controller.viewIfLoaded?.window != nil else {
        result(FlutterError(code: "export_unavailable", message: "Open Home Listen and select an existing recording.", details: nil))
        return
      }
      exportingRecording = true
      let sheet = UIActivityViewController(activityItems: [url], applicationActivities: nil)
      sheet.completionWithItemsHandler = { [weak self] _, completed, _, error in
        self?.exportingRecording = false
        if error != nil {
          result(FlutterError(code: "export_failed", message: "Could not export the recording.", details: nil))
        } else {
          result(completed)
        }
      }
      if let popover = sheet.popoverPresentationController {
        popover.sourceView = controller.view
        popover.sourceRect = CGRect(
          x: controller.view.bounds.midX, y: controller.view.bounds.midY,
          width: 1, height: 1
        )
        popover.permittedArrowDirections = []
      }
      controller.present(sheet, animated: true)
    } catch {
      result(FlutterError(code: "export_failed", message: "The recording is no longer available.", details: nil))
    }
  }
}

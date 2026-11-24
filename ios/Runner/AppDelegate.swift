import Flutter
import onnxruntime_objc
import UIKit
import UserNotifications

@main
@objc class AppDelegate: FlutterAppDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    GeneratedPluginRegistrant.register(with: self)
    if let registrar = self.registrar(forPlugin: "BeeCountDocumentFlatten") {
      registerDocumentFlatten(with: registrar)
    }

    // 注册AppIntents桥接插件
    if #available(iOS 13.0, *) {
      let controller = window?.rootViewController as! FlutterViewController
      let registrar = self.registrar(forPlugin: "AppIntentsBridge")
      if let registrar = registrar {
        AppIntentsBridge.register(with: registrar)
      }
    }

    // 设置通知中心代理
    if #available(iOS 10.0, *) {
      UNUserNotificationCenter.current().delegate = self
    }

    // 设置日志插件
    let controller = window?.rootViewController as! FlutterViewController
    let loggerChannel = FlutterMethodChannel(
      name: "com.beecount.logger",
      binaryMessenger: controller.binaryMessenger
    )
    LoggerPlugin.setup(channel: loggerChannel)

    // 监听 iCloud 日志（从插件模块发送）
    NotificationCenter.default.addObserver(
      forName: NSNotification.Name("ICloudLog"),
      object: nil,
      queue: .main
    ) { notification in
      if let message = notification.userInfo?["message"] as? String {
        LoggerPlugin.info(tag: "iCloud", message: message)
      }
    }

    // 测试日志
    LoggerPlugin.info(tag: "AppDelegate", message: "日志系统已初始化")

    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  override func applicationDidBecomeActive(_ application: UIApplication) {
    super.applicationDidBecomeActive(application)
    clearNotificationBadge()
  }

  private func clearNotificationBadge() {
    if #available(iOS 16.0, *) {
      UNUserNotificationCenter.current().setBadgeCount(0) { error in
        if let error = error {
          LoggerPlugin.info(tag: "AppDelegate", message: "清除通知角标失败: \(error.localizedDescription)")
        }
      }
    } else {
      UIApplication.shared.applicationIconBadgeNumber = 0
    }
  }

  // 前台显示通知
  @available(iOS 10.0, *)
  override func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    willPresent notification: UNNotification,
    withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
  ) {
    // 前台保留横幅和声音，避免正在使用 App 时重新留下未读角标。
    if #available(iOS 14.0, *) {
      completionHandler([.banner, .sound])
    } else {
      completionHandler([.alert, .sound])
    }
  }

  // 处理通知点击
  @available(iOS 10.0, *)
  override func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    didReceive response: UNNotificationResponse,
    withCompletionHandler completionHandler: @escaping () -> Void
  ) {
    clearNotificationBadge()
    completionHandler()
  }
}

private func registerDocumentFlatten(with registrar: FlutterPluginRegistrar) {
  let queue = DispatchQueue(label: "com.tntlikely.beecount.document_flatten")
  let channel = FlutterMethodChannel(
    name: "com.tntlikely.beecount/document_flatten",
    binaryMessenger: registrar.messenger()
  )
  let assetKey = registrar.lookupKey(forAsset: "assets/models/uvdoc.onnx")
  let model = Bundle.main.path(forResource: assetKey, ofType: nil)
  channel.setMethodCallHandler { call, result in
    guard call.method == "flatten" else {
      result(FlutterMethodNotImplemented)
      return
    }
    guard let args = call.arguments as? [String: Any],
          let width = args["width"] as? Int,
          let height = args["height"] as? Int,
          (64...1920).contains(width), (64...1920).contains(height),
          let pixels = args["pixels"] as? FlutterStandardTypedData,
          pixels.data.count == width * height * 3 * MemoryLayout<Float>.size,
          let model = model else {
      result(FlutterError(code: "INVALID_IMAGE", message: "Invalid UVDoc input", details: nil))
      return
    }
    queue.async {
      let response: Any = autoreleasepool {
        do {
          let env = try ORTEnv(loggingLevel: .warning)
          let options = try ORTSessionOptions()
          try options.setIntraOpNumThreads(2)
          let session = try ORTSession(env: env, modelPath: model, sessionOptions: options)
          let shape = [1, 3, height, width].map { NSNumber(value: $0) }
          let input = try ORTValue(
            tensorData: NSMutableData(data: pixels.data), elementType: .float, shape: shape
          )
          let outputs = try session.run(
            withInputs: ["image": input], outputNames: ["fetch_name_0"], runOptions: nil
          )
          guard let output = outputs["fetch_name_0"],
                try output.tensorTypeAndShapeInfo().shape == shape else {
            return FlutterError(code: "FLATTEN_FAILED", message: "Unexpected UVDoc output", details: nil)
          }
          // Copy the tensor bytes before the ORTValue owning them is released.
          let data = try output.tensorData()
          let copy = Data(bytes: data.bytes, count: data.length)
          return FlutterStandardTypedData(float32: copy)
        } catch {
          return FlutterError(code: "FLATTEN_FAILED", message: "UVDoc inference failed", details: nil)
        }
      }
      DispatchQueue.main.async { result(response) }
    }
  }
}

import Orion
import RevengeTweakC
import os

let revengeLog = OSLog(subsystem: Bundle.main.bundleIdentifier!, category: "revenge")
let source = URL(string: "revenge")!

let install_prefix = String(cString: get_install_prefix())
let isJailbroken = FileManager.default.fileExists(atPath: "\(install_prefix)/Library/Application Support/RevengeTweak/RevengePatches.bundle")

let revengePatchesBundlePath = isJailbroken ? "\(install_prefix)/Library/Application Support/RevengeTweak/RevengePatches.bundle" : "\(Bundle.main.bundleURL.path)/RevengePatches.bundle"

class FileManagerLoadHook: ClassHook<FileManager> {
  func containerURLForSecurityApplicationGroupIdentifier(_ groupIdentifier: NSString?) -> URL? {
    os_log("containerURLForSecurityApplicationGroupIdentifier called! %{public}@ groupIdentifier", log: revengeLog, type: .debug, groupIdentifier ?? "nil")

    if (isJailbroken) {
      return orig.containerURLForSecurityApplicationGroupIdentifier(groupIdentifier)
    }

    let paths = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)
    let lastPath = paths.last!
    return lastPath.appendingPathComponent("AppGroup")
  }
}

class LoadHook: ClassHook<RCTCxxBridge> {
  func executeApplicationScript(_ script: Data, url: URL, async: Bool) {
    os_log("executeApplicationScript called!", log: revengeLog, type: .debug)

    let loaderConfig = getLoaderConfig()

    let revengePatchesBundle = Bundle(path: revengePatchesBundlePath)!
    var patches = ["modules", "identity"]
    if loaderConfig.loadReactDevTools {
      os_log("DevTools patch enabled", log: revengeLog, type: .info)
      patches.append("devtools")
    }

    os_log("Executing patches", log: revengeLog, type: .info)
    for patch in patches {
      if let patchPath = revengePatchesBundle.url(forResource: patch, withExtension: "js") {
        let patchData = try! Data(contentsOf: patchPath)
        os_log("Executing %{public}@ patch", log: revengeLog, type: .debug, patch)
        orig.executeApplicationScript(patchData, url: source, async: true)
      }
    }

    let documentDirectory = getDocumentDirectory()

    var revenge = try? Data(contentsOf: documentDirectory.appendingPathComponent("revenge.js"))

    let group = DispatchGroup()

    group.enter()
    var revengeUrl: URL
    if loaderConfig.customLoadUrl.enabled {
      os_log(
        "Custom load URL enabled, with URL %{public}@ ", log: revengeLog, type: .info,
        loaderConfig.customLoadUrl.url.absoluteString)
      revengeUrl = loaderConfig.customLoadUrl.url
    } else {
      revengeUrl = URL(
        string: "https://raw.githubusercontent.com/revenge-mod/builds/main/revenge.js")!
    }

    os_log("Fetching revenge.js", log: revengeLog, type: .info)
    var revengeRequest = URLRequest(
      url: revengeUrl, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 3.0)

    if let revengeEtag = try? String(
      contentsOf: documentDirectory.appendingPathComponent("revenge_etag.txt")), revenge != nil
    {
      revengeRequest.addValue(revengeEtag, forHTTPHeaderField: "If-None-Match")
    }

    let revengeTask = URLSession.shared.dataTask(with: revengeRequest) { data, response, error in
      if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 {
        os_log("Successfully fetched revenge.js", log: revengeLog, type: .debug)
        revenge = data
        try? revenge?.write(to: documentDirectory.appendingPathComponent("revenge.js"))

        let etag = httpResponse.allHeaderFields["Etag"] as? String
        try? etag?.write(
          to: documentDirectory.appendingPathComponent("revenge_etag.txt"), atomically: true,
          encoding: .utf8)
      }

      group.leave()
    }

    revengeTask.resume()
    group.wait()

    os_log("Executing original script", log: revengeLog, type: .info)
    orig.executeApplicationScript(script, url: url, async: async)

    if let themeString = try? String(
      contentsOf: documentDirectory.appendingPathComponent("revenge_theme.json"))
    {
      orig.executeApplicationScript(
        "globalThis.__revenge_theme=\(themeString)".data(using: .utf8)!, url: source, async: async)
    }

    if revenge != nil {
      os_log("Executing revenge.js", log: revengeLog, type: .info)
      orig.executeApplicationScript(revenge!, url: source, async: async)
    } else {
      os_log("Unable to fetch revenge.js", log: revengeLog, type: .error)
    }
  }
}

struct RevengeTweak: Tweak {
    func tweakDidActivate() {
      if let themeData = try? Data(
      contentsOf: documentDirectory.appendingPathComponent("revenge_theme.json")) {
        let theme = try? JSONDecoder().decode(Theme.self, from: themeData)
        if let semanticColors = theme?.data.semanticColors { swizzleDCDThemeColor(semanticColors) }
        if let rawColors = theme?.data.rawColors { swizzleUIColor(rawColors) }
      }
    }
}

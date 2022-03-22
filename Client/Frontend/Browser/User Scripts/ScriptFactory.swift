// Copyright 2022 The Brave Authors. All rights reserved.
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/.

import Foundation
import WebKit
import GameplayKit

/// An error representing failures in loading scripts
enum ScriptLoadFailure: Error {
  case notFound
}

/// An enum representing the unmodified local scripts stored in the application.
///
/// - Warning: Some of these scripts are not usable "as-is". Rather, you should be using `UserScriptType`.
enum ScriptSourceType {
  /// A simple encryption library found here:
  /// https://www.npmjs.com/package/tweetnacl
  case nacl
  
  /// This script farbles certian system methods to output slightly randomized output.
  /// This script has a dependency on `nacl`.
  ///
  /// This script has the following dynamic variables:
  /// - `$<fudge_factor>`: A random value between 0.99 and 1
  case farblingProtection
  
  /// A YouTube ad blocking script
  case youtubeAdBlock
  case archive
  case braveSearchHelper
  case braveTalkHelper
  
  fileprivate var fileName: String {
    switch self {
    case .nacl: return "nacl.min"
    case .farblingProtection: return "FarblingProtection"
    case .youtubeAdBlock: return "YoutubeAdblock"
    case .archive: return "ArchiveIsCompat"
    case .braveSearchHelper: return "BraveSearchHelper"
    case .braveTalkHelper: return "BraveTalkHelper"
    }
  }
  
  fileprivate func loadScript() throws -> String {
    guard let path = Bundle.main.path(forResource: fileName, ofType: "js") else {
      assertionFailure("Cannot load script. This should not happen as it's part of the codebase")
      throw ScriptLoadFailure.notFound
    }
    
    return try String(contentsOfFile: path)
  }
}

/// An enum representing a specific (modified) variation of a local script replacing any dynamic variables.
enum UserScriptType: Hashable {
  /// This type does farbling protection and is customized for the provided eTLD+1
  /// Has a dependency on `nacl`
  case farblingProtection(etld: String)
  /// Scripts specific to certain domains
  case domainUserScript(DomainUserScript)
  /// A symple encryption library to be used by other scripts
  case nacl
  
  /// Return a source typ for this script type
  var sourceType: ScriptSourceType {
    switch self {
    case .farblingProtection:
      return .farblingProtection
    case .domainUserScript(let domainUserScript):
      switch domainUserScript {
      case .youtubeAdBlock:
        return .youtubeAdBlock
      case .archive:
        return .archive
      case .braveSearchHelper:
        return .braveSearchHelper
      case .braveTalkHelper:
        return .braveTalkHelper
      }
    case .nacl:
      return .nacl
    }
  }
  
  /// The order in which we want to inject the scripts
  var order: Int {
    switch self {
    case .nacl: return 0
    case .farblingProtection: return 1
    case .domainUserScript: return 2
    }
  }
  
  var injectionTime: WKUserScriptInjectionTime {
    switch self {
    case .farblingProtection, .domainUserScript, .nacl:
      return .atDocumentStart
    }
  }
  
  var forMainFrameOnly: Bool {
    switch self {
    case .farblingProtection, .domainUserScript, .nacl:
      return false
    }
  }
  
  var contentWorld: WKContentWorld {
    switch self {
    case .farblingProtection, .domainUserScript:
      return .page
    case .nacl:
      return .page
    }
  }
}

/// A class that helps in the aid of creating and caching scripts.
class ScriptFactory {
  /// A shared instance to be shared throughout the app.
  ///
  /// - Note: Perhaps we will move this to the tab to be managed on a tab basis.
  static let shared = ScriptFactory()
  
  /// Ensures that the message handlers cannot be invoked by the page scripts
  public static let messageHandlerTokenString: String = {
    return UUID().uuidString.replacingOccurrences(of: "-", with: "", options: .literal)
  }()
  
  /// This contains cahced script sources for a script type. Avoids reading from disk.
  private var cachedScriptSources: [ScriptSourceType: String]
  
  /// This contains cached altered scripts that are ready to be inected. Avoids replacing strings.
  private var cachedDomainScriptsSources: [UserScriptType: WKUserScript]
  
  init() {
    cachedScriptSources = [:]
    cachedDomainScriptsSources = [:]
  }
  
  /// Clear some caches in case we need to.
  ///
  /// Should only really be called in a memory warning scenario.
  func clearCaches() {
    cachedScriptSources = [:]
    cachedDomainScriptsSources = [:]
  }
  
  /// Returns a script source by loading a file or returning cached data
  private func makeScriptSource(of type: ScriptSourceType) throws -> String {
    if let source = cachedScriptSources[type] {
      return source
    } else {
      let source = try type.loadScript()
      cachedScriptSources[type] = source
      return source
    }
  }
  
  /// Get a script for the `UserScriptType`.
  ///
  /// Scripts can be cached on two levels:
  /// - On the unmodified source file (per `ScriptSourceType`)
  /// - On the modfied source file (per `UserScriptType`)
  func makeScript(for domainType: UserScriptType) throws -> WKUserScript {
    var source = try makeScriptSource(of: domainType.sourceType)

    // First check for and return cached value
    if let script = cachedDomainScriptsSources[domainType] {
      return script
    }
    
    switch domainType {
    case .farblingProtection(let etld):
      let randomManager = RandomManager(etld: etld)
      let seed = randomManager.seed

      // From the seed, let's generate a fudge factor between 0.99 and 1
      // `GKMersenneTwisterRandomSource` gives us a value between 0.0 and 1.0,
      // so we convert it to a value between 0.99 and 1.
      // It's important that this value is between 0.99 and 1 (especially less than 1)
      // As we are multiplying it by values betwen -1 and 1 and if the value is too small
      // It will manipulate the values too much and make it noticible to the user and if
      // it is greater than 1 it has the potential to be out of the appropriate range giving us JS errors.
      let randomSource = GKMersenneTwisterRandomSource(seed: seed)
      let fudgeFactor = 0.99 + (randomSource.nextUniform() / 100)
      let fakePluginData = FarblingProtectionHelper.makeFakePluginData(from: randomManager)

      print("[ScriptFactory] eTLD+1: \(etld)")
      print("[ScriptFactory] String: \(fakePluginData)")
      print("[ScriptFactory] Seed:   \(seed)")
      print("[ScriptFactory] Fudge:  \(fudgeFactor)")
      
      source = source
        .replacingOccurrences(of: "$<fudge_factor>", with: "\(fudgeFactor)", options: .literal)
        .replacingOccurrences(of: "$<fake_plugin_data>", with: "\(fakePluginData)", options: .literal)
      
    case .nacl:
      // No modifications needed
      break
      
    case .domainUserScript(let domainUserScript):
      switch domainUserScript {
      case .youtubeAdBlock:
        // Verify that the application itself is making a call to the JS script instead of other scripts on the page.
        // This variable will be unique amongst scripts loaded in the page.
        // When the script is called, the token is provided in order to access the script variable.
        let securityToken = UserScriptManager.securityTokenString
        
        source = source
          .replacingOccurrences(of: "$<prunePaths>", with: "ABSPP\(securityToken)", options: .literal)
          .replacingOccurrences(of: "$<findOwner>", with: "ABSFO\(securityToken)", options: .literal)
          .replacingOccurrences(of: "$<setJS>", with: "ABSSJ\(securityToken)", options: .literal)
        
      case .archive:
        // No modifications needed
        break
        
      case .braveSearchHelper:
        let securityToken = UserScriptManager.securityTokenString
        let messageToken = "BSH\(UserScriptManager.messageHandlerTokenString)"
        
        source = source
          .replacingOccurrences(of: "$<brave-search-helper>", with: messageToken, options: .literal)
          .replacingOccurrences(of: "$<security_token>", with: securityToken)
        
      case .braveTalkHelper:
        let securityToken = UserScriptManager.securityTokenString
        let messageToken = "BT\(UserScriptManager.messageHandlerTokenString)"
        
        source = source
          .replacingOccurrences(of: "$<brave-talk-helper>", with: messageToken, options: .literal)
          .replacingOccurrences(of: "$<security_token>", with: securityToken)
      }
    }
    
    let userScript = WKUserScript.create(source: source, injectionTime: domainType.injectionTime, forMainFrameOnly: domainType.forMainFrameOnly, in: domainType.contentWorld)
    cachedDomainScriptsSources[domainType] = userScript
    return userScript
  }
}

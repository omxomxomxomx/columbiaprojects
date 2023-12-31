//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift open source project
//
// Copyright (c) 2022-2023 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See https://swift.org/LICENSE.txt for license information
// See https://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

import AsyncAlgorithms
import AsyncHTTPClient
import Foundation
import GeneratorEngine
import RegexBuilder
import ServiceLifecycle
import SystemPackage

public extension Triple.CPU {
  /// Returns the value of `cpu` converted to a convention used in Debian package names
  var debianConventionName: String {
    switch self {
    case .arm64: "arm64"
    case .x86_64: "amd64"
    }
  }
}

private func withHTTPClient(
  _ configuration: HTTPClient.Configuration,
  _ body: @Sendable (HTTPClient) async throws -> ()
) async throws {
  let client = HTTPClient(eventLoopGroupProvider: .singleton, configuration: configuration)
  do {
    try await body(client)
    try await client.shutdown()
  } catch {
    try await client.shutdown()
    throw error
  }
}

extension SwiftSDKGenerator: Service {
  public func run() async throws {
    try await withEngine(LocalFileSystem(), self.logger, cacheLocation: self.engineCachePath) { engine in
      var configuration = HTTPClient.Configuration(redirectConfiguration: .follow(max: 5, allowCycles: false))
      // Workaround an issue with github.com returning 400 instead of 404 status to HEAD requests from AHC.
      configuration.httpVersion = .http1Only
      try await withHTTPClient(configuration) { client in
        if !self.isIncremental {
          try await self.removeRecursively(at: pathsConfiguration.sdkDirPath)
          try await self.removeRecursively(at: pathsConfiguration.toolchainDirPath)
        }

        try await self.createDirectoryIfNeeded(at: pathsConfiguration.artifactsCachePath)
        try await self.createDirectoryIfNeeded(at: pathsConfiguration.sdkDirPath)
        try await self.createDirectoryIfNeeded(at: pathsConfiguration.toolchainDirPath)

        try await self.downloadArtifacts(client, engine)

        if !shouldUseDocker {
          guard case let .ubuntu(version) = versionsConfiguration.linuxDistribution else {
            throw GeneratorError
              .distributionSupportsOnlyDockerGenerator(versionsConfiguration.linuxDistribution)
          }

          try await self.downloadUbuntuPackages(client, engine, requiredPackages: version.requiredPackages)
        }

        try await self.unpackHostSwift()

        if shouldUseDocker {
          try await self.copyTargetSwiftFromDocker()
        } else {
          try await self.unpackTargetSwiftPackage()
        }

        try await self.prepareLLDLinker(engine)

        try await self.fixAbsoluteSymlinks()

        let targetCPU = self.targetTriple.cpu
        try await self.fixGlibcModuleMap(
          at: pathsConfiguration.toolchainDirPath
            .appending("/usr/lib/swift/linux/\(targetCPU.linuxConventionName)/glibc.modulemap")
        )

        try await self.symlinkClangHeaders()

        let autolinkExtractPath = pathsConfiguration.toolchainBinDirPath.appending("swift-autolink-extract")

        if await !self.doesFileExist(at: autolinkExtractPath) {
          logGenerationStep("Fixing `swift-autolink-extract` symlink...")
          try await createSymlink(at: autolinkExtractPath, pointingTo: "swift")
        }

        let toolsetJSONPath = try await generateToolsetJSON()

        try await generateDestinationJSON(toolsetPath: toolsetJSONPath)

        try await generateArtifactBundleManifest()

        logGenerationStep(
          """
          All done! Install the newly generated SDK with this command:
          swift experimental-sdk install \(pathsConfiguration.artifactBundlePath)

          After that, use the newly installed SDK when building with this command:
          swift build --experimental-swift-sdk \(artifactID)
          """
        )
      }
    }
  }
}

func logGenerationStep(_ message: String) {
  print("\n\(message)")
}

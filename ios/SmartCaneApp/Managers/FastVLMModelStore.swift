import Foundation
#if canImport(Hub)
import Hub
#endif
#if canImport(MLXLMCommon)
import MLXLMCommon
#endif

@MainActor
final class FastVLMModelStore: ObservableObject {
    enum State: Equatable {
        case checking
        case missing
        case downloading(progress: Double)
        case installing
        case ready(URL)
        case failed(String)
    }

    static let remoteModelID = "mlx-community/FastVLM-0.5B-bf16"
    static let remoteModelRevision = "main"
    static let requiredFiles = [
        "config.json",
        "tokenizer.json",
        "tokenizer_config.json",
        "processor_config.json",
        "model.safetensors",
    ]
    static let downloadGlobs = [
        "*.json",
        "*.jinja",
        "*.safetensors",
        "merges.txt",
        "vocab.json",
        "tokenizer.model",
    ]

    @Published private(set) var state: State = .checking
    @Published private(set) var downloadProgress: Double = 0
    @Published private(set) var downloadDetail = ""
    private var downloadTask: Task<Void, Never>?

    init() {
        refresh()
        Task {
            await validateInstalledModelIfNeeded()
        }
    }

    var isModelReady: Bool {
        if case .ready = state {
            return true
        }
        return false
    }

    var statusMessage: String {
        switch state {
        case .checking:
            return "Checking for the installed FastVLM model."
        case .missing:
            return "FastVLM is required. Preparing automatic download."
        case .downloading(let progress):
            let percent = Int((progress * 100).rounded())
            return "Downloading FastVLM model: \(percent)%."
        case .installing:
            return "Importing FastVLM model files into app storage."
        case .ready(let url):
            return "FastVLM model ready at \(url.lastPathComponent)."
        case .failed(let message):
            return message
        }
    }

    var canRetryDownload: Bool {
        if case .failed = state {
            return true
        }
        return false
    }

    static func installedModelDirectoryURL() throws -> URL {
        let root = try fastVLMRootDirectoryURL()
        return root.appendingPathComponent("model", isDirectory: true)
    }

    static func fastVLMRootDirectoryURL() throws -> URL {
        let applicationSupport = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let root = applicationSupport.appendingPathComponent("FastVLM", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    static func existingInstalledModelDirectory() -> URL? {
        guard let url = try? installedModelDirectoryURL() else {
            return nil
        }

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              isDirectory.boolValue,
              validateModelDirectory(url) == nil else {
            return nil
        }
        try? ensureChatTemplateFiles(in: url)
        return url
    }

    static func validateModelDirectory(_ directory: URL) -> String? {
        for file in requiredFiles {
            let fileURL = directory.appendingPathComponent(file, isDirectory: false)
            guard FileManager.default.fileExists(atPath: fileURL.path) else {
                return "Missing required file \(file)."
            }
        }
        return nil
    }

    static func ensureChatTemplateFiles(in directory: URL) throws {
        let fileManager = FileManager.default
        let tokenizerConfigURL = directory.appendingPathComponent("tokenizer_config.json", isDirectory: false)
        let jinjaURL = directory.appendingPathComponent("chat_template.jinja", isDirectory: false)
        let existingJinjaTemplate: String? =
            fileManager.fileExists(atPath: jinjaURL.path)
            ? try? String(contentsOf: jinjaURL, encoding: .utf8)
            : nil

        var tokenizerConfigObject: [String: Any] = [:]
        if fileManager.fileExists(atPath: tokenizerConfigURL.path) {
            let configData = try Data(contentsOf: tokenizerConfigURL)
            tokenizerConfigObject =
                (try JSONSerialization.jsonObject(with: configData) as? [String: Any]) ?? [:]
        }

        let configTemplate =
            (tokenizerConfigObject["chat_template"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let jinjaTemplate = existingJinjaTemplate?.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedTemplate = [configTemplate, jinjaTemplate].compactMap { value -> String? in
            guard let value, !value.isEmpty else {
                return nil
            }
            return value
        }.first

        guard let resolvedTemplate else {
            return
        }

        if existingJinjaTemplate?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
            try resolvedTemplate.write(
                to: jinjaURL,
                atomically: true,
                encoding: String.Encoding.utf8
            )
        }

        if tokenizerConfigObject["chat_template"] == nil {
            tokenizerConfigObject["chat_template"] = resolvedTemplate
            let updatedData = try JSONSerialization.data(
                withJSONObject: tokenizerConfigObject,
                options: [.prettyPrinted, .sortedKeys]
            )
            try updatedData.write(to: tokenizerConfigURL, options: .atomic)
        }
    }

    static func ensureTokenizerMetadataIsUsable(in directory: URL) async throws {
        try ensureChatTemplateFiles(in: directory)
#if canImport(Hub) && canImport(MLXLMCommon)
        let configuration = ModelConfiguration(directory: directory)
        let hub = HubApi()
        let (tokenizerConfig, _) = try await loadTokenizerConfig(configuration: configuration, hub: hub)
        guard !tokenizerConfig.chatTemplate.isNull() else {
            throw NSError(
                domain: "SmartCane.FastVLMModelStore",
                code: 4,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "Installed FastVLM tokenizer is missing a usable chat template."
                ]
            )
        }
#endif
    }

    static func removeInstalledModelDirectory() throws {
        let directory = try installedModelDirectoryURL()
        if FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.removeItem(at: directory)
        }
    }

    func refresh() {
        if let directory = Self.existingInstalledModelDirectory() {
            state = .ready(directory)
            downloadProgress = 1
            downloadDetail = "FastVLM model is installed."
        } else {
            state = .missing
            downloadProgress = 0
            downloadDetail = "Waiting to start FastVLM download."
        }
    }

    func setImportFailure(_ error: Error) {
        state = .failed("FastVLM import failed: \(error.localizedDescription)")
    }

    func importModelDirectory(from pickedURL: URL) async {
        downloadTask?.cancel()
        downloadTask = nil
        state = .installing

        let accessed = pickedURL.startAccessingSecurityScopedResource()
        defer {
            if accessed {
                pickedURL.stopAccessingSecurityScopedResource()
            }
        }

        do {
            let sourceDirectory = try Self.normalizeModelDirectory(from: pickedURL)
            if let validationError = Self.validateModelDirectory(sourceDirectory) {
                throw NSError(
                    domain: "SmartCane.FastVLMModelStore",
                    code: 2,
                    userInfo: [NSLocalizedDescriptionKey: validationError]
                )
            }

            let destination = try Self.installedModelDirectoryURL()
            let fileManager = FileManager.default
            let parentDirectory = destination.deletingLastPathComponent()
            try fileManager.createDirectory(at: parentDirectory, withIntermediateDirectories: true)

            if fileManager.fileExists(atPath: destination.path) {
                try fileManager.removeItem(at: destination)
            }

            try fileManager.copyItem(at: sourceDirectory, to: destination)
            try await Self.ensureTokenizerMetadataIsUsable(in: destination)
            refresh()
        } catch {
            state = .failed("FastVLM import failed: \(error.localizedDescription)")
        }
    }

    func ensureModelAvailable() {
        refresh()

        switch state {
        case .ready, .installing, .downloading:
            return
        case .checking, .missing, .failed:
            break
        }

        guard downloadTask == nil else {
            return
        }

        downloadTask = Task { [weak self] in
            await self?.downloadModelAutomatically()
        }
    }

    func retryDownload() {
        downloadTask?.cancel()
        downloadTask = nil
        ensureModelAvailable()
    }

    private func validateInstalledModelIfNeeded() async {
        guard let directory = Self.existingInstalledModelDirectory() else {
            return
        }

        do {
            try await Self.ensureTokenizerMetadataIsUsable(in: directory)
        } catch {
            try? Self.removeInstalledModelDirectory()
            state = .missing
            downloadProgress = 0
            downloadDetail = "Repairing FastVLM model installation."
            ensureModelAvailable()
        }
    }

    private func downloadModelAutomatically() async {
#if canImport(Hub)
        state = .downloading(progress: 0)
        downloadProgress = 0
        downloadDetail = "Starting FastVLM download."

        do {
            let fileManager = FileManager.default
            let root = try Self.fastVLMRootDirectoryURL()
            let downloadBase = root.appendingPathComponent("downloads", isDirectory: true)
            let destination = try Self.installedModelDirectoryURL()

            if fileManager.fileExists(atPath: downloadBase.path) {
                try fileManager.removeItem(at: downloadBase)
            }
            try fileManager.createDirectory(at: root, withIntermediateDirectories: true)

            let repo = Hub.Repo(id: Self.remoteModelID)
            let hub = HubApi(downloadBase: downloadBase)
            let downloadedDirectory = try await hub.snapshot(
                from: repo,
                revision: Self.remoteModelRevision,
                matching: Self.downloadGlobs,
                progressHandler: { [weak self] progress, speed in
                    self?.updateDownloadProgress(progress, speed: speed)
                }
            )

            let normalizedDirectory = try Self.normalizeModelDirectory(from: downloadedDirectory)
            if let validationError = Self.validateModelDirectory(normalizedDirectory) {
                throw NSError(
                    domain: "SmartCane.FastVLMModelStore",
                    code: 3,
                    userInfo: [NSLocalizedDescriptionKey: validationError]
                )
            }

            if fileManager.fileExists(atPath: destination.path) {
                try fileManager.removeItem(at: destination)
            }

            if normalizedDirectory.standardizedFileURL == downloadedDirectory.standardizedFileURL {
                try fileManager.moveItem(at: downloadedDirectory, to: destination)
            } else {
                try fileManager.copyItem(at: normalizedDirectory, to: destination)
                try? fileManager.removeItem(at: downloadBase)
            }

            try await Self.ensureTokenizerMetadataIsUsable(in: destination)

            refresh()
        } catch {
            if error is CancellationError {
                state = .missing
                downloadDetail = "FastVLM download cancelled."
            } else {
                state = .failed("FastVLM download failed: \(error.localizedDescription)")
                downloadDetail = "FastVLM download failed."
            }
        }

        downloadTask = nil
#else
        state = .failed("Automatic FastVLM download is unavailable in this build.")
        downloadDetail = "Hub download support is missing."
#endif
    }

    private func updateDownloadProgress(_ progress: Progress, speed: Double?) {
        let total = progress.totalUnitCount
        let completed = progress.completedUnitCount
        let fraction =
            total > 0
            ? min(max(Double(completed) / Double(total), 0), 1)
            : progress.fractionCompleted

        downloadProgress = fraction.isFinite ? fraction : 0
        state = .downloading(progress: downloadProgress)

        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useMB, .useGB]
        formatter.countStyle = .file

        if total > 0 {
            let completedText = formatter.string(fromByteCount: completed)
            let totalText = formatter.string(fromByteCount: total)
            if let speed, speed > 0 {
                let speedText = formatter.string(fromByteCount: Int64(speed)) + "/s"
                downloadDetail = "\(completedText) of \(totalText) at \(speedText)"
            } else {
                downloadDetail = "\(completedText) of \(totalText)"
            }
        } else {
            downloadDetail = "Downloading FastVLM model files."
        }
    }

    private static func normalizeModelDirectory(from pickedURL: URL) throws -> URL {
        if validateModelDirectory(pickedURL) == nil {
            return pickedURL
        }

        let nestedModel = pickedURL.appendingPathComponent("model", isDirectory: true)
        if validateModelDirectory(nestedModel) == nil {
            return nestedModel
        }

        let childDirectories = try FileManager.default.contentsOfDirectory(
            at: pickedURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ).filter {
            (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        }

        if let firstValid = childDirectories.first(where: { validateModelDirectory($0) == nil }) {
            return firstValid
        }

        throw NSError(
            domain: "SmartCane.FastVLMModelStore",
            code: 1,
            userInfo: [
                NSLocalizedDescriptionKey:
                    "Select the folder that directly contains config.json, tokenizer.json, processor_config.json, and model.safetensors."
            ]
        )
    }
}

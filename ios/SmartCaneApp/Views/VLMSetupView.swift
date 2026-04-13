import SwiftUI
import UniformTypeIdentifiers

struct VLMSetupView: View {
    @EnvironmentObject private var modelStore: FastVLMModelStore
    @State private var showsImporter = false

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.96, green: 0.95, blue: 0.92),
                    Color(red: 0.90, green: 0.94, blue: 0.96)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            VStack(alignment: .leading, spacing: 20) {
                Text("Preparing FastVLM")
                    .font(.largeTitle.weight(.bold))

                Text("SmartCane requires the FastVLM model before the app can run. The app will download it automatically once, keep it in app storage, and reuse it across future launches and app updates.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                statusCard

                if modelStore.canRetryDownload {
                    Button {
                        modelStore.retryDownload()
                    } label: {
                        Text("Retry download")
                            .font(.headline.weight(.semibold))
                            .frame(maxWidth: .infinity, minHeight: 52)
                            .background(Color.white.opacity(0.9), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }

                Button {
                    showsImporter = true
                } label: {
                    Text(modelStore.state == .installing ? "Importing model..." : "Import model folder instead")
                        .font(.headline.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 52)
                        .background(Color.white.opacity(0.9), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                }
                .buttonStyle(.plain)
                .disabled(modelStore.state == .installing || isDownloading)

                Button {
                    modelStore.refresh()
                } label: {
                    Text("Recheck installed model")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.plain)

                Text("Automatic download needs internet access and enough free storage. Manual import is still available as a fallback.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Spacer()
            }
            .padding(24)
        }
        .task {
            modelStore.ensureModelAvailable()
        }
        .fileImporter(
            isPresented: $showsImporter,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else {
                    return
                }
                Task {
                    await modelStore.importModelDirectory(from: url)
                }
            case .failure(let error):
                let nsError = error as NSError
                if nsError.domain == NSCocoaErrorDomain, nsError.code == NSUserCancelledError {
                    return
                }
                modelStore.setImportFailure(error)
            }
        }
    }

    private var isDownloading: Bool {
        if case .downloading = modelStore.state {
            return true
        }
        return false
    }

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Status")
                .font(.headline.weight(.semibold))

            Text(modelStore.statusMessage)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            switch modelStore.state {
            case .downloading:
                ProgressView(value: modelStore.downloadProgress)
                    .progressViewStyle(.linear)

                Text(modelStore.downloadDetail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            case .installing:
                ProgressView()
                    .progressViewStyle(.linear)
            case .ready(let url):
                Text(url.path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            case .failed(let message):
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            default:
                EmptyView()
            }
        }
        .padding(18)
        .background(Color.white.opacity(0.72), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(Color.white.opacity(0.55), lineWidth: 1)
        )
    }
}

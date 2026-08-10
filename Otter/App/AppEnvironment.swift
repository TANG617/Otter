import Foundation
import Observation

@MainActor
@Observable
final class AppEnvironment {
    let session: AppSession
    let usesFixtures: Bool
    private(set) var liveRuntime: LiveAppRuntime?
    private(set) var fixtureRuntime: FixtureAppRuntime?

    private let accountStore: any ActiveAccountStoring
    private let keyStore: any APIKeyStoring
    private let fileManager: FileManager
    private var pendingConnection: PendingConnection?
    private var activationTask: Task<Void, Never>?

    init(
        session: AppSession,
        usesFixtures: Bool,
        liveRuntime: LiveAppRuntime? = nil,
        fixtureRuntime: FixtureAppRuntime? = nil,
        accountStore: any ActiveAccountStoring = UserDefaultsActiveAccountStore(),
        keyStore: any APIKeyStoring = KeychainAPIKeyStore(),
        fileManager: FileManager = .default
    ) {
        self.session = session
        self.usesFixtures = usesFixtures
        self.liveRuntime = liveRuntime
        self.fixtureRuntime = fixtureRuntime
        self.accountStore = accountStore
        self.keyStore = keyStore
        self.fileManager = fileManager
    }

    static func makeDefault(processInfo: ProcessInfo = .processInfo) -> AppEnvironment {
        let arguments = processInfo.arguments
        let environment = processInfo.environment
        let fixtureArgumentIndex = arguments.firstIndex(of: "-OTTER_USE_FIXTURES")
        let fixtureArgumentValue = fixtureArgumentIndex.flatMap { index in
            arguments.indices.contains(index + 1) ? arguments[index + 1] : nil
        }
        let usesFixtures = fixtureArgumentValue == "YES" || environment["OTTER_USE_FIXTURES"] == "YES"
        if usesFixtures {
            let configuration = FixtureLibraryConfiguration.resolved(
                arguments: arguments,
                environment: environment
            )
            return AppEnvironment(
                session: AppSession(initialState: .fixture),
                usesFixtures: true,
                fixtureRuntime: .make(configuration: configuration)
            )
        }

        let accountStore = UserDefaultsActiveAccountStore()
        let keyStore = KeychainAPIKeyStore()
        do {
            guard let record = try accountStore.load(),
                  let apiKey = try keyStore.apiKey(accountNamespace: record.namespace) else {
                return AppEnvironment(
                    session: AppSession(initialState: .signedOut),
                    usesFixtures: false,
                    accountStore: accountStore,
                    keyStore: keyStore
                )
            }
            let runtime = try LiveAppRuntimeFactory.make(record: record, apiKey: apiKey)
            return AppEnvironment(
                session: AppSession(initialState: .active(accountNamespace: record.namespace)),
                usesFixtures: false,
                liveRuntime: runtime,
                accountStore: accountStore,
                keyStore: keyStore
            )
        } catch {
            return AppEnvironment(
                session: AppSession(initialState: .authenticationInvalid),
                usesFixtures: false,
                accountStore: accountStore,
                keyStore: keyStore
            )
        }
    }

    func validateConnection(_ request: OnboardingConnectRequest) async -> ConnectionValidationResult {
        guard let apiKey = APIKey(request.apiKey) else {
            return .failed(.invalidCredentials)
        }
        do {
            let serverURL = try NormalizedServerURL(request.serverURL.absoluteString)
            let namespace = UUID()
            let client = ImmichClient(
                accountNamespace: namespace,
                serverURL: serverURL,
                apiKey: apiKey
            )
            async let probe = client.probeVersion()
            async let firstPage = client.searchAssets(
                AssetSearchRequest(pageSize: 1),
                accountNamespace: namespace
            )
            let (probeResult, _) = try await (probe, firstPage)
            guard probeResult.version.major >= 3 else {
                return .failed(.incompatibleServer)
            }
            let summary = ConnectedServerSummary(
                serverVersion: probeResult.version.description,
                accountDisplayName: serverURL.url.host() ?? "Immich"
            )
            pendingConnection = PendingConnection(
                request: request,
                serverURL: serverURL,
                apiKey: apiKey,
                probe: probeResult
            )
            return .connected(summary)
        } catch let error as ImmichClientError {
            return .failed(Self.connectionFailure(for: error))
        } catch is ServerURLNormalizationError {
            return .failed(.serverUnavailable)
        } catch {
            return .failed(.unknown)
        }
    }

    func completeConnection(
        request: OnboardingConnectRequest,
        summary: ConnectedServerSummary
    ) {
        guard let pendingConnection, pendingConnection.request == request else {
            session.transition(to: .signedOut)
            return
        }
        self.pendingConnection = nil
        activationTask?.cancel()
        session.transition(to: .connecting)

        let accountStore = self.accountStore
        let keyStore = self.keyStore
        let fileManager = self.fileManager
        let existing = try? accountStore.load()
        let namespace = existing?.serverURL == pendingConnection.serverURL.url
            ? existing!.namespace
            : UUID()
        let record = ActiveAccountRecord(
            namespace: namespace,
            serverURL: pendingConnection.serverURL.url,
            serverVersion: pendingConnection.probe.version,
            cacheLimitBytes: existing?.cacheLimitBytes ?? SettingsCacheLimit.gibibytes2.rawValue
        )
        let apiKey = pendingConnection.apiKey

        activationTask = Task {
            do {
                let runtime = try LiveAppRuntimeFactory.make(
                    record: record,
                    apiKey: apiKey,
                    fileManager: fileManager
                )
                try keyStore.save(apiKey, accountNamespace: namespace)
                do {
                    try accountStore.save(record)
                } catch {
                    try? keyStore.remove(accountNamespace: namespace)
                    throw error
                }
                guard !Task.isCancelled else { return }
                liveRuntime = runtime
                session.transition(to: .active(accountNamespace: namespace))
            } catch {
                liveRuntime = nil
                session.transition(to: .signedOut)
            }
        }
    }

    func updateCacheLimit(_ limit: SettingsCacheLimit) {
        guard var record = try? accountStore.load() else { return }
        record.cacheLimitBytes = limit.rawValue
        try? accountStore.save(record)
        if let runtime = liveRuntime {
            Task { try? await runtime.diskCache.setByteLimit(limit.rawValue) }
        }
    }

    func clearMediaCache() async -> ActionOutcome {
        guard let runtime = liveRuntime else {
            return .failure(PresentationFailure(title: "Cache Unavailable", message: "No active account is connected."))
        }
        do {
            await runtime.mediaPipeline.clearMemory()
            try await runtime.mediaPipeline.clearDisk(accountNamespace: runtime.account.namespace)
            return .success(message: "Media cache cleared.")
        } catch {
            return .failure(PresentationFailure(title: "Could Not Clear Cache", message: "Try again in a moment."))
        }
    }

    func signOut() async -> ActionOutcome {
        activationTask?.cancel()
        activationTask = nil
        let runtime = liveRuntime
        let record = try? accountStore.load()
        if let runtime {
            await runtime.mediaPipeline.clearMemory()
            try? await runtime.mediaPipeline.clearDisk(accountNamespace: runtime.account.namespace)
            try? runtime.database.deleteAccount(namespace: runtime.account.namespace)
        }
        if let record { try? keyStore.remove(accountNamespace: record.namespace) }
        try? accountStore.remove()
        liveRuntime = nil
        session.transition(to: .signedOut)
        return .success(message: "Signed out.")
    }

    func settingsSnapshot() async -> SettingsSnapshot {
        if usesFixtures { return .fixture }
        guard let runtime = liveRuntime else {
            return SettingsSnapshot(
                accountDisplayName: "Signed Out",
                serverDisplayName: "Unavailable",
                serverVersion: "Unavailable",
                cacheUsageBytes: 0,
                cacheLimit: .gibibytes2,
                appVersion: Self.appVersion,
                usesFixtures: false
            )
        }
        let stats = try? await runtime.diskCache.stats()
        let record = try? accountStore.load()
        let limit = record.flatMap { SettingsCacheLimit(rawValue: $0.cacheLimitBytes) } ?? .gibibytes2
        return SettingsSnapshot(
            accountDisplayName: runtime.serverURL.url.host() ?? "Immich",
            serverDisplayName: runtime.serverURL.url.host() ?? "Immich",
            serverVersion: runtime.account.serverVersion ?? "Unavailable",
            cacheUsageBytes: stats?.byteCount ?? 0,
            cacheLimit: limit,
            appVersion: Self.appVersion,
            usesFixtures: false
        )
    }

    func diagnosticsSnapshot() async -> DiagnosticsSnapshot {
        if usesFixtures { return .fixture }
        guard let runtime = liveRuntime else {
            return DiagnosticsSnapshot(
                appVersion: Self.appVersion,
                buildNumber: Self.buildNumber,
                serverVersion: nil,
                connectionStatus: .signedOut,
                assetCount: 0,
                lastMetadataRefresh: nil,
                mediaCacheBytes: 0,
                memoryCacheBytes: 0,
                inFlightMediaRequests: 0,
                queuedDecodeCount: 0,
                ratingWriteStatus: "Unavailable",
                originalPermissionStatus: "Unavailable",
                currentExportStatus: "Unavailable",
                thumbnailObservation: nil,
                previewObservation: nil,
                fullsizeObservation: nil,
                usesFixtures: false
            )
        }

        let stats = try? await runtime.mediaPipeline.stats()
        let syncState = try? runtime.database.syncState(accountNamespace: runtime.account.namespace)
        let profile = try? runtime.database.serverMediaProfile(accountNamespace: runtime.account.namespace)
        let assetCount = (try? runtime.database.count(accountNamespace: runtime.account.namespace)) ?? 0
        let ratingAvailability = await runtime.ratingRepository.writeAvailability
        return DiagnosticsSnapshot(
            appVersion: Self.appVersion,
            buildNumber: Self.buildNumber,
            serverVersion: runtime.account.serverVersion,
            connectionStatus: .connected,
            assetCount: assetCount,
            lastMetadataRefresh: syncState?.lastIncrementalRefreshAt ?? syncState?.lastFullReconciliationAt,
            mediaCacheBytes: stats?.disk.byteCount ?? 0,
            memoryCacheBytes: Int64(stats?.memory.estimatedCost ?? 0),
            inFlightMediaRequests: (stats?.inFlightByteRequests ?? 0) + (stats?.inFlightRenderRequests ?? 0),
            queuedDecodeCount: stats?.scheduler.queuedByLane[.decode] ?? 0,
            ratingWriteStatus: ratingAvailability == .available ? "Available" : "Unavailable",
            originalPermissionStatus: Self.capabilityText(runtime.capabilities.originalDownload),
            currentExportStatus: runtime.account.serverVersion?.hasPrefix("3.") == true ? "Available" : "Unverified",
            thumbnailObservation: profile?.thumbnail,
            previewObservation: profile?.preview,
            fullsizeObservation: profile?.fullsize,
            usesFixtures: false
        )
    }

    private static func connectionFailure(for error: ImmichClientError) -> ConnectionValidationFailure {
        switch error {
        case .authenticationInvalid: .invalidCredentials
        case .permissionDenied: .insufficientPermissions
        case .transport(code: NSURLErrorAppTransportSecurityRequiresSecureConnection): .transportSecurity
        case .transport, .server, .rateLimited: .serverUnavailable
        case .invalidPayload, .invalidResponse, .invalidContinuation: .incompatibleServer
        case .crossOriginResponse: .transportSecurity
        case .notFound, .wrongAccount: .unknown
        }
    }

    private static func capabilityText(_ capability: CapabilityAvailability) -> String {
        switch capability {
        case .available: "Available"
        case .unverified: "Unverified"
        case .unavailable: "Unavailable"
        }
    }

    private static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
    }

    private static var buildNumber: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
    }
}

private struct PendingConnection: Sendable {
    let request: OnboardingConnectRequest
    let serverURL: NormalizedServerURL
    let apiKey: APIKey
    let probe: ServerProbeResult
}

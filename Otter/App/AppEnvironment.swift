import Foundation
import Observation

@MainActor
@Observable
final class AppEnvironment {
    let session: AppSession
    let usesFixtures: Bool
    let fixtureRatingWritesFail: Bool
    let fixtureCurrentExportAvailable: Bool
    private(set) var liveRuntime: LiveAppRuntime?
    private(set) var fixtureRuntime: FixtureAppRuntime?

    private let accountStore: any ActiveAccountStoring
    private let keyStore: any APIKeyStoring
    private let fileManager: FileManager
    private var pendingConnection: PendingConnection?
    private var activationTask: Task<Void, Never>?
    private var authenticationTask: Task<Void, Never>?

    init(
        session: AppSession,
        usesFixtures: Bool,
        liveRuntime: LiveAppRuntime? = nil,
        fixtureRuntime: FixtureAppRuntime? = nil,
        fixtureRatingWritesFail: Bool = false,
        fixtureCurrentExportAvailable: Bool = true,
        accountStore: any ActiveAccountStoring = UserDefaultsActiveAccountStore(),
        keyStore: any APIKeyStoring = KeychainAPIKeyStore(),
        fileManager: FileManager = .default
    ) {
        self.session = session
        self.usesFixtures = usesFixtures
        self.fixtureRatingWritesFail = fixtureRatingWritesFail
        self.fixtureCurrentExportAvailable = fixtureCurrentExportAvailable
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
                fixtureRuntime: .make(configuration: configuration),
                fixtureRatingWritesFail: environment["OTTER_FIXTURE_RATING_FAILURE"] == "YES",
                fixtureCurrentExportAvailable: environment["OTTER_FIXTURE_CURRENT_EXPORT_UNAVAILABLE"] != "YES"
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
            let environment = AppEnvironment(
                session: AppSession(initialState: .active(accountNamespace: record.namespace)),
                usesFixtures: false,
                liveRuntime: runtime,
                accountStore: accountStore,
                keyStore: keyStore
            )
            environment.observeAuthenticationInvalidations(from: runtime)
            return environment
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
        // A URL is not an account identity. A fresh namespace prevents a different
        // API key on the same Immich server from observing the previous account's DB/cache.
        let namespace = AccountNamespacePolicy.namespaceForNewConnection(existing: existing)
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
                    if let existing, existing.namespace != namespace {
                        try keyStore.remove(accountNamespace: existing.namespace)
                    }
                } catch {
                    try? keyStore.remove(accountNamespace: namespace)
                    if let existing {
                        try? accountStore.save(existing)
                    } else {
                        try? accountStore.remove()
                    }
                    throw error
                }
                guard !Task.isCancelled else { return }
                if let existing, existing.namespace != namespace {
                    try? runtime.database.deleteAccount(namespace: existing.namespace)
                    try? await runtime.diskCache.clear(accountNamespace: existing.namespace)
                }
                liveRuntime = runtime
                observeAuthenticationInvalidations(from: runtime)
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
        authenticationTask?.cancel()
        authenticationTask = nil
        let runtime = liveRuntime
        let record = try? accountStore.load()
        liveRuntime = nil
        session.transition(to: .signedOut)
        await Task.yield()
        var didFail = false
        if let runtime {
            await runtime.mediaPipeline.clearMemory()
            do { try await runtime.mediaPipeline.clearDisk(accountNamespace: runtime.account.namespace) }
            catch { didFail = true }
            do { try runtime.database.deleteAccount(namespace: runtime.account.namespace) }
            catch { didFail = true }
        }
        if let record {
            do { try keyStore.remove(accountNamespace: record.namespace) }
            catch { didFail = true }
        }
        do { try accountStore.remove() }
        catch { didFail = true }
        return didFail
            ? .failure(PresentationFailure(
                title: "Signed Out with Cleanup Warning",
                message: "Otter closed the session, but some local data could not be removed. Try signing out again after restarting the app."
            ))
            : .success(message: "Signed out.")
    }

    private func observeAuthenticationInvalidations(from runtime: LiveAppRuntime) {
        authenticationTask?.cancel()
        let namespace = runtime.account.namespace
        authenticationTask = Task { [weak self] in
            for await _ in runtime.authenticationInvalidations {
                guard !Task.isCancelled,
                      let self,
                      self.liveRuntime?.account.namespace == namespace else { return }
                self.liveRuntime = nil
                self.session.transition(to: .authenticationInvalid)
                try? self.keyStore.remove(accountNamespace: namespace)
                try? self.accountStore.remove()
                await runtime.mediaPipeline.clearMemory()
                try? await runtime.mediaPipeline.clearDisk(accountNamespace: namespace)
                try? runtime.database.deleteAccount(namespace: namespace)
                return
            }
        }
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
        let ratingStatus: String = switch ratingAvailability {
        case .available: "Available"
        case .unverified: "Unverified"
        case .unavailable: "Unavailable"
        }
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
            ratingWriteStatus: ratingStatus,
            originalPermissionStatus: Self.capabilityText(runtime.capabilities.originalDownload),
            currentExportStatus: "Unverified",
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

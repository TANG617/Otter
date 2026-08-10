import Foundation

struct ImmichClient: AssetRemoteDataSource, Sendable {
    let accountNamespace: UUID
    let serverURL: NormalizedServerURL

    private let requestBuilder: ImmichRequestBuilder
    private let transport: any ImmichHTTPTransport
    private let allowedOrigin: URLOrigin
    private let onAuthenticationInvalid: @Sendable () -> Void

    init(
        accountNamespace: UUID,
        serverURL: NormalizedServerURL,
        apiKey: APIKey,
        transport: (any ImmichHTTPTransport)? = nil,
        onAuthenticationInvalid: @escaping @Sendable () -> Void = { }
    ) {
        self.accountNamespace = accountNamespace
        self.serverURL = serverURL
        requestBuilder = ImmichRequestBuilder(serverURL: serverURL, apiKey: apiKey)
        self.transport = transport ?? URLSessionImmichTransport(serverURL: serverURL, apiKey: apiKey)
        allowedOrigin = URLOrigin(url: serverURL.url)!
        self.onAuthenticationInvalid = onAuthenticationInvalid
    }

    func probeVersion() async throws -> ServerProbeResult {
        let request = try requestBuilder.request(
            method: "GET",
            pathComponents: ["server", "version"],
            authenticated: false
        )
        let data = try await perform(request)
        let dto: ServerVersionDTO = try decode(data)
        let version = SemanticVersion(
            major: dto.major,
            minor: dto.minor,
            patch: dto.patch,
            prerelease: dto.prerelease
        )
        return ServerProbeResult(version: version, capabilities: ImmichCapabilityProbe.capabilities(for: version))
    }

    func searchAssets(
        _ request: AssetSearchRequest,
        accountNamespace: UUID
    ) async throws -> AssetSearchPage {
        try validate(accountNamespace: accountNamespace)
        let page: Int
        if let continuation = request.continuation {
            guard let parsed = Int(continuation), parsed > 0 else {
                throw ImmichClientError.invalidContinuation
            }
            page = parsed
        } else {
            page = 1
        }
        let body = try ImmichJSON.encoder().encode(
            MetadataSearchBody(page: page, size: request.pageSize, updatedAfter: request.updatedAfter)
        )
        let urlRequest = try requestBuilder.request(
            method: "POST",
            pathComponents: ["search", "metadata"],
            body: body
        )
        let data = try await perform(urlRequest)
        let response: SearchMetadataResponseDTO = try decode(data)
        var seen = Set<UUID>()
        let assets = response.assets.items.compactMap { dto -> TimelineAsset? in
            guard let asset = map(dto, accountNamespace: accountNamespace),
                  asset.isTimelineEligible,
                  seen.insert(asset.id).inserted else {
                return nil
            }
            return asset
        }
        return AssetSearchPage(assets: assets, nextContinuation: response.assets.nextPage?.value)
    }

    func asset(id: UUID, accountNamespace: UUID) async throws -> TimelineAsset {
        try validate(accountNamespace: accountNamespace)
        let request = try requestBuilder.request(
            method: "GET",
            pathComponents: ["assets", id.uuidString.lowercased()]
        )
        let data = try await perform(request)
        let dto: ImmichAssetDTO = try decode(data)
        guard let asset = map(dto, accountNamespace: accountNamespace) else {
            throw ImmichClientError.invalidPayload
        }
        return asset
    }

    func writeRating(
        _ rating: AssetRating?,
        assetID: UUID,
        accountNamespace: UUID
    ) async throws {
        try validate(accountNamespace: accountNamespace)
        let body = try ImmichJSON.encoder().encode(RatingUpdateBody(rating: rating))
        let request = try requestBuilder.request(
            method: "PUT",
            pathComponents: ["assets", assetID.uuidString.lowercased()],
            body: body
        )
        _ = try await perform(request)
    }

    private func validate(accountNamespace: UUID) throws {
        guard accountNamespace == self.accountNamespace else {
            throw ImmichClientError.wrongAccount
        }
    }

    private func perform(_ request: URLRequest) async throws -> Data {
        do {
            let (data, response) = try await transport.data(for: request)
            guard let responseURL = response.url,
                  URLOrigin(url: responseURL) == allowedOrigin else {
                throw ImmichClientError.crossOriginResponse
            }
            try ImmichHTTPResponseValidator.validate(response)
            return data
        } catch let error as ImmichClientError {
            if error == .authenticationInvalid {
                onAuthenticationInvalid()
            }
            throw error
        } catch let error as URLError {
            throw ImmichClientError.transport(code: error.errorCode)
        } catch {
            throw ImmichClientError.transport(code: nil)
        }
    }

    private func decode<Value: Decodable>(_ data: Data) throws -> Value {
        do {
            return try ImmichJSON.decoder().decode(Value.self, from: data)
        } catch {
            throw ImmichClientError.invalidPayload
        }
    }

    private func map(_ dto: ImmichAssetDTO, accountNamespace: UUID) -> TimelineAsset? {
        guard let id = UUID(uuidString: dto.id), dto.type == "IMAGE" else {
            return nil
        }
        return TimelineAsset(
            accountNamespace: accountNamespace,
            id: id,
            ownerID: dto.ownerId.flatMap(UUID.init(uuidString:)),
            mediaType: .image,
            localDateTime: dto.localDateTime,
            fileCreatedAt: dto.fileCreatedAt,
            createdAt: dto.createdAt,
            updatedAt: dto.updatedAt,
            width: dto.width ?? dto.exifInfo?.exifImageWidth,
            height: dto.height ?? dto.exifInfo?.exifImageHeight,
            thumbhash: dto.thumbhash,
            checksum: dto.checksum,
            originalFileName: dto.originalFileName,
            originalMimeType: dto.originalMimeType,
            isFavorite: dto.isFavorite ?? false,
            isEdited: dto.isEdited ?? false,
            isArchived: dto.isArchived ?? false,
            isTrashed: (dto.isTrashed ?? false) || dto.deletedAt != nil,
            visibility: dto.visibility,
            rating: dto.exifInfo?.rating.flatMap(AssetRating.init(rawValue:))
        )
    }
}

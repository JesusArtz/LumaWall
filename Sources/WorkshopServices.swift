import Foundation

struct WorkshopPage: Sendable {
    let items: [WorkshopItem]
    let nextCursor: String?
    let total: Int
}

enum WorkshopAPIError: LocalizedError {
    case missingAPIKey
    case invalidRequest
    case invalidResponse
    case server(status: Int, message: String?)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "Add a Steam Web API key in Settings to browse the Workshop."
        case .invalidRequest:
            return "The Workshop request could not be created."
        case .invalidResponse:
            return "Steam returned Workshop data in an unexpected format."
        case .server(let status, let message):
            if let message, !message.isEmpty {
                return "Steam returned an error (HTTP \(status)): \(message)"
            }
            return "Steam returned an error (HTTP \(status))."
        }
    }
}

struct WorkshopAPIService: Sendable {
    private let session: URLSession

    init(session: URLSession? = nil) {
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.urlCache = nil
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            self.session = URLSession(configuration: configuration)
        }
    }

    func query(
        apiKey: String,
        searchText: String,
        sort: WorkshopSort,
        type: WorkshopTypeFilter,
        requiredTag: String?,
        content: WorkshopContentFilter,
        cursor: String? = nil,
        pageSize: Int = 50
    ) async throws -> WorkshopPage {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw WorkshopAPIError.missingAPIKey }
        var components = URLComponents(string: "https://api.steampowered.com/IPublishedFileService/QueryFiles/v1/")
        var queryItems = [
            URLQueryItem(name: "key", value: key),
            URLQueryItem(name: "query_type", value: String(sort.queryType)),
            URLQueryItem(name: "cursor", value: cursor ?? "*"),
            URLQueryItem(name: "numperpage", value: String(min(max(pageSize, 1), 100))),
            URLQueryItem(name: "creator_appid", value: ProductInfo.wallpaperEngineAppID),
            URLQueryItem(name: "appid", value: ProductInfo.wallpaperEngineAppID),
            URLQueryItem(name: "match_all_tags", value: "1"),
            URLQueryItem(name: "return_tags", value: "1"),
            URLQueryItem(name: "return_previews", value: "1"),
            URLQueryItem(name: "return_vote_data", value: "1"),
            URLQueryItem(name: "return_short_description", value: "1"),
            URLQueryItem(name: "return_metadata", value: "1"),
            URLQueryItem(name: "strip_description_bbcode", value: "1")
        ]
        let trimmedSearch = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedSearch.isEmpty {
            queryItems.append(URLQueryItem(name: "search_text", value: trimmedSearch))
        }
        if sort == .trending {
            queryItems.append(URLQueryItem(name: "days", value: "7"))
            queryItems.append(URLQueryItem(name: "include_recent_votes_only", value: "1"))
        }
        var requiredTags: [String] = []
        if let typeTag = type.requiredTag { requiredTags.append(typeTag) }
        if let requiredTag = requiredTag?.trimmingCharacters(in: .whitespacesAndNewlines),
           !requiredTag.isEmpty,
           !requiredTags.contains(where: { $0.caseInsensitiveCompare(requiredTag) == .orderedSame }) {
            requiredTags.append(requiredTag)
        }
        for (index, tag) in requiredTags.enumerated() {
            queryItems.append(URLQueryItem(name: "requiredtags[\(index)]", value: tag))
        }
        components?.queryItems = queryItems
        guard let url = components?.url else { throw WorkshopAPIError.invalidRequest }

        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw WorkshopAPIError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            throw WorkshopAPIError.server(status: http.statusCode, message: Self.serverMessage(from: data))
        }
        var page = try Self.parsePage(data)
        page = WorkshopPage(
            items: Self.filter(page.items, content: content),
            nextCursor: page.nextCursor,
            total: page.total
        )
        let names = try? await creatorNames(
            apiKey: key,
            steamIDs: Array(Set(page.items.compactMap(\.creatorSteamID)))
        )
        guard let names, !names.isEmpty else { return page }
        return WorkshopPage(
            items: page.items.map { item in
                var item = item
                if let creatorSteamID = item.creatorSteamID {
                    item.creatorName = names[creatorSteamID]
                }
                return item
            },
            nextCursor: page.nextCursor,
            total: page.total
        )
    }

    static func parsePage(_ data: Data) throws -> WorkshopPage {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let response = root["response"] as? [String: Any],
              let details = response["publishedfiledetails"] as? [[String: Any]] else {
            throw WorkshopAPIError.invalidResponse
        }
        let items = details.compactMap(Self.mapItem)
        return WorkshopPage(
            items: items,
            nextCursor: string(response["next_cursor"])?.nilIfBlank,
            total: integer(response["total"]) ?? items.count
        )
    }

    private func creatorNames(apiKey: String, steamIDs: [String]) async throws -> [String: String] {
        guard !steamIDs.isEmpty else { return [:] }
        var result: [String: String] = [:]
        for batchStart in stride(from: 0, to: steamIDs.count, by: 100) {
            let batch = Array(steamIDs[batchStart..<min(batchStart + 100, steamIDs.count)])
            var components = URLComponents(string: "https://api.steampowered.com/ISteamUser/GetPlayerSummaries/v2/")
            components?.queryItems = [
                URLQueryItem(name: "key", value: apiKey),
                URLQueryItem(name: "steamids", value: batch.joined(separator: ","))
            ]
            guard let url = components?.url else { continue }
            let (data, response) = try await session.data(from: url)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                  let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let response = root["response"] as? [String: Any],
                  let players = response["players"] as? [[String: Any]] else { continue }
            for player in players {
                if let id = Self.string(player["steamid"]), let name = Self.string(player["personaname"]) {
                    result[id] = name
                }
            }
        }
        return result
    }

    private static func mapItem(_ dictionary: [String: Any]) -> WorkshopItem? {
        guard let id = string(dictionary["publishedfileid"]), id.isSteamPublishedFileID,
              let title = string(dictionary["title"])?.nilIfBlank else { return nil }
        let tagObjects = dictionary["tags"] as? [[String: Any]] ?? []
        let tags = tagObjects.compactMap { string($0["display_name"] ?? $0["tag"]) }
        let lowerTags = Set(tagObjects.compactMap { string($0["tag"] ?? $0["display_name"])?.lowercased() })
        let type: WallpaperType
        if lowerTags.contains("video") { type = .video }
        else if lowerTags.contains("web") { type = .web }
        else if lowerTags.contains("scene") { type = .scenePackage }
        else { type = .unsupported }

        let descriptorIDs = (dictionary["content_descriptorids"] as? [Any] ?? []).compactMap(integer)
        let summary = string(dictionary["short_description"])
            ?? string(dictionary["file_description"])
        let preview = string(dictionary["preview_url"]).flatMap(URL.init(string:))
        return WorkshopItem(
            publishedFileID: id,
            title: title,
            creatorSteamID: string(dictionary["creator"]),
            creatorName: nil,
            summary: summary?.nilIfBlank,
            previewURL: preview,
            tags: tags,
            type: type,
            fileSize: int64(dictionary["file_size"]),
            updatedAt: int64(dictionary["time_updated"]).map { Date(timeIntervalSince1970: TimeInterval($0)) },
            subscriptions: integer(dictionary["subscriptions"]),
            contentDescriptorIDs: descriptorIDs
        )
    }

    private static func filter(_ items: [WorkshopItem], content: WorkshopContentFilter) -> [WorkshopItem] {
        switch content {
        case .all: return items
        case .general: return items.filter { $0.contentDescriptorIDs.isEmpty }
        case .mature: return items.filter { !$0.contentDescriptorIDs.isEmpty }
        }
    }

    private static func serverMessage(from data: Data) -> String? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return string(root["message"]) ?? string(root["error"])
    }

    private static func string(_ value: Any?) -> String? {
        if let value = value as? String { return value }
        if let value = value as? NSNumber { return value.stringValue }
        return nil
    }

    private static func integer(_ value: Any?) -> Int? {
        if let value = value as? NSNumber { return value.intValue }
        if let value = value as? String { return Int(value) }
        return nil
    }

    private static func int64(_ value: Any?) -> Int64? {
        if let value = value as? NSNumber { return value.int64Value }
        if let value = value as? String { return Int64(value) }
        return nil
    }
}

@MainActor
final class WorkshopViewModel: ObservableObject {
    @Published var searchText = ""
    @Published var sort: WorkshopSort = .trending
    @Published var typeFilter: WorkshopTypeFilter = .all
    @Published var tagFilter: String?
    @Published var contentFilter: WorkshopContentFilter = .general
    @Published private(set) var items: [WorkshopItem] = []
    @Published private(set) var isLoading = false
    @Published private(set) var canLoadMore = false
    @Published private(set) var total = 0
    @Published private(set) var errorMessage: String?
    @Published private(set) var availableTags: [String] = []

    private let service: WorkshopAPIService
    private let settings: AppSettings
    private var cursor: String?
    private var task: Task<Void, Never>?

    init(service: WorkshopAPIService = WorkshopAPIService(), settings: AppSettings) {
        self.service = service
        self.settings = settings
    }

    func reload() {
        task?.cancel()
        task = nil
        cursor = nil
        items = []
        isLoading = false
        canLoadMore = false
        errorMessage = nil
        performLoad(reset: true)
    }

    func loadMoreIfNeeded(after item: WorkshopItem) {
        guard item.id == items.last?.id, canLoadMore, !isLoading else { return }
        performLoad(reset: false)
    }

    func loadMore() {
        guard canLoadMore, !isLoading else { return }
        performLoad(reset: false)
    }

    func retry() { reload() }

    private func performLoad(reset: Bool) {
        guard let apiKey = settings.steamAPIKey(), !apiKey.isEmpty else {
            errorMessage = WorkshopAPIError.missingAPIKey.localizedDescription
            return
        }
        isLoading = true
        errorMessage = nil
        let requestedCursor = reset ? nil : cursor
        let requestedSearchText = searchText
        let requestedSort = sort
        let requestedType = typeFilter
        let requestedTag = tagFilter
        let requestedContent = contentFilter
        task = Task { [weak self] in
            guard let self else { return }
            do {
                var page = try await service.query(
                    apiKey: apiKey,
                    searchText: requestedSearchText,
                    sort: requestedSort,
                    type: requestedType,
                    requiredTag: requestedTag,
                    content: requestedContent,
                    cursor: requestedCursor
                )
                try Task.checkCancellation()
                var attempts = 1
                var previousCursor = requestedCursor
                while page.items.isEmpty,
                      let next = page.nextCursor,
                      next != previousCursor,
                      attempts < 5 {
                    previousCursor = next
                    page = try await service.query(
                        apiKey: apiKey,
                        searchText: requestedSearchText,
                        sort: requestedSort,
                        type: requestedType,
                        requiredTag: requestedTag,
                        content: requestedContent,
                        cursor: next
                    )
                    try Task.checkCancellation()
                    attempts += 1
                }
                try Task.checkCancellation()
                if reset { items = page.items }
                else {
                    let known = Set(items.map(\.id))
                    items.append(contentsOf: page.items.filter { !known.contains($0.id) })
                }
                cursor = page.nextCursor
                let typeTags = Set(["scene", "video", "web"])
                let discovered = page.items.flatMap(\.tags).filter { !typeTags.contains($0.lowercased()) }
                availableTags = Array(Set(availableTags + discovered)).sorted {
                    $0.localizedStandardCompare($1) == .orderedAscending
                }
                canLoadMore = page.nextCursor != nil && page.nextCursor != requestedCursor
                total = page.total
                isLoading = false
            } catch is CancellationError {
                return
            } catch {
                errorMessage = error.localizedDescription
                isLoading = false
                AppLog.workshop.error("Workshop query failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}

private extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

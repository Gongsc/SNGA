import Foundation
import Observation
import SwiftData

enum AIProfileGenerationPhase: Equatable, Sendable {
    case collecting
    case generating

    var title: String {
        switch self {
        case .collecting: "正在整理已加载的发布记录…"
        case .generating: "AI 正在生成用户画像…"
        }
    }
}

@MainActor
@Observable
final class AIProfileStore {
    private(set) var records: [AIProfileSummaryRecord] = []
    var selectedUID: Int64?
    private(set) var generatingUID: Int64?
    private(set) var generationPhase: AIProfileGenerationPhase?
    private(set) var streamedText = ""
    private(set) var errorMessage: String?
    private(set) var errorUID: Int64?

    @ObservationIgnored private let context: ModelContext
    @ObservationIgnored private let summarizer: any AIProfileSummarizing
    @ObservationIgnored private let connectionTester: any AIConnectionTesting
    @ObservationIgnored let keyStore: any AIKeyStore
    @ObservationIgnored private var generationTask: Task<Void, Never>?
    @ObservationIgnored private var generationID = UUID()

    init(
        context: ModelContext,
        session: AppSession,
        summarizer: any AIProfileSummarizing,
        connectionTester: any AIConnectionTesting = OpenAICompatibleClient(),
        keyStore: any AIKeyStore
    ) {
        self.context = context
        self.summarizer = summarizer
        self.connectionTester = connectionTester
        self.keyStore = keyStore
        reloadRecords()
        trimToHistoryLimit(AISettings.historyLimit)
    }

    var selectedRecord: AIProfileSummaryRecord? {
        guard let selectedUID else { return nil }
        return record(for: selectedUID)
    }

    var isShowingDetail: Bool {
        guard let selectedUID else { return false }
        return record(for: selectedUID) != nil
            || generatingUID == selectedUID
            || errorUID == selectedUID
    }

    func record(for uid: Int64) -> AIProfileSummaryRecord? {
        records.first { $0.uid == uid }
    }

    func testConnection(
        baseURLString: String,
        model: String,
        instruction: String,
        apiKeyOverride: String?
    ) async throws -> AIConnectionTestResult {
        guard let baseURL = AISettings.normalizedBaseURL(from: baseURLString) else {
            throw AIServiceError.invalidBaseURL
        }
        let resolvedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !resolvedModel.isEmpty else { throw AIServiceError.missingModel }

        let normalizedOverride = apiKeyOverride?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let apiKey: String?
        if let normalizedOverride, !normalizedOverride.isEmpty {
            apiKey = normalizedOverride
        } else {
            apiKey = try await keyStore.apiKey()
        }

        return try await connectionTester.testConnection(configuration: AIConfiguration(
            baseURL: baseURL,
            model: resolvedModel,
            apiKey: apiKey,
            instruction: instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        ))
    }

    func select(uid: Int64?) {
        selectedUID = uid
        if let uid, errorUID != uid {
            errorMessage = nil
        }
    }

    func selectMostRecentIfNeeded() {
        if selectedUID == nil || (selectedRecord == nil && generatingUID != selectedUID) {
            selectedUID = records.first?.uid
        }
    }

    func generate(
        uid: Int64,
        fallbackProfile: Profile? = nil,
        topics: [UserActivity] = [],
        replies: [UserActivity] = []
    ) {
        cancelGeneration(showsMessage: false)
        let requestID = UUID()
        generationID = requestID
        generatingUID = uid
        selectedUID = uid
        generationPhase = .collecting
        streamedText = ""
        errorMessage = nil
        errorUID = nil

        generationTask = Task { [weak self] in
            await self?.runGeneration(
                uid: uid,
                fallbackProfile: fallbackProfile,
                topics: topics,
                replies: replies,
                requestID: requestID
            )
        }
    }

    func cancelGeneration(showsMessage: Bool = true) {
        guard generatingUID != nil else { return }
        let cancelledUID = generatingUID
        generationID = UUID()
        generationTask?.cancel()
        generationTask = nil
        generatingUID = nil
        generationPhase = nil
        if showsMessage {
            errorUID = cancelledUID
            errorMessage = "已取消生成，本次结果没有保存。"
        }
    }

    func delete(_ record: AIProfileSummaryRecord) {
        let deletingUID = record.uid
        if generatingUID == deletingUID {
            cancelGeneration(showsMessage: false)
        }
        let oldIndex = records.firstIndex { $0.uid == deletingUID } ?? 0
        context.delete(record)
        saveAndReload()
        if selectedUID == deletingUID {
            selectedUID = records.isEmpty ? nil : records[min(oldIndex, records.count - 1)].uid
        }
        if errorUID == deletingUID {
            errorUID = nil
            errorMessage = nil
        }
    }

    func delete(uid: Int64) {
        guard let record = record(for: uid) else { return }
        delete(record)
    }

    func clearAll() {
        cancelGeneration(showsMessage: false)
        for record in records { context.delete(record) }
        saveAndReload()
        selectedUID = nil
        errorUID = nil
        errorMessage = nil
        streamedText = ""
    }

    func trimToHistoryLimit(_ proposedLimit: Int) {
        let limit = AISettings.normalizedHistoryLimit(proposedLimit)
        let sorted = records.sorted { $0.generatedAt > $1.generatedAt }
        guard sorted.count > limit else { return }
        let removedUIDs = Set(sorted.dropFirst(limit).map(\.uid))
        for record in sorted.dropFirst(limit) { context.delete(record) }
        saveAndReload()
        if let selectedUID, removedUIDs.contains(selectedUID) {
            self.selectedUID = records.first?.uid
        }
    }

    func clearError() {
        errorMessage = nil
        errorUID = nil
    }

    private func runGeneration(
        uid: Int64,
        fallbackProfile: Profile?,
        topics: [UserActivity],
        replies: [UserActivity],
        requestID: UUID
    ) async {
        do {
            let apiKey = try await keyStore.apiKey()
            let configuration = try AISettings.configuration(apiKey: apiKey)
            try Task.checkCancellation()
            guard generationID == requestID else { return }

            var profile = fallbackProfile
                ?? Profile(uid: uid, displayName: "NGA \(uid)", avatarURL: nil)
            if profile.displayName == "NGA \(uid)", let fallbackProfile {
                profile.displayName = fallbackProfile.displayName
            }
            if profile.avatarURL == nil {
                profile.avatarURL = fallbackProfile?.avatarURL
            }

            let input = AIProfileInput.make(
                profile: profile,
                topics: topics,
                replies: replies
            )
            generationPhase = .generating

            var completeText = ""
            for try await fragment in summarizer.streamSummary(
                configuration: configuration,
                input: input
            ) {
                try Task.checkCancellation()
                guard generationID == requestID else { return }
                completeText += fragment
                streamedText = completeText
            }

            let normalizedText = completeText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalizedText.isEmpty else { throw AIServiceError.emptyResponse }
            guard generationID == requestID else { return }
            upsert(
                profile: profile,
                summary: normalizedText,
                model: configuration.model,
                input: input
            )
            generatingUID = nil
            generationPhase = nil
            generationTask = nil
            errorUID = nil
            errorMessage = nil
        } catch is CancellationError {
            // 新请求或用户取消后，旧任务不能覆盖新状态。
        } catch {
            finishWithError(error.localizedDescription, uid: uid, requestID: requestID)
        }
    }

    private func upsert(
        profile: Profile,
        summary: String,
        model: String,
        input: AIProfileInput
    ) {
        if let existing = record(for: profile.uid) {
            existing.update(
                profile: profile,
                summary: summary,
                model: model,
                generatedAt: .now,
                topicCount: input.coverage.topicCount,
                replyCount: input.coverage.replyCount,
                wasTruncated: input.coverage.wasTruncated
            )
        } else {
            context.insert(AIProfileSummaryRecord(
                uid: profile.uid,
                displayName: profile.displayName,
                avatarURL: profile.avatarURL,
                summary: summary,
                model: model,
                topicCount: input.coverage.topicCount,
                replyCount: input.coverage.replyCount,
                wasTruncated: input.coverage.wasTruncated
            ))
        }
        saveAndReload()
        trimToHistoryLimit(AISettings.historyLimit)
        selectedUID = profile.uid
    }

    private func finishWithError(_ message: String, uid: Int64, requestID: UUID) {
        guard generationID == requestID else { return }
        generatingUID = nil
        generationPhase = nil
        generationTask = nil
        errorUID = uid
        errorMessage = message
    }

    private func reloadRecords() {
        do {
            records = try context.fetch(FetchDescriptor<AIProfileSummaryRecord>(
                sortBy: [SortDescriptor(\.generatedAt, order: .reverse)]
            ))
        } catch {
            records = []
            errorMessage = "无法读取 AI 画像历史：\(error.localizedDescription)"
        }
    }

    private func saveAndReload() {
        do {
            try context.save()
            reloadRecords()
        } catch {
            errorMessage = "无法保存 AI 画像历史：\(error.localizedDescription)"
        }
    }
}

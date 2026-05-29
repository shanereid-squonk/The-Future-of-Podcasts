import Foundation

struct AIResult {
    let score: Int
    let grade: PromptGrade
    let feedback: String
    let awardedPoints: Int
}

private struct ScoreRequest: Codable {
    let question: String?
    let expectedAnswer: String
    let userAnswer: String
    let transcript: String?
    let progressSeconds: Double?
}

final class AIService {
    var endpointURL: URL? = URL(string: "https://agora-score-shane.shareid.workers.dev")
    var promptGenerationURL: URL? = URL(string: "https://agora-prompts-qwen.agorala.workers.dev")

    func evaluateAnswer(question: String, expectedAnswer: String, userAnswer: String, transcript: String? = nil, progressSeconds: Double? = nil) async -> AIResult {
        if let endpointURL {
            do {
                let remote = try await callEndpoint(
                    url: endpointURL,
                    question: question,
                    expectedAnswer: expectedAnswer,
                    userAnswer: userAnswer,
                    transcript: transcript,
                    progressSeconds: progressSeconds
                )
                return calibratedResult(
                    remote: remote,
                    expectedAnswer: expectedAnswer,
                    userAnswer: userAnswer,
                    progressSeconds: progressSeconds
                )
            } catch {
                return localScore(expectedAnswer: expectedAnswer, userAnswer: userAnswer, progressSeconds: progressSeconds)
            }
        }

        return localScore(expectedAnswer: expectedAnswer, userAnswer: userAnswer, progressSeconds: progressSeconds)
    }

    private func localScore(expectedAnswer: String, userAnswer: String, progressSeconds: Double?) -> AIResult {
        let score = heuristicScore(expectedAnswer: expectedAnswer, userAnswer: userAnswer)

        let progressPrefix: String
        if let secs = progressSeconds, secs.isFinite {
            progressPrefix = "You’ve listened up to \(formatTime(secs)). "
        } else {
            progressPrefix = ""
        }

        let feedback: String
        switch score {
        case 85...100:
            feedback = progressPrefix + "Strong answer. You captured the main idea."
        case 60..<85:
            feedback = progressPrefix + "Close. You have the gist, but you missed key details: \(expectedAnswer)"
        case 30..<60:
            feedback = progressPrefix + "Partial. Revisit this point: \(expectedAnswer)"
        default:
            feedback = progressPrefix + "Not quite. The core takeaway is: \(expectedAnswer)"
        }

        let grade = PromptGrade.from(score: score)
        let awardedPoints = grade.pointsAwarded
        return AIResult(score: score, grade: grade, feedback: feedback, awardedPoints: awardedPoints)
    }

    private func calibratedResult(remote: AIResult, expectedAnswer: String, userAnswer: String, progressSeconds: Double?) -> AIResult {
        let local = localScore(expectedAnswer: expectedAnswer, userAnswer: userAnswer, progressSeconds: progressSeconds)

        if local.score >= 85 && remote.score < 70 {
            return local
        }

        if local.score >= 70 && remote.score + 20 < local.score {
            return local
        }

        return remote
    }

    private func heuristicScore(expectedAnswer: String, userAnswer: String) -> Int {
        let expectedOrderedTokens = meaningfulTokenList(from: expectedAnswer)
        let userOrderedTokens = meaningfulTokenList(from: userAnswer)
        let expectedTokens = Set(expectedOrderedTokens)
        let userTokens = Set(userOrderedTokens)

        guard !expectedTokens.isEmpty, !userTokens.isEmpty else { return 0 }

        let overlap = expectedTokens.intersection(userTokens)
        let precision = Double(overlap.count) / Double(max(userTokens.count, 1))
        let recall = Double(overlap.count) / Double(max(expectedTokens.count, 1))
        let f1 = (precision + recall) > 0 ? (2 * precision * recall) / (precision + recall) : 0

        let expectedPhrases = Set(ngrams(from: expectedOrderedTokens, size: 2) + ngrams(from: expectedOrderedTokens, size: 3))
        let userPhrases = Set(ngrams(from: userOrderedTokens, size: 2) + ngrams(from: userOrderedTokens, size: 3))
        let sharedPhrases = expectedPhrases.intersection(userPhrases)
        let phraseCoverage = expectedPhrases.isEmpty ? 0.0 : Double(sharedPhrases.count) / Double(expectedPhrases.count)

        let expectedLoose = expectedOrderedTokens.joined(separator: " ")
        let userLoose = userOrderedTokens.joined(separator: " ")
        let strongPhraseMatch = longestSharedWordRun(expected: expectedLoose, user: userLoose)

        var raw = (f1 * 100.0 * 0.65) + (phraseCoverage * 100.0 * 0.2)
        if strongPhraseMatch >= 3 {
            raw += 18
        } else if strongPhraseMatch == 2 {
            raw += 10
        }

        if recall >= 0.75 {
            raw += 8
        } else if recall >= 0.6 {
            raw += 4
        }

        return min(100, max(0, Int(raw.rounded())))
    }

    private func meaningfulTokens(from text: String) -> Set<String> {
        Set(meaningfulTokenList(from: text))
    }

    private func tokenize(_ text: String) -> Set<String> {
        let cleaned = normalizeLoose(text)
        let parts = cleaned.split(separator: " ")
        return Set(parts.map(String.init))
    }

    private func meaningfulTokenList(from text: String) -> [String] {
        let stopwords: Set<String> = [
            "the", "a", "an", "and", "or", "but", "to", "of", "in", "on", "for", "with", "is", "are", "was", "were",
            "it", "this", "that", "as", "by", "at", "from", "be", "has", "have", "had", "do", "does", "did", "not",
            "we", "you", "they", "he", "she", "i", "me", "our", "your", "their", "about", "into", "out", "up", "down",
            "main", "idea", "speaker", "argues", "says", "point"
        ]

        let cleaned = normalizeLoose(text)
        let parts = cleaned.split(separator: " ").map(String.init)
        return parts.filter { $0.count >= 3 && !stopwords.contains($0) }
    }

    private func normalizeLoose(_ text: String) -> String {
        text
            .lowercased()
            .replacingOccurrences(of: "[^a-z0-9 ]", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func ngrams(from tokens: [String], size: Int) -> [String] {
        guard size > 0, tokens.count >= size else { return [] }
        return (0...(tokens.count - size)).map { index in
            tokens[index..<(index + size)].joined(separator: " ")
        }
    }

    private func longestSharedWordRun(expected: String, user: String) -> Int {
        let expectedWords = expected.split(separator: " ").map(String.init)
        let userWords = user.split(separator: " ").map(String.init)
        guard !expectedWords.isEmpty, !userWords.isEmpty else { return 0 }

        var best = 0
        for i in expectedWords.indices {
            for j in userWords.indices {
                var run = 0
                while i + run < expectedWords.count, j + run < userWords.count, expectedWords[i + run] == userWords[j + run] {
                    run += 1
                }
                best = max(best, run)
            }
        }
        return best
    }

    private func formatTime(_ seconds: Double) -> String {
        guard seconds.isFinite else { return "0:00" }
        let intSeconds = Int(seconds)
        let minutes = intSeconds / 60
        let remainingSeconds = intSeconds % 60
        return String(format: "%d:%02d", minutes, remainingSeconds)
    }

    private func callEndpoint(url: URL, question: String, expectedAnswer: String, userAnswer: String, transcript: String?, progressSeconds: Double?) async throws -> AIResult {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 10

        let payload = ScoreRequest(
            question: question,
            expectedAnswer: expectedAnswer,
            userAnswer: userAnswer,
            transcript: transcript,
            progressSeconds: progressSeconds
        )
        request.httpBody = try JSONEncoder().encode(payload)

        let (data, response) = try await URLSession.shared.data(for: request)

        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw NSError(domain: "AIService", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: body])
        }

        let responseModel = try JSONDecoder().decode(ScoreResponse.self, from: data)
        let boundedScore = min(max(responseModel.score, 0), 100)
        let grade = PromptGrade.from(score: boundedScore)
        return AIResult(
            score: boundedScore,
            grade: grade,
            feedback: responseModel.feedback,
            awardedPoints: grade.pointsAwarded
        )
    }

    // MARK: - Prompt generation from transcript
    func generatePrompts(transcript: String, audioDuration: Double, desiredCount: Int = 3) async -> [Prompt] {
        let requestedCount = max(3, min(9, desiredCount))
        let effectiveDuration = resolvedDuration(audioDuration: audioDuration, transcript: transcript)
        let trimmedTranscript = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTranscript.isEmpty else { return [] }

        guard let base = resolvedPromptGenerationURL() else {
            print("[AIService] No dedicated prompt-generation endpoint configured")
            return []
        }

        let remotePool = deduplicatedPrompts(
            await fetchFrontierPromptCandidates(
                baseURL: base,
                transcript: trimmedTranscript,
                audioDuration: effectiveDuration,
                count: max(requestedCount * 2, requestedCount + 6),
                strategy: ""
            )
        )
        print("[AIService] Remote candidate prompts fetched: \(remotePool.count)")

        guard !remotePool.isEmpty else {
            print("[AIService] Prompt worker returned no usable prompts")
            return []
        }

        let rankedRemote = rankPromptCandidates(
            remotePool,
            desiredCount: requestedCount,
            audioDuration: effectiveDuration,
            transcript: trimmedTranscript
        )
        print("[AIService] Ranked remote prompts: \(rankedRemote.count)")
        return Array(rankedRemote.prefix(requestedCount))
    }

    private func resolvedPromptGenerationURL() -> URL? {
        if shouldUseRemotePromptGeneration(baseURL: promptGenerationURL) {
            return promptGenerationURL
        }
        if shouldUseRemotePromptGeneration(baseURL: endpointURL) {
            return endpointURL
        }
        return nil
    }

    private func shouldUseRemotePromptGeneration(baseURL: URL?) -> Bool {
        guard let baseURL else { return false }
        let url = baseURL.absoluteString.lowercased()
        return url.contains("workers.dev") && url.contains("agora-prompts-")
    }

    private struct GeneratedPrompt: Decodable {
        let time: Double
        let question: String
        let expectedAnswer: String
        let judgeScore: Double?
        let evidenceCount: Int?
        let passesQualityGates: Bool?

        enum CodingKeys: String, CodingKey {
            case time
            case question
            case expectedAnswer
            case expected_answer
            case scores
            case evidence
            case passesQualityGates
            case passes_quality_gates
        }

        private struct Scores: Decodable {
            let overall: Double?
        }

        private struct EvidenceItem: Decodable {
            let startSeconds: Double?
            let endSeconds: Double?
            let quote: String?

            enum CodingKeys: String, CodingKey {
                case startSeconds
                case endSeconds
                case quote
            }

            private enum AlternateCodingKeys: String, CodingKey {
                case start_seconds
                case end_seconds
            }

            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                let altContainer = try decoder.container(keyedBy: AlternateCodingKeys.self)

                let startPrimary = try container.decodeIfPresent(Double.self, forKey: .startSeconds)
                let startAlternate = try altContainer.decodeIfPresent(Double.self, forKey: .start_seconds)
                startSeconds = startPrimary ?? startAlternate

                let endPrimary = try container.decodeIfPresent(Double.self, forKey: .endSeconds)
                let endAlternate = try altContainer.decodeIfPresent(Double.self, forKey: .end_seconds)
                endSeconds = endPrimary ?? endAlternate

                quote = try container.decodeIfPresent(String.self, forKey: .quote)
            }
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            time = try container.decodeIfPresent(Double.self, forKey: .time) ?? 0
            question = try container.decodeIfPresent(String.self, forKey: .question) ?? ""
            let expectedCamel = try container.decodeIfPresent(String.self, forKey: .expectedAnswer)
            let expectedSnake = try container.decodeIfPresent(String.self, forKey: .expected_answer)
            expectedAnswer = expectedCamel ?? expectedSnake ?? ""
            let scores = try container.decodeIfPresent(Scores.self, forKey: .scores)
            judgeScore = scores?.overall
            let evidence = try container.decodeIfPresent([EvidenceItem].self, forKey: .evidence)
            evidenceCount = evidence?.count
            let passesCamel = try container.decodeIfPresent(Bool.self, forKey: .passesQualityGates)
            let passesSnake = try container.decodeIfPresent(Bool.self, forKey: .passes_quality_gates)
            passesQualityGates = passesCamel ?? passesSnake
        }
    }

    private struct GeneratedPromptEnvelope: Decodable {
        let prompts: [GeneratedPrompt]
    }

    private struct PromptContractRequest: Encodable {
        let contractVersion: String
        let transcript: String
        let duration: Double
        let count: Int
        let strategy: String
        let model: ModelPreferences
        let generation: GenerationConfig
        let quality: QualityConfig
        let output: OutputConfig

        enum CodingKeys: String, CodingKey {
            case contractVersion = "contract_version"
            case transcript
            case duration
            case count
            case strategy
            case model
            case generation
            case quality
            case output
        }
    }

    private struct ModelPreferences: Encodable {
        let mode: String
        let reasoningBudget: String
        let modelPreference: [String]

        enum CodingKeys: String, CodingKey {
            case mode = "analysis_mode"
            case reasoningBudget = "reasoning_budget"
            case modelPreference = "model_preference"
        }
    }

    private struct GenerationConfig: Encodable {
        let globalSynthesisRequired: Bool
        let candidateMultiplier: Int
        let pipeline: [String]
        let constraints: [String]

        enum CodingKeys: String, CodingKey {
            case globalSynthesisRequired = "global_synthesis_required"
            case candidateMultiplier = "candidate_multiplier"
            case pipeline
            case constraints
        }
    }

    private struct QualityConfig: Encodable {
        let questionQuality: String
        let questionStyle: String
        let answerGrounding: String
        let answerQuality: String
        let scoringRubric: [String]

        enum CodingKeys: String, CodingKey {
            case questionQuality = "question_quality"
            case questionStyle = "question_style"
            case answerGrounding = "answer_grounding"
            case answerQuality = "answer_quality"
            case scoringRubric = "scoring_rubric"
        }
    }

    private struct OutputConfig: Encodable {
        let includeCandidates: Bool
        let includeEvidence: Bool
        let includeScores: Bool
        let includeDiagnostics: Bool

        enum CodingKeys: String, CodingKey {
            case includeCandidates = "include_candidates"
            case includeEvidence = "include_evidence"
            case includeScores = "include_scores"
            case includeDiagnostics = "include_diagnostics"
        }
    }

    private func fetchFrontierPromptCandidates(
        baseURL: URL,
        transcript: String,
        audioDuration: Double,
        count: Int,
        strategy: String
    ) async -> [Prompt] {
        let promptsURL = baseURL.appendingPathComponent("prompts")
        do {
            var request = URLRequest(url: promptsURL)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.timeoutInterval = 120
            let payload = PromptContractRequest(
                contractVersion: "2026-02-15.prompts.v1",
                transcript: transcript,
                duration: audioDuration,
                count: max(3, min(30, count)),
                strategy: strategy,
                model: ModelPreferences(
                    mode: "frontier_max",
                    reasoningBudget: "max",
                    modelPreference: ["gpt-5", "o3", "o4-mini-high"]
                ),
                generation: GenerationConfig(
                    globalSynthesisRequired: true,
                    candidateMultiplier: 4,
                    pipeline: [
                        "full_episode_analysis",
                        "multi_pass_candidate_generation",
                        "judge_reranking",
                        "evidence_grounding",
                        "self_critique_revision"
                    ],
                    constraints: [
                        "No sponsor, ad, shoutout, promo, or housekeeping content",
                        "Questions must not be repetitive",
                        "Avoid generic summary questions",
                        "Prioritize questions that require synthesis across opening, middle, and closing sections",
                        "Each final answer must include cross-episode evidence"
                    ]
                ),
                quality: QualityConfig(
                    questionQuality: "frontier_expert",
                    questionStyle: "nuanced, non-generic, naturally-phrased, only-answerable-from-full-episode-context",
                    answerGrounding: "expected answers must be derived from podcast transcript content only",
                    answerQuality: "specific, high-signal, cites concrete claims/evidence/tradeoffs and connects earlier/later episode sections",
                    scoringRubric: [
                        "importance_to_listener",
                        "episode_specificity",
                        "cross_episode_synthesis",
                        "answerability_from_transcript",
                        "depth_and_non_genericity",
                        "factual_grounding"
                    ]
                ),
                output: OutputConfig(
                    includeCandidates: true,
                    includeEvidence: true,
                    includeScores: true,
                    includeDiagnostics: true
                )
            )
            request.httpBody = try JSONEncoder().encode(payload)

            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                return []
            }

            let decoded = decodeGeneratedPrompts(from: data)
            guard !decoded.isEmpty else { return [] }

            return decoded
                .filter { generated in
                    // Prefer backend outputs that passed quality gates when provided.
                    if let passed = generated.passesQualityGates {
                        return passed
                    }
                    return true
                }
                .map { generated in
                    let question = polishGeneratedQuestion(generated.question)
                    let backendAnswer = polishExpectedAnswerText(generated.expectedAnswer)
                    let transcriptAnswer = transcriptBackedExpectedAnswer(
                        for: question,
                        transcript: transcript,
                        fallback: backendAnswer
                    )
                    return Prompt(
                        id: UUID(),
                        timestampSeconds: min(max(generated.time, 0), audioDuration),
                        question: question,
                        expectedAnswer: transcriptAnswer,
                        leadTimeSeconds: 0
                    )
                }
                .filter {
                    !$0.question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
                    !$0.expectedAnswer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                }
        } catch {
            return []
        }
    }

    private func decodeGeneratedPrompts(from data: Data) -> [GeneratedPrompt] {
        if let direct = try? JSONDecoder().decode([GeneratedPrompt].self, from: data) {
            return direct
        }
        if let wrapped = try? JSONDecoder().decode(GeneratedPromptEnvelope.self, from: data) {
            return wrapped.prompts
        }

        // Fallback for envelopes like { "data": { "prompts": [...] } }.
        struct NestedEnvelope: Decodable {
            struct Inner: Decodable {
                let prompts: [GeneratedPrompt]
            }
            let data: Inner
        }
        if let nested = try? JSONDecoder().decode(NestedEnvelope.self, from: data) {
            return nested.data.prompts
        }
        return []
    }

    private func rankPromptCandidates(
        _ prompts: [Prompt],
        desiredCount: Int,
        audioDuration: Double,
        transcript: String
    ) -> [Prompt] {
        guard !prompts.isEmpty else { return [] }
        let target = max(1, desiredCount)
        let transcriptTokens = tokenize(transcript)

        struct RankedCandidate {
            let prompt: Prompt
            let score: Double
        }

        let ranked: [RankedCandidate] = deduplicatedPrompts(prompts).compactMap { raw in
            let question = polishGeneratedQuestion(raw.question)
            let answer = transcriptBackedExpectedAnswer(
                for: question,
                transcript: transcript,
                fallback: polishExpectedAnswerText(raw.expectedAnswer)
            )
            let isStrongLocalCandidate = isContentPromptCandidate(question: question, expectedAnswer: answer)
            let scopeSignal = episodeScopeQuestionSignal(question)
            let hasArcLanguage = answer.lowercased().contains("earlier in the episode") || answer.lowercased().contains("later in the episode")
            let grounding = transcriptGroundingScore(
                question: question,
                expectedAnswer: answer,
                transcriptTokens: transcriptTokens
            )
            let alignment = promptAnswerAlignmentScore(question: question, expectedAnswer: answer)
            guard !isTemplateHeavyQuestion(question) else { return nil }
            guard isStrongLocalCandidate || scopeSignal >= 0.18 || hasArcLanguage else { return nil }
            guard grounding >= 0.15 else { return nil }
            guard alignment >= 0.2 else { return nil }

            let ratio = min(max(raw.timestampSeconds / max(audioDuration, 1), 0), 1)
            let segmentIndex = Int(round(ratio * Double(max(target - 1, 0))))

            var score = promptPairQualityScore(
                question: question,
                expectedAnswer: answer,
                segmentIndex: segmentIndex,
                totalSegments: target
            )
            score += scopeSignal * 1.35
            score += grounding * 1.55
            score += alignment * 1.8
            if answer.lowercased().contains("earlier in the episode") { score += 0.08 }
            if answer.lowercased().contains("later in the episode") { score += 0.08 }

            return RankedCandidate(
                prompt: Prompt(
                    id: raw.id,
                    timestampSeconds: min(max(raw.timestampSeconds, 0), audioDuration),
                    question: question,
                    expectedAnswer: answer,
                    leadTimeSeconds: raw.leadTimeSeconds
                ),
                score: score
            )
        }

        let sorted = ranked.sorted { lhs, rhs in
            if abs(lhs.score - rhs.score) < 0.0001 {
                return lhs.prompt.timestampSeconds < rhs.prompt.timestampSeconds
            }
            return lhs.score > rhs.score
        }

        var selected: [Prompt] = []
        let minTimeGap = max(8, min(120, audioDuration / Double(max(target * 2, 1))))

        for candidate in sorted {
            if selected.count >= target { break }
            let isDistinct = selected.allSatisfy { existing in
                let timeGapOK = abs(existing.timestampSeconds - candidate.prompt.timestampSeconds) >= minTimeGap
                let questionSimilarity = tokenJaccardSimilarity(
                    tokenize(existing.question),
                    tokenize(candidate.prompt.question)
                )
                let answerSimilarity = tokenJaccardSimilarity(
                    tokenize(existing.expectedAnswer),
                    tokenize(candidate.prompt.expectedAnswer)
                )
                return timeGapOK && questionSimilarity < 0.72 && answerSimilarity < 0.78
            }
            if isDistinct {
                selected.append(candidate.prompt)
            }
        }

        if selected.count < target {
            for candidate in sorted where selected.count < target {
                let qKey = normalizedPromptText(candidate.prompt.question)
                if !selected.contains(where: { normalizedPromptText($0.question) == qKey }) {
                    selected.append(candidate.prompt)
                }
            }
        }

        return normalizePromptTiming(
            selected.sorted { $0.timestampSeconds < $1.timestampSeconds },
            audioDuration: audioDuration,
            desiredCount: target
        )
    }

    private func transcriptGroundingScore(
        question: String,
        expectedAnswer: String,
        transcriptTokens: Set<String>
    ) -> Double {
        guard !transcriptTokens.isEmpty else { return 0 }
        let candidateTokens = tokenize(question + " " + expectedAnswer)
        guard !candidateTokens.isEmpty else { return 0 }
        let overlap = candidateTokens.intersection(transcriptTokens).count
        return Double(overlap) / Double(max(candidateTokens.count, 1))
    }

    private func isTemplateHeavyQuestion(_ question: String) -> Bool {
        let lowered = normalizedPromptText(question)
        if lowered.isEmpty { return true }
        let templated = [
            "what is the strongest reason the speaker gives",
            "if the claim about",
            "what consequence tied to",
            "what unresolved issue around",
            "in this segment"
        ]
        return templated.contains { lowered.contains($0) }
    }

    private struct PromptGenerationContext {
        let keyPhrases: [String]
        let namedEntities: [String]
        let topicalTerms: [String]
        let openingAnchors: [String]
        let middleAnchors: [String]
        let closingAnchors: [String]

        static let empty = PromptGenerationContext(
            keyPhrases: [],
            namedEntities: [],
            topicalTerms: [],
            openingAnchors: [],
            middleAnchors: [],
            closingAnchors: []
        )
    }

    private func localGeneratePrompts(transcript: String, audioDuration: Double, desiredCount: Int) -> [Prompt] {
        enum Section {
            case opening
            case middle
            case closing
        }

        enum Signal: Hashable {
            case distinction
            case contradiction
            case evidence
            case caseStudy
            case method
            case worldview
            case psychology
            case historical
            case education
            case implication
            case uncertainty
        }

        struct Span {
            let index: Int
            let text: String
            let lowered: String
            let section: Section
            let time: Double
            let tokens: Set<String>
            let signals: Set<Signal>
            let score: Double
            let isHost: Bool
            let isGuest: Bool
        }

        struct Candidate {
            let prompt: Prompt
            let style: String
            let score: Double
        }

        let target = max(3, min(9, desiredCount))
        let effectiveDuration = resolvedDuration(audioDuration: audioDuration, transcript: transcript)
        let sentences = splitIntoSentences(transcript)
            .compactMap { raw -> (text: String, isHost: Bool, isGuest: Bool)? in
                var line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !line.isEmpty else { return nil }

                var isHost = false
                var isGuest = false
                if let match = line.range(of: #"^([A-Za-z0-9 ]{2,20}):\s*"#, options: .regularExpression) {
                    let speakerTag = String(line[match]).lowercased()
                    if speakerTag.contains("host") { isHost = true }
                    if speakerTag.contains("guest") { isGuest = true }
                    line.removeSubrange(match)
                }

                line = cleanTranscriptSentence(line)
                guard !line.isEmpty else { return nil }
                return (line, isHost, isGuest)
            }
            .filter {
                isSubstantiveSentence($0.text) &&
                !isSponsorOrShoutoutContent($0.text)
            }
        guard !sentences.isEmpty else { return [] }

        func sectionFor(index: Int, total: Int) -> Section {
            let ratio = Double(index) / Double(max(total - 1, 1))
            if ratio <= 0.33 { return .opening }
            if ratio >= 0.67 { return .closing }
            return .middle
        }

        func detectSignals(_ lowered: String) -> Set<Signal> {
            var out = Set<Signal>()
            if lowered.contains("different ways") || lowered.contains("distinguish") || lowered.contains("depends on your having") || lowered.contains("match the world") || lowered.contains("match each other") {
                out.insert(.distinction)
            }
            if lowered.contains("inconsistent") || lowered.contains("incompatible") || lowered.contains("contradict") || lowered.contains("cannot both") {
                out.insert(.contradiction)
            }
            if lowered.contains("evidence") || lowered.contains("prove") || lowered.contains("reason") || lowered.contains("because") || lowered.contains("therefore") {
                out.insert(.evidence)
            }
            if lowered.contains("example") || lowered.contains("scandal") || lowered.contains("case") || lowered.contains("selling organs") || lowered.contains("kidney") {
                out.insert(.caseStudy)
            }
            if lowered.contains("logic") || lowered.contains("argument") || lowered.contains("reasoning") || lowered.contains("core tool") {
                out.insert(.method)
            }
            if lowered.contains("metaphysics") || lowered.contains("science") || lowered.contains("kuhn") || lowered.contains("fundamentals") {
                out.insert(.worldview)
            }
            if lowered.contains("haidt") || lowered.contains("psychology") || lowered.contains("convince") || lowered.contains("find ways") {
                out.insert(.psychology)
            }
            if lowered.contains("victorian") || lowered.contains("mill") {
                out.insert(.historical)
            }
            if lowered.contains("education") || lowered.contains("isolated bits") || lowered.contains("fit together") || lowered.contains("inquiry") {
                out.insert(.education)
            }
            if lowered.contains("should") || lowered.contains("must") || lowered.contains("what's needed") || lowered.contains("next step") {
                out.insert(.implication)
            }
            if lowered.contains("might") || lowered.contains("uncertain") || lowered.contains("not always") || lowered.contains("can’t get agreement") {
                out.insert(.uncertainty)
            }
            return out
        }

        let topTerms = extractTopicalTerms(from: transcript).prefix(20).map { $0.lowercased() }
        let entities = extractNamedEntities(from: transcript)
            .filter {
                let blocked = Set(["What", "This", "That", "And", "But", "So", "One", "Guest", "Host"])
                return !blocked.contains($0)
            }

        var spans: [Span] = []
        spans.reserveCapacity(sentences.count)
        for (idx, item) in sentences.enumerated() {
            let sentence = item.text
            let lowered = normalizedPromptText(sentence)
            let tokens = tokenize(sentence)
            let signals = detectSignals(lowered)
            let section = sectionFor(index: idx, total: sentences.count)
            let ratio = Double(idx) / Double(max(sentences.count - 1, 1))
            let time = min(max(ratio * effectiveDuration, 0), effectiveDuration)

            var score = depthScore(for: sentence) * 0.45
            score += specificityScore(for: sentence) * 0.55
            score += interestingnessScore(for: sentence) * 0.55
            score += Double(signals.count) * 0.15
            if sentence.contains("?") { score += 0.18 }
            if lowered.contains("however") || lowered.contains("but") || lowered.contains("yet") { score += 0.16 }
            if item.isGuest { score += 0.28 }
            if item.isHost { score -= 0.28 }

            spans.append(
                Span(
                    index: idx,
                    text: sentence,
                    lowered: lowered,
                    section: section,
                    time: time,
                    tokens: tokens,
                    signals: signals,
                    score: score,
                    isHost: item.isHost,
                    isGuest: item.isGuest
                )
            )
        }

        func anchorTopic(from span: Span) -> String {
            let blocked = Set([
                "speaker", "episode", "argument", "point", "thing", "things", "people",
                "says", "said", "because", "therefore", "however", "this", "that",
                "example", "starting", "knowing", "using", "getting", "claim", "claims",
                "section", "discussion", "reasoning", "levels", "really", "understanding",
                "incompatible", "consistent", "inconsistency", "truth", "basic", "things"
            ])

            let localTerms = extractTopicalTerms(from: span.text).map { $0.lowercased() }
            if let local = localTerms.first(where: { !blocked.contains($0) && $0.count >= 4 }) {
                let concise = conciseTopicPhrase(local, maxWords: 2)
                if !concise.isEmpty { return concise }
            }

            if let term = topTerms.first(where: { span.lowered.contains($0) && !blocked.contains($0) && $0.count >= 4 }) {
                let concise = conciseTopicPhrase(term, maxWords: 3)
                if !concise.isEmpty { return concise }
            }

            if let entity = entities.first(where: { span.lowered.contains($0.lowercased()) }) {
                let concise = conciseTopicPhrase(entity, maxWords: 2)
                if !concise.isEmpty { return concise }
            }

            if let phrase = focusPhrase(from: span.text) {
                let concise = conciseTopicPhrase(phrase, maxWords: 2)
                if wordCount(concise) >= 2 { return concise }
            }

            let fallback = conciseTopicPhrase(safeAnchor(from: span.text), maxWords: 2)
            return fallback.isEmpty ? "the central claim" : fallback
        }

        func isWeakTopic(_ topic: String) -> Bool {
            let lowered = normalizedPromptText(topic)
            if lowered.isEmpty { return true }
            let blocked = Set([
                "think", "really", "universal", "levels", "understanding",
                "argument", "claim", "claims", "point", "discussion", "section",
                "reasoning", "thing", "things", "truth", "basic"
            ])
            if blocked.contains(lowered) { return true }
            if lowered.split(separator: " ").count == 1 && lowered.count < 5 { return true }
            return false
        }

        func supportSpans(for primary: Span, maxCount: Int = 2) -> [Span] {
            let scored = spans
                .filter { $0.index != primary.index }
                .map { candidate -> (Span, Double) in
                    let overlap = Double(primary.tokens.intersection(candidate.tokens).count)
                    let distance = Double(abs(primary.index - candidate.index)) / Double(max(spans.count, 1))
                    let sectionShift = primary.section == candidate.section ? 0.0 : 0.24
                    let signalComplement = primary.signals.intersection(candidate.signals).isEmpty ? 0.2 : 0.08
                    var score = (overlap * 0.22) + (distance * 0.45) + sectionShift + signalComplement + (candidate.score * 0.22)
                    if candidate.isHost { score -= 0.25 }
                    if primary.isGuest && candidate.isGuest { score += 0.12 }
                    return (candidate, score)
                }
                .sorted { $0.1 > $1.1 }
            return Array(scored.prefix(maxCount).map(\.0))
        }

        func buildAnswer(question: String, primary: Span, support: [Span]) -> String {
            func conciseClause(_ text: String) -> String {
                let cleaned = cleanTranscriptSentence(text)
                let words = cleaned.split(whereSeparator: { $0.isWhitespace || $0.isNewline })
                guard words.count > 34 else { return cleaned }
                let clipped = words.prefix(34).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
                if clipped.isEmpty { return cleaned }
                if clipped.hasSuffix(".") || clipped.hasSuffix("?") || clipped.hasSuffix("!") { return clipped }
                return clipped + "."
            }

            let questionTokens = meaningfulTokens(from: question)
            let primaryTokens = meaningfulTokens(from: primary.text)

            func supportAlignmentScore(_ span: Span) -> Double {
                let supportTokens = meaningfulTokens(from: span.text)
                guard !supportTokens.isEmpty else { return 0 }

                let questionOverlap = questionTokens.isEmpty
                    ? 0.0
                    : tokenJaccardSimilarity(questionTokens, supportTokens)
                let primaryOverlap = tokenJaccardSimilarity(primaryTokens, supportTokens)
                let signalOverlap = primary.signals.intersection(span.signals).isEmpty ? 0.0 : 0.12
                return (questionOverlap * 0.7) + (primaryOverlap * 0.9) + signalOverlap
            }

            var parts: [String] = []
            var seen = Set<String>()
            let primaryClause = conciseClause(primary.text)
            let primaryKey = normalizedPromptText(primaryClause)
            if !primaryKey.isEmpty {
                parts.append(primaryClause)
                seen.insert(primaryKey)
            }

            let alignedSupport = support
                .sorted { supportAlignmentScore($0) > supportAlignmentScore($1) }
                .filter { supportAlignmentScore($0) >= 0.18 }

            for s in alignedSupport.prefix(2) {
                let clause = conciseClause(s.text)
                let key = normalizedPromptText(clause)
                if key.isEmpty || seen.contains(key) { continue }
                if s.index < primary.index {
                    parts.append("Earlier in the episode, \(clause)")
                } else {
                    parts.append("Later in the episode, \(clause)")
                }
                seen.insert(key)
            }
            return polishExpectedAnswerText(parts.joined(separator: " "))
        }

        var candidates: [Candidate] = []
        var seenQuestionKeys = Set<String>()

        func addCandidate(question rawQuestion: String, primary: Span, support: [Span], style: String) {
            let question = polishGeneratedQuestion(rawQuestion)
            let expected = buildAnswer(question: question, primary: primary, support: support)
            guard !question.isEmpty, !expected.isEmpty else { return }
            guard !isOverlyGenericQuestion(question), !isOverlyGenericSummary(expected) else { return }

            let alignment = promptAnswerAlignmentScore(question: question, expectedAnswer: expected)
            guard alignment >= 0.12 else { return }

            let qKey = normalizedPromptText(question)
            guard !qKey.isEmpty, !seenQuestionKeys.contains(qKey) else { return }
            seenQuestionKeys.insert(qKey)

            let segmentIndex = Int(round((primary.time / max(effectiveDuration, 1)) * Double(max(target - 1, 0))))
            var score = promptPairQualityScore(
                question: question,
                expectedAnswer: expected,
                segmentIndex: segmentIndex,
                totalSegments: target
            )
            score += primary.score * 0.2
            score += Double(primary.signals.count) * 0.08
            if !support.isEmpty { score += 0.15 }
            score += alignment * 1.25

            let prompt = Prompt(
                id: UUID(),
                timestampSeconds: primary.time,
                question: question,
                expectedAnswer: expected,
                leadTimeSeconds: 0
            )
            candidates.append(Candidate(prompt: prompt, style: style, score: score))
        }

        let rankedSpans = spans.sorted { $0.score > $1.score }
        let primaryPool = {
            let guestOrNeutral = rankedSpans.filter { !$0.isHost }
            return guestOrNeutral.isEmpty ? rankedSpans : guestOrNeutral
        }()
        let openingAnchor = primaryPool.first { $0.section == .opening }
        let middleAnchor = primaryPool.first { $0.section == .middle }
        let closingAnchor = primaryPool.first { $0.section == .closing }

        func keywordMatches(_ span: Span, _ keywords: [String]) -> Int {
            keywords.reduce(0) { $0 + (span.lowered.contains($1) ? 1 : 0) }
        }

        func bestSpan(
            preferredSignals: Set<Signal>,
            section: Section? = nil,
            keywords: [String] = []
        ) -> Span? {
            primaryPool
                .filter { section == nil || $0.section == section }
                .map { span -> (Span, Double) in
                    var score = span.score
                    if !preferredSignals.isEmpty {
                        let hits = span.signals.intersection(preferredSignals).count
                        score += Double(hits) * 0.55
                        if hits == 0 { score -= 0.4 }
                    }
                    score += Double(keywordMatches(span, keywords)) * 0.25
                    if span.isHost { score -= 0.35 }
                    return (span, score)
                }
                .max { $0.1 < $1.1 }?.0
        }

        let distinctionSpan = bestSpan(
            preferredSignals: [.distinction, .method],
            section: .opening,
            keywords: ["different ways", "match the world", "match each other", "contradict"]
        )
        let practicalSpan = bestSpan(
            preferredSignals: [.method, .contradiction, .uncertainty],
            section: .middle,
            keywords: ["meta", "day to day", "stratosphere", "agreement", "basic levels"]
        )
        let contradictionSpan = bestSpan(
            preferredSignals: [.contradiction, .caseStudy],
            section: .middle,
            keywords: ["organ", "kidney", "autonomy", "consent", "payment", "illegal"]
        )
        let psychologySpan = bestSpan(
            preferredSignals: [.psychology, .contradiction],
            section: .middle,
            keywords: ["haidt", "psychology", "find ways", "incompatible"]
        )
        let worldviewSpan = bestSpan(
            preferredSignals: [.worldview, .historical, .method],
            keywords: ["metaphysics", "science", "mill", "victorian", "kuhn"]
        )
        let educationSpan = bestSpan(
            preferredSignals: [.education, .implication],
            section: .closing,
            keywords: ["education", "fit together", "isolated", "inquiry", "next step"]
        )
        let logicBalanceSpan = bestSpan(
            preferredSignals: [.method, .worldview],
            keywords: ["core tool", "logic", "science", "metaphysics"]
        )

        if let distinctionSpan {
            addCandidate(
                question: "How does the opening distinction become the framework for the rest of the episode’s argument?",
                primary: distinctionSpan,
                support: [practicalSpan, logicBalanceSpan].compactMap { $0 },
                style: "distinction"
            )
        }

        if let practicalSpan {
            addCandidate(
                question: "Why does the speaker argue that starting from concrete disagreements is more productive than starting at a high-theory level?",
                primary: practicalSpan,
                support: [distinctionSpan, contradictionSpan].compactMap { $0 },
                style: "method"
            )
        }

        if let contradictionSpan {
            let topic = anchorTopic(from: contradictionSpan)
            let contradictionQuestion: String
            if isWeakTopic(topic) {
                contradictionQuestion = "What exact inconsistency does the main case expose between accepted principles and policy conclusions?"
            } else {
                contradictionQuestion = "What exact inconsistency does the discussion of \(topic) expose between accepted principles and policy conclusions?"
            }
            addCandidate(
                question: contradictionQuestion,
                primary: contradictionSpan,
                support: [practicalSpan, psychologySpan].compactMap { $0 },
                style: "contradiction"
            )
        }

        if let psychologySpan {
            addCandidate(
                question: "What role does the psychology move play in explaining why exposing contradictions often fails to change people’s positions?",
                primary: psychologySpan,
                support: [contradictionSpan, distinctionSpan].compactMap { $0 },
                style: "psychology"
            )
        }

        if let worldviewSpan {
            addCandidate(
                question: "How does the episode show that two positions can be internally logical yet still conflict at the level of worldview assumptions?",
                primary: worldviewSpan,
                support: [logicBalanceSpan, practicalSpan].compactMap { $0 },
                style: "worldview"
            )
        }

        if let logicBalanceSpan {
            addCandidate(
                question: "What balance does the speaker propose between logical analysis, metaphysical assumptions, and scientific revision?",
                primary: logicBalanceSpan,
                support: [worldviewSpan, distinctionSpan].compactMap { $0 },
                style: "method"
            )
        }

        if let educationSpan {
            addCandidate(
                question: "What is the educational consequence of learning isolated facts without understanding how arguments fit together?",
                primary: educationSpan,
                support: [distinctionSpan, logicBalanceSpan].compactMap { $0 },
                style: "implication"
            )
        }

        if let openingAnchor, let closingAnchor {
            addCandidate(
                question: "Across the full episode, how does the argument move from its opening framing to its closing position, and what causes that shift?",
                primary: closingAnchor,
                support: [openingAnchor, middleAnchor].compactMap { $0 },
                style: "arc_synthesis"
            )
        }

        // Adaptive fallback: build additional nuanced prompts from strong spans.
        for span in primaryPool.prefix(min(24, primaryPool.count)) where candidates.count < target * 4 {
            let topic = anchorTopic(from: span)
            let support = supportSpans(for: span, maxCount: 2)
            let fallbackTemplates: [String]
            if isWeakTopic(topic) {
                fallbackTemplates = [
                    "Which assumption in this section is later pressure-tested by another part of the episode?",
                    "How does this section complicate an earlier claim rather than merely repeat it?",
                    "What would a careful listener infer only after connecting this moment to the full episode arc?"
                ]
            } else {
                fallbackTemplates = [
                    "Which assumption behind the claim about \(topic) is later pressure-tested by another part of the episode?",
                    "How does this section on \(topic) complicate an earlier claim rather than merely repeat it?",
                    "What would a careful listener infer about \(topic) only after connecting this moment to the full episode arc?"
                ]
            }
            let chosen = fallbackTemplates[span.index % fallbackTemplates.count]
            addCandidate(question: chosen, primary: span, support: support, style: "adaptive_fallback")
        }

        let rankedCandidates = candidates.sorted {
            if abs($0.score - $1.score) < 0.0001 {
                return $0.prompt.timestampSeconds < $1.prompt.timestampSeconds
            }
            return $0.score > $1.score
        }

        var selected: [Candidate] = []
        var styleCounts: [String: Int] = [:]
        let priorityStyles = [
            "distinction",
            "contradiction",
            "worldview",
            "method",
            "psychology",
            "implication",
            "arc_synthesis"
        ]

        func isDistinct(_ candidate: Candidate, against existing: [Candidate]) -> Bool {
            existing.allSatisfy { prev in
                let qSimilarity = tokenJaccardSimilarity(
                    tokenize(prev.prompt.question),
                    tokenize(candidate.prompt.question)
                )
                let aSimilarity = tokenJaccardSimilarity(
                    tokenize(prev.prompt.expectedAnswer),
                    tokenize(candidate.prompt.expectedAnswer)
                )
                return qSimilarity < 0.70 && aSimilarity < 0.84
            }
        }

        // Coverage pass: guarantee style diversity first.
        for style in priorityStyles where selected.count < target {
            if let candidate = rankedCandidates.first(where: { $0.style == style && isDistinct($0, against: selected) }) {
                selected.append(candidate)
                styleCounts[candidate.style, default: 0] += 1
            }
        }

        // Fill pass: add strongest remaining candidates.
        for candidate in rankedCandidates where selected.count < target {
            if styleCounts[candidate.style, default: 0] >= 2 && selected.count < target - 1 { continue }
            if !isDistinct(candidate, against: selected) { continue }
            selected.append(candidate)
            styleCounts[candidate.style, default: 0] += 1
        }

        if selected.count < target {
            for candidate in rankedCandidates where selected.count < target {
                let qKey = normalizedPromptText(candidate.prompt.question)
                if selected.contains(where: { normalizedPromptText($0.prompt.question) == qKey }) {
                    continue
                }
                selected.append(candidate)
            }
        }

        let prompts = selected.map(\.prompt)
        return normalizePromptTiming(
            deduplicatedPrompts(prompts).sorted { $0.timestampSeconds < $1.timestampSeconds },
            audioDuration: effectiveDuration,
            desiredCount: target
        )
    }

    private func normalizePromptTiming(_ prompts: [Prompt], audioDuration: Double, desiredCount: Int) -> [Prompt] {
        let unique = deduplicatedPrompts(prompts)
        guard !unique.isEmpty else { return [] }
        let sorted = unique.sorted { $0.timestampSeconds < $1.timestampSeconds }
        let count = min(max(desiredCount, 1), sorted.count)
        guard audioDuration.isFinite, audioDuration > 10 else {
            return Array(sorted.prefix(count))
        }

        var adjusted: [Prompt] = []
        for i in 0..<count {
            let p = sorted[i]
            let t = min(max(p.timestampSeconds, 0), audioDuration)
            adjusted.append(
                Prompt(
                    id: p.id,
                    timestampSeconds: t,
                    question: polishGeneratedQuestion(p.question),
                    expectedAnswer: polishExpectedAnswerText(p.expectedAnswer),
                    leadTimeSeconds: p.leadTimeSeconds
                )
            )
        }
        return adjusted
    }

    private func ensurePromptCount(_ prompts: [Prompt], transcript: String, audioDuration: Double, desiredCount: Int) -> [Prompt] {
        let target = max(3, min(9, desiredCount))
        var prepared = normalizePromptTiming(prompts, audioDuration: audioDuration, desiredCount: target)
        if prepared.count >= target {
            return Array(prepared.prefix(target))
        }

        let effectiveDuration = resolvedDuration(audioDuration: audioDuration, transcript: transcript)
        // First, try a second high-fidelity local pass with a wider candidate pool.
        let expanded = normalizePromptTiming(
            localGeneratePrompts(
                transcript: transcript,
                audioDuration: effectiveDuration,
                desiredCount: min(9, max(target + 2, target * 2))
            ),
            audioDuration: effectiveDuration,
            desiredCount: min(9, max(target + 2, target * 2))
        )

        var seenQuestionKeys = Set(prepared.map { normalizedPromptText($0.question) })
        var seenAnswerKeys = Set(prepared.map { normalizedPromptText($0.expectedAnswer) })

        for prompt in expanded where prepared.count < target {
            let qKey = normalizedPromptText(prompt.question)
            let aKey = normalizedPromptText(prompt.expectedAnswer)
            guard !qKey.isEmpty, !aKey.isEmpty else { continue }
            if seenQuestionKeys.contains(qKey) || seenAnswerKeys.contains(aKey) { continue }
            prepared.append(prompt)
            seenQuestionKeys.insert(qKey)
            seenAnswerKeys.insert(aKey)
        }

        if prepared.count >= target {
            return Array(normalizePromptTiming(prepared, audioDuration: effectiveDuration, desiredCount: target).prefix(target))
        }

        // Final pass: ask generator for max pool and merge the strongest unique prompts.
        let maxPool = normalizePromptTiming(
            localGeneratePrompts(
                transcript: transcript,
                audioDuration: effectiveDuration,
                desiredCount: 9
            ),
            audioDuration: effectiveDuration,
            desiredCount: 9
        )
        for prompt in maxPool where prepared.count < target {
            let qKey = normalizedPromptText(prompt.question)
            let aKey = normalizedPromptText(prompt.expectedAnswer)
            guard !qKey.isEmpty, !aKey.isEmpty else { continue }
            if seenQuestionKeys.contains(qKey) || seenAnswerKeys.contains(aKey) { continue }
            prepared.append(prompt)
            seenQuestionKeys.insert(qKey)
            seenAnswerKeys.insert(aKey)
        }

        return Array(normalizePromptTiming(prepared, audioDuration: effectiveDuration, desiredCount: target).prefix(target))
    }

    private func resolvedDuration(audioDuration: Double, transcript: String) -> Double {
        if audioDuration.isFinite, audioDuration > 10 {
            return audioDuration
        }

        // Estimate duration if player metadata isn't available yet.
        // 2.6 words/sec ~= 156 wpm (typical podcast speech pace).
        let wordCount = transcript.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count
        let estimated = Double(wordCount) / 2.6
        return max(180, min(86_400, estimated))
    }

    private func deepQuestion(for expectedAnswer: String, segmentIndex: Int, totalSegments: Int) -> String {
        var noOpUsed = Set<String>()
        return deepQuestion(
            for: expectedAnswer,
            segmentIndex: segmentIndex,
            totalSegments: totalSegments,
            context: .empty,
            usedQuestionKeys: &noOpUsed
        )
    }

    private func deepQuestion(
        for expectedAnswer: String,
        segmentIndex: Int,
        totalSegments: Int,
        context: PromptGenerationContext,
        usedQuestionKeys: inout Set<String>
    ) -> String {
        let claim = conciseTopicPhrase(
            claimClause(from: expectedAnswer) ?? "the key point in this segment is correct",
            maxWords: 16
        )
        let anchors = anchorCandidates(for: expectedAnswer, context: context)
        let primaryAnchor = anchors.first ?? safeAnchor(from: expectedAnswer)
        let secondaryAnchor = anchors.dropFirst().first
            ?? context.keyPhrases.first
            ?? context.namedEntities.first
            ?? context.topicalTerms.first
            ?? "the broader argument"
        let openingAnchor = context.openingAnchors.first
            ?? context.keyPhrases.first
            ?? primaryAnchor
        let middleAnchor = context.middleAnchors.first
            ?? secondaryAnchor
        let closingAnchor = context.closingAnchors.first
            ?? context.keyPhrases.dropFirst().first
            ?? secondaryAnchor
        let nuance = nuanceSignalQuestion(for: expectedAnswer, anchor: primaryAnchor)
        let detail = concreteDetail(from: expectedAnswer)

        var candidates: [String] = []
        if totalSegments <= 1 {
            candidates = [
                "What distinction does the speaker draw around \(primaryAnchor), and how does that distinction define the larger argument?",
                "How does the claim that \(claim) depend on a contrast with \(secondaryAnchor), rather than a standalone assertion?",
                "How does the episode move from its opening framing of \(openingAnchor) to its closing position on \(closingAnchor), and what exact tension drives that shift?",
                nuance
            ]
        } else if segmentIndex <= 0 {
            candidates = [
                "What assumption is the speaker asking listeners to accept first about \(primaryAnchor), and why is that assumption load-bearing later?",
                "Which conceptual distinction introduced early about \(primaryAnchor) becomes the framework for the rest of the episode?",
                "Which detail here most clearly launches the argument that \(claim), and what later section tests it?",
                "What thread introduced here about \(openingAnchor) gets reframed by the end when \(closingAnchor) comes into focus?"
            ]
        } else if segmentIndex >= totalSegments - 1 {
            candidates = [
                "Which earlier claim about \(openingAnchor) does this ending effectively revise, and why?",
                "What practical conclusion follows only after combining the episode's treatment of \(primaryAnchor) and \(closingAnchor)?",
                "Which unresolved inconsistency around \(primaryAnchor) remains even after the speaker's conclusion?",
                "What would a listener misunderstand if they heard only this ending and missed the opening setup?"
            ]
        } else {
            let rotating = [
                "How does this segment turn the argument about \(primaryAnchor) from description into a real tradeoff?",
                "Which evidence in this section most strengthens or weakens the claim that \(claim), and why?",
                "Where does the reasoning about \(primaryAnchor) expose an internal inconsistency in the position being criticized?",
                "How does this section connect \(primaryAnchor) to the episode's larger point about \(secondaryAnchor)?",
                "What value conflict makes this claim about \(primaryAnchor) more than a factual dispute?",
                "Which consequence of the argument about \(primaryAnchor) is easiest for listeners to underestimate?",
                "How does this midpoint treatment of \(middleAnchor) mediate the tension between the opening emphasis on \(openingAnchor) and the ending emphasis on \(closingAnchor)?"
            ]
            if !rotating.isEmpty {
                let base = segmentIndex % rotating.count
                candidates = Array(rotating[base...] + rotating[..<base])
            }
        }

        if let detail, !detail.isEmpty {
            candidates.append("What does the detail \"\(detail)\" reveal about how the speaker wants listeners to interpret \(primaryAnchor)?")
            candidates.append("How should a careful listener test the claim around \"\(detail)\" before accepting the argument about \(primaryAnchor)?")
        }
        if normalizedPromptText(secondaryAnchor) != normalizedPromptText(primaryAnchor) {
            candidates.append("How does the point about \(primaryAnchor) reshape the episode's stance on \(secondaryAnchor)?")
        }
        candidates.append("Across the full episode arc, where does the speaker's stance move from \(openingAnchor) toward \(closingAnchor), and what drives that change?")
        candidates.append("What connection between the opening concern about \(openingAnchor) and the later claim about \(closingAnchor) would a casual listener likely miss?")
        candidates.append(nuance)
        candidates.append("What hidden assumption under the claim about \(primaryAnchor) must hold for the speaker's argument to work?")

        for candidate in candidates {
            let cleaned = polishGeneratedQuestion(candidate)
            let key = normalizedPromptText(cleaned)
            guard !key.isEmpty else { continue }
            if usedQuestionKeys.insert(key).inserted {
                return cleaned
            }
        }

        let fallback = polishGeneratedQuestion("Which exact claim about \(primaryAnchor) becomes unstable once the episode's later constraints are applied?")
        usedQuestionKeys.insert(normalizedPromptText(fallback))
        return fallback
    }

    private func buildPromptGenerationContext(transcript: String) -> PromptGenerationContext {
        let substantive = splitIntoSentences(transcript)
            .map(cleanTranscriptSentence)
            .filter { isSubstantiveSentence($0) }
        guard !substantive.isEmpty else { return .empty }

        let phrases = extractKeyPhrases(from: substantive)
        let entities = extractNamedEntities(from: transcript)
        let terms = extractTopicalTerms(from: transcript)

        let count = substantive.count
        let openingEnd = max(1, count / 3)
        let middleStart = openingEnd
        let middleEnd = max(middleStart + 1, (count * 2) / 3)
        let opening = Array(substantive.prefix(openingEnd))
        let middle = Array(substantive[middleStart..<min(middleEnd, count)])
        let closing = Array(substantive.suffix(max(1, count - min(middleEnd, count))))

        return PromptGenerationContext(
            keyPhrases: Array(phrases.prefix(12)),
            namedEntities: Array(entities.prefix(12)),
            topicalTerms: Array(terms.prefix(16)),
            openingAnchors: extractSectionAnchors(from: opening, limit: 6),
            middleAnchors: extractSectionAnchors(from: middle, limit: 6),
            closingAnchors: extractSectionAnchors(from: closing, limit: 6)
        )
    }

    private func extractSectionAnchors(from sentences: [String], limit: Int) -> [String] {
        guard !sentences.isEmpty else { return [] }
        var counts: [String: Int] = [:]
        for sentence in sentences {
            guard let phrase = focusPhrase(from: sentence) else { continue }
            let cleaned = conciseTopicPhrase(phrase, maxWords: 7)
            guard wordCount(cleaned) >= 2 else { continue }
            counts[cleaned, default: 0] += 1
        }
        return counts
            .sorted { lhs, rhs in
                if lhs.value == rhs.value {
                    return lhs.key.count > rhs.key.count
                }
                return lhs.value > rhs.value
            }
            .prefix(max(1, limit))
            .map(\.key)
    }

    private func anchorCandidates(for expectedAnswer: String, context: PromptGenerationContext) -> [String] {
        var results: [String] = []
        var seen = Set<String>()
        let loweredAnswer = expectedAnswer.lowercased()

        func append(_ raw: String?) {
            guard let raw else { return }
            let normalized = conciseTopicPhrase(raw, maxWords: 8)
            guard wordCount(normalized) >= 1 else { return }
            let key = normalizedPromptText(normalized)
            guard !key.isEmpty, !seen.contains(key) else { return }
            seen.insert(key)
            results.append(normalized)
        }

        append(focusPhrase(from: expectedAnswer))
        if let clause = claimClause(from: expectedAnswer) {
            append(String(clause.split(separator: " ").prefix(8).joined(separator: " ")))
        }

        for entity in context.namedEntities where loweredAnswer.contains(entity.lowercased()) {
            append(entity)
        }
        for phrase in context.keyPhrases where loweredAnswer.contains(phrase.lowercased()) {
            append(phrase)
        }
        for term in context.topicalTerms where loweredAnswer.contains(term) {
            append(term)
        }

        if results.count < 3 {
            context.keyPhrases.prefix(5).forEach { append($0) }
            context.namedEntities.prefix(5).forEach { append($0) }
            context.topicalTerms.prefix(5).forEach { append($0) }
        }

        return Array(results.prefix(6))
    }

    private func concreteDetail(from text: String) -> String? {
        if let quotedRange = text.range(of: "\"([^\"]{4,80})\"", options: .regularExpression) {
            let raw = String(text[quotedRange])
                .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let detail = conciseTopicPhrase(raw, maxWords: 10)
            if wordCount(detail) >= 2 { return detail }
        }

        if let numericRange = text.range(
            of: "\\b(?:[A-Za-z]+\\s+){0,2}\\d+(?:\\.\\d+)?%?(?:\\s+[A-Za-z]+){0,3}\\b",
            options: .regularExpression
        ) {
            let detail = conciseTopicPhrase(String(text[numericRange]), maxWords: 8)
            if wordCount(detail) >= 1 { return detail }
        }

        if let entity = extractNamedEntities(from: text).first {
            let detail = conciseTopicPhrase(entity, maxWords: 6)
            if wordCount(detail) >= 1 { return detail }
        }

        return nil
    }

    private func extractKeyPhrases(from sentences: [String]) -> [String] {
        var counts: [String: Int] = [:]
        for sentence in sentences {
            guard let phrase = focusPhrase(from: sentence) else { continue }
            let cleaned = conciseTopicPhrase(phrase, maxWords: 7)
            guard wordCount(cleaned) >= 2 else { continue }
            counts[cleaned, default: 0] += 1
        }
        return counts
            .sorted { lhs, rhs in
                if lhs.value == rhs.value {
                    return wordCount(lhs.key) > wordCount(rhs.key)
                }
                return lhs.value > rhs.value
            }
            .map(\.key)
    }

    private func extractNamedEntities(from text: String) -> [String] {
        guard !text.isEmpty else { return [] }
        guard let regex = try? NSRegularExpression(pattern: "\\b([A-Z][a-z]+(?:\\s+[A-Z][a-z]+){0,2})\\b") else {
            return []
        }
        let nsRange = NSRange(text.startIndex..<text.endIndex, in: text)
        let blocked = Set([
            "the", "this", "that", "these", "those", "and", "but", "because",
            "i", "we", "you", "he", "she", "they", "it", "episode", "podcast",
            "speaker", "segment", "section", "today", "tomorrow", "yesterday"
        ])
        var counts: [String: Int] = [:]
        for match in regex.matches(in: text, range: nsRange) {
            guard let range = Range(match.range(at: 1), in: text) else { continue }
            let raw = String(text[range]).trimmingCharacters(in: .whitespacesAndNewlines)
            let candidate = conciseTopicPhrase(raw, maxWords: 4)
            guard !candidate.isEmpty else { continue }
            let lowered = candidate.lowercased()
            guard !blocked.contains(lowered) else { continue }
            if wordCount(candidate) == 1 && candidate.count < 4 { continue }
            counts[candidate, default: 0] += 1
        }
        return counts
            .sorted { lhs, rhs in
                if lhs.value == rhs.value { return lhs.key.count > rhs.key.count }
                return lhs.value > rhs.value
            }
            .map(\.key)
    }

    private func extractTopicalTerms(from text: String) -> [String] {
        let lowered = text.lowercased()
        guard let regex = try? NSRegularExpression(pattern: "\\b[a-z][a-z'-]{3,}\\b") else {
            return []
        }
        let nsRange = NSRange(lowered.startIndex..<lowered.endIndex, in: lowered)
        let matches = regex.matches(in: lowered, range: nsRange).compactMap { match -> String? in
            guard let range = Range(match.range, in: lowered) else { return nil }
            return String(lowered[range])
        }
        guard !matches.isEmpty else { return [] }

        let stopwords = Set([
            "about", "after", "again", "against", "almost", "along", "also", "although",
            "always", "among", "because", "before", "between", "could", "every", "first",
            "from", "have", "having", "into", "just", "like", "many", "might", "more",
            "most", "much", "must", "only", "other", "over", "podcast", "episode",
            "section", "segment", "speaker", "their", "there", "these", "those", "through",
            "under", "until", "very", "what", "when", "where", "which", "while", "with",
            "would", "your", "this", "that", "they", "them", "been", "were", "will", "should",
            "said", "says", "here", "then", "than", "into", "onto", "across", "around"
        ])

        var counts: [String: Int] = [:]
        for token in matches {
            let trimmed = token.trimmingCharacters(in: .punctuationCharacters)
            guard !trimmed.isEmpty else { continue }
            guard !stopwords.contains(trimmed) else { continue }
            counts[trimmed, default: 0] += 1
        }

        let hasRepeat = counts.values.contains { $0 >= 2 }
        let threshold = hasRepeat ? 2 : 1
        return counts
            .filter { $0.value >= threshold }
            .sorted { lhs, rhs in
                if lhs.value == rhs.value { return lhs.key.count > rhs.key.count }
                return lhs.value > rhs.value
            }
            .map(\.key)
    }

    private func conciseTopicPhrase(_ phrase: String, maxWords: Int) -> String {
        var cleaned = phrase
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'“”`"))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return "" }

        var words = cleaned.split(separator: " ").map {
            $0.trimmingCharacters(in: .punctuationCharacters)
        }.filter { !$0.isEmpty }
        guard !words.isEmpty else { return "" }

        let stop = Set([
            "the", "a", "an", "this", "that", "these", "those", "and", "but", "or",
            "so", "then", "because", "however", "well", "also"
        ])
        while let first = words.first, stop.contains(first.lowercased()), words.count > 2 {
            words.removeFirst()
        }
        while let last = words.last, stop.contains(last.lowercased()), words.count > 2 {
            words.removeLast()
        }

        cleaned = words.prefix(max(1, maxWords)).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned
    }

    private func focusPhrase(from sentence: String) -> String? {
        let normalized = sentence
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        guard !normalized.isEmpty else { return nil }
        guard !isSponsorOrShoutoutContent(normalized) else { return nil }

        let firstSentence = splitIntoSentences(normalized).first ?? normalized
        let rawWords = firstSentence.split(separator: " ").map { token in
            token.trimmingCharacters(in: .punctuationCharacters)
        }.filter { !$0.isEmpty }
        guard rawWords.count >= 3 else { return nil }

        let leadingStopwords = Set([
            "and", "but", "so", "then", "because", "however", "well", "also", "that", "this"
        ])
        let trailingStopwords = Set(["and", "but", "or", "so", "then", "because", "that"])

        var words = rawWords
        while let first = words.first, leadingStopwords.contains(first.lowercased()), words.count > 4 {
            words.removeFirst()
        }
        while let last = words.last, trailingStopwords.contains(last.lowercased()), words.count > 4 {
            words.removeLast()
        }

        let phrase = words.prefix(8).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return phrase.isEmpty ? nil : phrase
    }

    private func claimClause(from expectedAnswer: String) -> String? {
        let firstSentenceRaw = splitIntoSentences(expectedAnswer).first ?? expectedAnswer
        var cleaned = cleanTranscriptSentence(firstSentenceRaw)
        cleaned = cleaned.replacingOccurrences(of: "[“”\"']", with: "", options: .regularExpression)
        cleaned = cleaned.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return nil }

        var words = cleaned.split(separator: " ").map(String.init)
        guard words.count >= 4 else { return nil }

        let leadIns = Set(["and", "but", "so", "because", "then", "also", "well", "however"])
        while let first = words.first, leadIns.contains(first.lowercased()), words.count > 5 {
            words.removeFirst()
        }

        let result = words.prefix(18).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard result.split(separator: " ").count >= 4 else { return nil }
        return result
    }

    private func safeAnchor(from expectedAnswer: String) -> String {
        if let phrase = focusPhrase(from: expectedAnswer), wordCount(phrase) >= 2 {
            return phrase
        }
        if let clause = claimClause(from: expectedAnswer) {
            let short = clause.split(separator: " ").prefix(6).joined(separator: " ")
            if wordCount(short) >= 2 { return short }
        }
        return "this argument"
    }

    private func nuanceSignalQuestion(for expectedAnswer: String, anchor: String) -> String {
        let lowered = expectedAnswer.lowercased()
        if expectedAnswer.contains("?") {
            return "How does the speaker answer the question they raise about \(anchor)?"
        }
        if lowered.contains("evidence") || lowered.contains("data") || lowered.contains("study") || lowered.contains("research") {
            return "Which evidence about \(anchor) is strongest here, and what uncertainty remains?"
        }
        if lowered.contains("risk") || lowered.contains("tradeoff") || lowered.contains("cost") || lowered.contains("benefit") {
            return "Which tradeoff around \(anchor) is unavoidable here, and which part is framing?"
        }
        if lowered.contains("responsibility") || lowered.contains("duty") || lowered.contains("obligation") {
            return "What responsibility around \(anchor) is implied here, and who carries it?"
        }
        if lowered.contains("policy") || lowered.contains("law") || lowered.contains("system") || lowered.contains("institution") {
            return "Which system incentive does this argument about \(anchor) reveal most clearly?"
        }
        if lowered.contains("ethic") || lowered.contains("moral") || lowered.contains("justice") {
            return "What moral tension around \(anchor) is this section asking the listener to hold?"
        }
        if lowered.contains("because") || lowered.contains("therefore") || lowered.contains("so that") {
            return "Which step in the reasoning about \(anchor) is strongest, and which step is most vulnerable?"
        }
        return "What nuance about \(anchor) prevents a simplistic reading of this segment?"
    }

    private func normalizeQuestion(_ question: String) -> String {
        var cleaned = question
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\\?+", with: "?", options: .regularExpression)
            .replacingOccurrences(of: "^[A-Za-z ]+check-in:\\s*", with: "", options: [.regularExpression, .caseInsensitive])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        cleaned = cleaned.replacingOccurrences(of: "?.", with: "?", options: .literal)
        cleaned = cleaned.replacingOccurrences(of: ".?", with: "?", options: .literal)
        cleaned = cleaned.replacingOccurrences(of: "\\bthat that\\b", with: "that", options: .regularExpression)
        cleaned = cleaned.replacingOccurrences(of: "\\bthe the\\b", with: "the", options: .regularExpression)
        if !cleaned.hasSuffix("?") {
            cleaned.append("?")
        }
        return cleaned
    }

    private func polishGeneratedQuestion(_ question: String) -> String {
        let normalized = normalizeQuestion(question)
        var cleaned = normalized
            .replacingOccurrences(of: "\\s+([,;:.!?])", with: "$1", options: .regularExpression)
            .replacingOccurrences(of: "\\s{2,}", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        cleaned = uppercaseFirstLetter(cleaned)
        if !cleaned.hasSuffix("?") {
            cleaned = cleaned.trimmingCharacters(in: .punctuationCharacters) + "?"
        }
        return cleaned
    }

    private func polishExpectedAnswerText(_ answer: String) -> String {
        let normalized = answer
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return "" }

        var sentences = splitIntoSentences(normalized)
        if sentences.isEmpty { sentences = [normalized] }

        var seen = Set<String>()
        var polished: [String] = []
        for raw in sentences {
            var sentence = cleanTranscriptSentence(raw)
            sentence = sentence.replacingOccurrences(of: "^[,;:.!?\\-]+\\s*", with: "", options: .regularExpression)
            sentence = sentence.replacingOccurrences(
                of: "^(and|but|so|then|because|however|also|anyway|anyways)\\b\\s*",
                with: "",
                options: [.regularExpression, .caseInsensitive]
            )
            sentence = sentence.replacingOccurrences(of: "\\s+([,;:.!?])", with: "$1", options: .regularExpression)
            sentence = sentence.replacingOccurrences(of: "\\b(\\w+)\\s+\\1\\b", with: "$1", options: .regularExpression)
            sentence = sentence.replacingOccurrences(of: "\\s{2,}", with: " ", options: .regularExpression)
            sentence = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !sentence.isEmpty else { continue }

            sentence = uppercaseFirstLetter(sentence)
            if sentence.range(of: "[.!?]$", options: .regularExpression) == nil {
                sentence.append(".")
            }

            let key = normalizedPromptText(sentence)
            guard !key.isEmpty, !seen.contains(key) else { continue }
            seen.insert(key)

            if wordCount(sentence) < 4 && !polished.isEmpty {
                continue
            }
            polished.append(sentence)
        }

        if polished.isEmpty {
            var fallback = uppercaseFirstLetter(cleanTranscriptSentence(normalized))
            if fallback.range(of: "[.!?]$", options: .regularExpression) == nil {
                fallback.append(".")
            }
            return fallback
        }

        return polished.joined(separator: " ")
    }

    private enum QuestionIntent {
        case why
        case how
        case role
        case inconsistency
        case consequence
        case balance
        case comparison
        case arc
        case factual
    }

    private func questionIntent(for question: String) -> QuestionIntent {
        let lowered = normalizedPromptText(question)
        if lowered.hasPrefix("why ") { return .why }
        if lowered.hasPrefix("how ") { return .how }
        if lowered.contains("what role") { return .role }
        if lowered.contains("inconsistency") || lowered.contains("contradiction") || lowered.contains("conflict") {
            return .inconsistency
        }
        if lowered.contains("consequence") || lowered.contains("result") || lowered.contains("follows") || lowered.contains("follow") {
            return .consequence
        }
        if lowered.contains("balance") || lowered.contains("tradeoff") || lowered.contains("between") {
            return .balance
        }
        if lowered.contains("distinction") || lowered.contains("contrast") || lowered.contains("different") || lowered.contains("compare") {
            return .comparison
        }
        if lowered.contains("opening") || lowered.contains("closing") || lowered.contains("earlier") || lowered.contains("later") || lowered.contains("full episode") {
            return .arc
        }
        return .factual
    }

    private func questionContentTokens(from question: String) -> Set<String> {
        let genericQuestionWords: Set<String> = [
            "about", "across", "argument", "careful", "claim", "claims", "closing",
            "discussion", "episode", "exact", "full", "larger", "later", "listener",
            "listeners", "move", "opening", "part", "point", "points", "position",
            "rest", "role", "section", "segment", "show", "shows", "speaker", "test"
        ]
        return Set(
            meaningfulTokenList(from: question).filter { token in
                !genericQuestionWords.contains(token)
            }
        )
    }

    private func questionAnchors(from question: String) -> [String] {
        var anchors: [String] = []
        var seen = Set<String>()
        let contentTokens = questionContentTokens(from: question)

        func append(_ raw: String?) {
            guard let raw else { return }
            let cleaned = conciseTopicPhrase(raw, maxWords: 6)
            let key = normalizedPromptText(cleaned)
            guard !key.isEmpty, !seen.contains(key) else { return }
            seen.insert(key)
            anchors.append(cleaned)
        }

        append(focusPhrase(from: question))
        extractNamedEntities(from: question).prefix(4).forEach { append($0) }
        extractTopicalTerms(from: question)
            .filter { !contentTokens.isEmpty ? contentTokens.contains($0) : true }
            .prefix(6)
            .forEach { append($0) }

        return Array(anchors.prefix(6))
    }

    private func anchorHitCount(in normalizedText: String, anchors: [String]) -> Int {
        anchors.reduce(0) { count, anchor in
            let normalizedAnchor = normalizedPromptText(anchor)
            guard !normalizedAnchor.isEmpty else { return count }
            return normalizedText.contains(normalizedAnchor) ? count + 1 : count
        }
    }

    private func intentSignalBonus(for normalizedSentence: String, intent: QuestionIntent) -> Double {
        switch intent {
        case .why:
            if normalizedSentence.contains("because") || normalizedSentence.contains("so that") || normalizedSentence.contains("therefore") || normalizedSentence.contains("reason") {
                return 0.26
            }
        case .how:
            if normalizedSentence.contains("by ") || normalizedSentence.contains("through") || normalizedSentence.contains("depends on") || normalizedSentence.contains("using") {
                return 0.24
            }
        case .role:
            if normalizedSentence.contains("helps") || normalizedSentence.contains("allows") || normalizedSentence.contains("used to") || normalizedSentence.contains("serves") || normalizedSentence.contains("explains") {
                return 0.22
            }
        case .inconsistency:
            if normalizedSentence.contains("inconsistent") || normalizedSentence.contains("contradict") || normalizedSentence.contains("however") || normalizedSentence.contains("but") || normalizedSentence.contains("cannot both") || normalizedSentence.contains("can't both") {
                return 0.28
            }
        case .consequence:
            if normalizedSentence.contains("means") || normalizedSentence.contains("therefore") || normalizedSentence.contains("result") || normalizedSentence.contains("leads to") || normalizedSentence.contains("so ") {
                return 0.24
            }
        case .balance:
            if normalizedSentence.contains("between") || normalizedSentence.contains("both") || normalizedSentence.contains("while") || normalizedSentence.contains("balance") {
                return 0.22
            }
        case .comparison:
            if normalizedSentence.contains("different") || normalizedSentence.contains("distinguish") || normalizedSentence.contains("rather than") || normalizedSentence.contains("contrast") {
                return 0.22
            }
        case .arc:
            if normalizedSentence.contains("earlier") || normalizedSentence.contains("later") || normalizedSentence.contains("at first") || normalizedSentence.contains("ultimately") || normalizedSentence.contains("in the end") {
                return 0.2
            }
        case .factual:
            break
        }
        return 0
    }

    private func transcriptBackedExpectedAnswer(for question: String, transcript: String, fallback: String) -> String {
        let trimmedTranscript = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTranscript.isEmpty else {
            return polishExpectedAnswerText(fallback)
        }

        let questionTokens = meaningfulTokens(from: question)
        guard !questionTokens.isEmpty else {
            return polishExpectedAnswerText(fallback)
        }

        let contentTokens = questionContentTokens(from: question)
        let targetTokens = contentTokens.isEmpty ? questionTokens : contentTokens
        let anchors = questionAnchors(from: question)
        let intent = questionIntent(for: question)
        let fallbackAnswer = polishExpectedAnswerText(fallback)
        let fallbackTokens = meaningfulTokens(from: fallbackAnswer)
        let fallbackAlignment = fallbackAnswer.isEmpty ? 0.0 : promptAnswerAlignmentScore(question: question, expectedAnswer: fallbackAnswer)
        let normalizedQuestion = normalizedPromptText(question)

        struct ScoredSentence {
            let index: Int
            let sentence: String
            let tokens: Set<String>
            let contentOverlap: Double
            let anchorHits: Int
            let intentBonus: Double
            let score: Double
        }

        let scored: [ScoredSentence] = splitIntoSentences(trimmedTranscript)
            .map(cleanTranscriptSentence)
            .enumerated()
            .compactMap { index, sentence in
                guard !sentence.isEmpty else { return nil }
                guard !isSponsorOrShoutoutContent(sentence) else { return nil }
                guard wordCount(sentence) >= 6 else { return nil }

                let sentenceTokens = meaningfulTokens(from: sentence)
                guard !sentenceTokens.isEmpty else { return nil }

                let loweredSentence = normalizedPromptText(sentence)
                let questionOverlap = tokenJaccardSimilarity(questionTokens, sentenceTokens)
                let contentOverlap = targetTokens.isEmpty ? questionOverlap : tokenJaccardSimilarity(targetTokens, sentenceTokens)
                let fallbackOverlap = fallbackTokens.isEmpty ? 0.0 : tokenJaccardSimilarity(fallbackTokens, sentenceTokens)
                let anchorHits = anchorHitCount(in: loweredSentence, anchors: anchors)
                let intentBonus = intentSignalBonus(for: loweredSentence, intent: intent)

                var score = questionOverlap * 0.9
                score += contentOverlap * 2.4
                score += min(Double(anchorHits), 2) * 0.26
                score += intentBonus
                if fallbackAlignment >= 0.22 {
                    score += fallbackOverlap * 0.25
                }
                score += min(specificityScore(for: sentence) / 2.0, 1.0) * 0.18
                score += min(interestingnessScore(for: sentence) / 2.0, 1.0) * 0.14

                if normalizedQuestion.hasPrefix("why "),
                   loweredSentence.contains("because") || loweredSentence.contains("so that") || loweredSentence.contains("therefore") {
                    score += 0.12
                }
                if normalizedQuestion.hasPrefix("how "),
                   loweredSentence.contains("by ") || loweredSentence.contains("through") || loweredSentence.contains("depends on") {
                    score += 0.1
                }
                if normalizedQuestion.contains("what role"),
                   loweredSentence.contains("helps") || loweredSentence.contains("allows") || loweredSentence.contains("shapes") {
                    score += 0.08
                }

                return ScoredSentence(
                    index: index,
                    sentence: sentence,
                    tokens: sentenceTokens,
                    contentOverlap: contentOverlap,
                    anchorHits: anchorHits,
                    intentBonus: intentBonus,
                    score: score
                )
            }
            .sorted { lhs, rhs in
                if abs(lhs.score - rhs.score) < 0.0001 {
                    return lhs.index < rhs.index
                }
                return lhs.score > rhs.score
            }

        guard let best = scored.first,
              best.score >= 0.2 || best.contentOverlap >= 0.1 || best.anchorHits > 0 else {
            return fallbackAnswer
        }

        var selected = [best]
        var coveredTokens = best.tokens.intersection(targetTokens)
        let maxSentences = (intent == .why || intent == .how || intent == .arc) ? 3 : 2

        let localCandidates = scored.filter { candidate in
            candidate.index != best.index && abs(candidate.index - best.index) <= 2
        }

        for candidate in localCandidates {
            if selected.count >= maxSentences { break }

            let tokenGain = candidate.tokens.intersection(targetTokens).subtracting(coveredTokens).count
            let supportsIntent = candidate.intentBonus >= 0.18
            let supportsAnchor = candidate.anchorHits > 0
            let strongNeighbor = candidate.score >= best.score * 0.48

            guard strongNeighbor || tokenGain > 0 || supportsIntent || supportsAnchor else { continue }

            selected.append(candidate)
            coveredTokens.formUnion(candidate.tokens.intersection(targetTokens))
        }

        let transcriptAnswer = polishExpectedAnswerText(
            selected
                .sorted { $0.index < $1.index }
                .map(\.sentence)
                .joined(separator: " ")
        )

        let transcriptAlignment = promptAnswerAlignmentScore(question: question, expectedAnswer: transcriptAnswer)

        if transcriptAlignment >= 0.18 {
            return transcriptAnswer
        }
        if !transcriptAnswer.isEmpty &&
            (best.contentOverlap >= 0.1 || best.anchorHits > 0) &&
            transcriptAlignment + 0.05 >= fallbackAlignment {
            return transcriptAnswer
        }
        if fallbackAlignment >= 0.22 {
            return fallbackAnswer
        }
        return transcriptAnswer.isEmpty ? fallbackAnswer : transcriptAnswer
    }

    private func uppercaseFirstLetter(_ text: String) -> String {
        guard let first = text.first else { return text }
        return first.uppercased() + text.dropFirst()
    }

    private func expectedAnswerQualityScore(_ expectedAnswer: String) -> Double {
        let words = wordCount(expectedAnswer)
        guard words > 0 else { return 0 }

        var score = 0.0
        score += min(Double(words) / 34.0, 1.0) * 0.45
        score += min(specificityScore(for: expectedAnswer) / 1.6, 1.0) * 0.35
        score += min(interestingnessScore(for: expectedAnswer) / 1.6, 1.0) * 0.35
        score += min(depthScore(for: expectedAnswer) / 2.2, 1.0) * 0.2

        if isOverlyGenericSummary(expectedAnswer) { score -= 0.8 }
        if words < 12 { score -= 0.25 }
        return max(0, min(score, 2.2))
    }

    private func questionQualityScore(_ question: String, expectedAnswer: String) -> Double {
        let cleaned = polishGeneratedQuestion(question)
        let lowered = cleaned.lowercased()
        let words = wordCount(cleaned)
        var score = 0.0

        if cleaned.hasSuffix("?") { score += 0.2 }
        if words >= 9 && words <= 28 { score += 0.3 } else { score -= 0.1 }
        if lowered.hasPrefix("what ") || lowered.hasPrefix("why ") || lowered.hasPrefix("how ") || lowered.hasPrefix("which ") || lowered.hasPrefix("if ") {
            score += 0.18
        }

        let reasoningTerms = [
            "assumption", "tradeoff", "tension", "evidence", "reason", "consequence",
            "responsibility", "uncertainty", "risk", "value", "justification", "implication"
        ]
        for term in reasoningTerms where lowered.contains(term) {
            score += 0.06
        }

        if isOverlyGenericQuestion(cleaned) { score -= 0.9 }
        if isSponsorOrShoutoutContent(cleaned) { score -= 0.7 }

        let anchor = safeAnchor(from: expectedAnswer).lowercased()
        if anchor.split(separator: " ").count >= 2 && lowered.contains(anchor) {
            score += 0.25
        } else {
            score -= 0.1
        }

        score += episodeScopeQuestionSignal(cleaned)

        return max(0, min(score, 1.8))
    }

    private func promptPairQualityScore(
        question: String,
        expectedAnswer: String,
        segmentIndex: Int,
        totalSegments: Int
    ) -> Double {
        var score = 0.0
        score += expectedAnswerQualityScore(expectedAnswer) * 1.2
        score += questionQualityScore(question, expectedAnswer: expectedAnswer) * 1.0

        let q = question.lowercased()
        let a = expectedAnswer.lowercased()
        if segmentIndex == 0 {
            if q.contains("assumption") || q.contains("reason") || q.contains("force") { score += 0.12 }
        } else if segmentIndex == totalSegments - 1 {
            if q.contains("consequence") || q.contains("change") || q.contains("responsibility") { score += 0.12 }
        } else {
            if q.contains("tension") || q.contains("tradeoff") || q.contains("evidence") { score += 0.12 }
        }

        if q.contains("earlier") || q.contains("later") || q.contains("opening") || q.contains("closing") {
            score += 0.12
        }
        if a.contains("earlier in the episode") || a.contains("later in the episode") {
            score += 0.1
        }

        return score
    }

    private func isContentPromptCandidate(question: String, expectedAnswer: String) -> Bool {
        guard !isSponsorOrShoutoutContent(question) else { return false }
        guard !isSponsorOrShoutoutContent(expectedAnswer) else { return false }
        guard !isOverlyGenericQuestion(question) else { return false }
        guard !isOverlyGenericSummary(expectedAnswer) else { return false }
        let words = expectedAnswer.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count
        guard words >= 10 else { return false }
        guard specificityScore(for: expectedAnswer) >= 0.45 else { return false }
        guard interestingnessScore(for: expectedAnswer) >= 0.35 else { return false }
        let pairScore = promptPairQualityScore(question: question, expectedAnswer: expectedAnswer, segmentIndex: 1, totalSegments: 3)
        let scopeSignal = episodeScopeQuestionSignal(question)
        if scopeSignal < 0.06, pairScore < 1.6 {
            return false
        }
        return pairScore >= 1.35
    }

    private func deduplicatedPrompts(_ prompts: [Prompt]) -> [Prompt] {
        var seenQuestionKeys = Set<String>()
        var seenAnswerKeys = Set<String>()
        var unique: [Prompt] = []

        for prompt in prompts {
            let qKey = normalizedPromptText(prompt.question)
            let aKey = normalizedPromptText(prompt.expectedAnswer)
            guard !qKey.isEmpty, !aKey.isEmpty else { continue }
            if seenQuestionKeys.contains(qKey) || seenAnswerKeys.contains(aKey) {
                continue
            }
            seenQuestionKeys.insert(qKey)
            seenAnswerKeys.insert(aKey)
            unique.append(prompt)
        }
        return unique
    }

    private func normalizedPromptText(_ text: String) -> String {
        let lowered = text.lowercased()
            .replacingOccurrences(of: "[^a-z0-9 ]", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return lowered
    }

    private func tokenJaccardSimilarity(_ lhs: Set<String>, _ rhs: Set<String>) -> Double {
        guard !lhs.isEmpty, !rhs.isEmpty else { return 0 }
        let unionCount = lhs.union(rhs).count
        guard unionCount > 0 else { return 0 }
        return Double(lhs.intersection(rhs).count) / Double(unionCount)
    }

    private func promptAnswerAlignmentScore(question: String, expectedAnswer: String) -> Double {
        let questionTokens = meaningfulTokens(from: question)
        let contentTokens = questionContentTokens(from: question)
        let answerTokens = meaningfulTokens(from: expectedAnswer)
        guard !questionTokens.isEmpty, !answerTokens.isEmpty else { return 0 }

        let overlap = tokenJaccardSimilarity(questionTokens, answerTokens)
        let contentOverlap = contentTokens.isEmpty ? overlap : tokenJaccardSimilarity(contentTokens, answerTokens)
        let anchor = safeAnchor(from: expectedAnswer).lowercased()
        let anchors = questionAnchors(from: question)
        let intent = questionIntent(for: question)
        let normalizedQuestion = normalizedPromptText(question)
        let normalizedAnswer = normalizedPromptText(expectedAnswer)

        var score = (overlap * 0.45) + (contentOverlap * 0.75)
        if anchor.split(separator: " ").count >= 2 && normalizedQuestion.contains(anchor) {
            score += 0.18
        }
        if anchor.split(separator: " ").count >= 2 && normalizedAnswer.contains(anchor) {
            score += 0.12
        }
        let anchorHits = anchorHitCount(in: normalizedAnswer, anchors: anchors)
        if anchorHits > 0 {
            score += min(Double(anchorHits), 2) * 0.12
        }
        if intentSignalBonus(for: normalizedAnswer, intent: intent) >= 0.18 {
            score += 0.08
        }
        if normalizedQuestion.contains("earlier") || normalizedQuestion.contains("later") || normalizedQuestion.contains("opening") || normalizedQuestion.contains("closing") {
            if normalizedAnswer.contains("earlier in the episode") || normalizedAnswer.contains("later in the episode") {
                score += 0.08
            }
        }

        return min(score, 1.0)
    }

    private func expectedAnswerSelection(
        sentences: [String],
        paragraphBySentence: [Int],
        centerIndex: Int,
        segmentRange: ClosedRange<Int>,
        reservedIndices: Set<Int>
    ) -> (text: String, indices: [Int]) {
        guard !sentences.isEmpty else { return ("", []) }
        let safeCenter = max(0, min(centerIndex, sentences.count - 1))
        let centerParagraph = paragraphBySentence.indices.contains(safeCenter) ? paragraphBySentence[safeCenter] : 0
        var selected = [safeCenter]

        let nearby = (-3...3).compactMap { delta -> Int? in
            let idx = safeCenter + delta
            guard idx >= 0, idx < sentences.count, idx != safeCenter else { return nil }
            guard segmentRange.contains(idx) else { return nil }
            guard !reservedIndices.contains(idx) else { return nil }
            if paragraphBySentence.indices.contains(idx), paragraphBySentence[idx] != centerParagraph {
                return nil
            }
            guard isSubstantiveSentence(sentences[idx]) else { return nil }
            return idx
        }

        let rankedNearby = nearby.sorted { lhs, rhs in
            let lhsScore =
                (specificityScore(for: sentences[lhs]) * 0.7) +
                (depthScore(for: sentences[lhs]) * 0.4) +
                (interestingnessScore(for: sentences[lhs]) * 0.85) -
                (Double(abs(lhs - safeCenter)) * 0.14)
            let rhsScore =
                (specificityScore(for: sentences[rhs]) * 0.7) +
                (depthScore(for: sentences[rhs]) * 0.4) +
                (interestingnessScore(for: sentences[rhs]) * 0.85) -
                (Double(abs(rhs - safeCenter)) * 0.14)
            if abs(lhsScore - rhsScore) < 0.0001 {
                return abs(lhs - safeCenter) < abs(rhs - safeCenter)
            }
            return lhsScore > rhsScore
        }

        for idx in rankedNearby {
            selected.append(idx)
            let preview = selected
                .sorted()
                .map { cleanTranscriptSentence(sentences[$0]) }
                .joined(separator: " ")
            if wordCount(preview) >= 30 || selected.count >= 3 {
                break
            }
        }

        if selected.count == 1 {
            let fallbackNeighbor = (-2...2).compactMap { delta -> Int? in
                let idx = safeCenter + delta
                guard idx >= 0, idx < sentences.count, idx != safeCenter else { return nil }
                guard segmentRange.contains(idx) else { return nil }
                guard !reservedIndices.contains(idx) else { return nil }
                return idx
            }.min(by: { abs($0 - safeCenter) < abs($1 - safeCenter) })

            if let fallbackNeighbor {
                selected.append(fallbackNeighbor)
            }
        }

        let ordered = Array(Set(selected)).sorted()
        let merged = ordered
            .map { cleanTranscriptSentence(sentences[$0]) }
            .filter { !$0.isEmpty && !isSponsorOrShoutoutContent($0) }
            .joined(separator: " ")
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if merged.isEmpty {
            return (polishExpectedAnswerText(cleanTranscriptSentence(sentences[safeCenter])), [safeCenter])
        }
        return (polishExpectedAnswerText(merged), ordered)
    }

    private func cleanTranscriptSentence(_ sentence: String) -> String {
        var cleaned = sentence
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let fillerPattern = "^(well|so|you know|i mean|kind of|sort of|like)\\b[,:-]?\\s*"
        for _ in 0..<2 {
            let updated = cleaned.replacingOccurrences(
                of: fillerPattern,
                with: "",
                options: [.regularExpression, .caseInsensitive]
            ).trimmingCharacters(in: .whitespacesAndNewlines)
            if updated == cleaned { break }
            cleaned = updated
        }

        return cleaned
    }

    private func wordCount(_ text: String) -> Int {
        text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count
    }

    private func episodeArcSupportSentence(
        sentences: [String],
        centerIndex: Int,
        reservedIndices: Set<Int>
    ) -> String? {
        guard !sentences.isEmpty else { return nil }
        let safeCenter = max(0, min(centerIndex, sentences.count - 1))
        let centerSentence = cleanTranscriptSentence(sentences[safeCenter])
        let centerTokens = tokenize(centerSentence)
        let minDistance = max(10, sentences.count / 5)

        var bestIndex: Int?
        var bestScore = -Double.infinity

        for idx in sentences.indices {
            if idx == safeCenter { continue }
            if reservedIndices.contains(idx) { continue }
            let distance = abs(idx - safeCenter)
            if distance < minDistance { continue }

            let candidate = cleanTranscriptSentence(sentences[idx])
            guard isSubstantiveSentence(candidate) else { continue }
            let candidateTokens = tokenize(candidate)
            guard !candidateTokens.isEmpty else { continue }

            let overlap = Double(centerTokens.intersection(candidateTokens).count) / Double(max(centerTokens.count, 1))
            var score = overlap * 1.1
            score += specificityScore(for: candidate) * 0.32
            score += interestingnessScore(for: candidate) * 0.34
            score += depthScore(for: candidate) * 0.24
            score += (Double(distance) / Double(max(sentences.count, 1))) * 0.26

            if score > bestScore {
                bestScore = score
                bestIndex = idx
            }
        }

        guard let bestIndex else { return nil }
        let anchorText = cleanTranscriptSentence(sentences[bestIndex])
        guard !anchorText.isEmpty else { return nil }
        if bestIndex < safeCenter {
            return "Earlier in the episode, the speaker frames this through: \(anchorText)"
        }
        return "Later in the episode, this is extended through: \(anchorText)"
    }

    private func episodeScopeQuestionSignal(_ question: String) -> Double {
        let lowered = question.lowercased()
        var score = 0.0

        let arcSignals = [
            "earlier", "later", "opening", "closing", "beginning", "by the end",
            "across the episode", "throughout the episode", "full episode",
            "reframe", "reframes", "shift", "shifts", "evolve", "evolves",
            "thread", "arc", "tension between", "from the opening", "to the ending"
        ]

        for signal in arcSignals where lowered.contains(signal) {
            score += 0.06
        }

        if lowered.contains("casual listener") || lowered.contains("likely miss") {
            score += 0.08
        }

        return min(score, 0.42)
    }

    private func specificityScore(for sentence: String) -> Double {
        let cleaned = sentence
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        guard !cleaned.isEmpty else { return 0 }

        let tokens = cleaned.lowercased().split(whereSeparator: { $0.isWhitespace || $0.isNewline })
        guard !tokens.isEmpty else { return 0 }
        let tokenStrings = tokens.map(String.init)
        let unique = Set(tokenStrings).count
        let lexicalDensity = Double(unique) / Double(tokens.count)
        let longWords = tokenStrings.filter { $0.count >= 7 }.count

        var score = (lexicalDensity * 0.9) + (Double(longWords) / Double(max(tokens.count, 1)))
        if cleaned.range(of: "\\d", options: .regularExpression) != nil {
            score += 0.25
        }

        let lowered = cleaned.lowercased()
        let concreteSignals = [
            "because", "therefore", "however", "evidence", "data", "tradeoff",
            "cost", "risk", "policy", "history", "ethics", "responsibility",
            "consequence", "mechanism", "constraint", "incentive"
        ]
        for signal in concreteSignals where lowered.contains(signal) {
            score += 0.08
        }

        if isOverlyGenericSummary(cleaned) {
            score -= 0.6
        }

        return max(0, min(score, 2.2))
    }

    private func interestingnessScore(for sentence: String) -> Double {
        let cleaned = sentence
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        guard !cleaned.isEmpty else { return 0 }

        let lowered = cleaned.lowercased()
        var score = 0.0

        let causalSignals = ["because", "therefore", "so that", "which means", "leads to", "results in"]
        let tensionSignals = ["however", "but", "yet", "although", "on the other hand", "while", "despite"]
        let stakesSignals = ["risk", "cost", "benefit", "harm", "consequence", "failure", "pressure", "crisis"]
        let actionSignals = ["should", "must", "need to", "have to", "responsibility", "duty", "obligation"]
        let uncertaintySignals = ["uncertain", "uncertainty", "unknown", "depends", "maybe", "might", "tradeoff"]

        for signal in causalSignals where lowered.contains(signal) { score += 0.22 }
        for signal in tensionSignals where lowered.contains(signal) { score += 0.22 }
        for signal in stakesSignals where lowered.contains(signal) { score += 0.2 }
        for signal in actionSignals where lowered.contains(signal) { score += 0.2 }
        for signal in uncertaintySignals where lowered.contains(signal) { score += 0.18 }

        if cleaned.range(of: "\\d", options: .regularExpression) != nil { score += 0.15 }
        if cleaned.contains(":") || cleaned.contains(";") { score += 0.08 }
        if cleaned.contains("?") { score += 0.1 }

        if isOverlyGenericSummary(cleaned) { score -= 0.7 }
        return max(0, min(score, 2.3))
    }

    private func isOverlyGenericSummary(_ text: String) -> Bool {
        let lowered = normalizedPromptText(text)
        guard !lowered.isEmpty else { return true }
        let genericPhrases = [
            "the speaker talks about",
            "the speaker discusses",
            "the podcast talks about",
            "this section talks about",
            "in this section the speaker",
            "the main idea is",
            "overall the point is",
            "it is important to",
            "this is important because",
            "there are many factors",
            "it depends on many things"
        ]
        return genericPhrases.contains { lowered.contains($0) }
    }

    private func isOverlyGenericQuestion(_ text: String) -> Bool {
        let lowered = normalizedPromptText(text)
        guard !lowered.isEmpty else { return true }
        let genericFragments = [
            "what is the main idea",
            "what did the speaker talk about",
            "summarize this section",
            "what happened in this section",
            "what is this section about",
            "what is the strongest reason the speaker gives",
            "what consequence tied to",
            "what unresolved issue around",
            "if the claim about"
        ]
        return genericFragments.contains { lowered.contains($0) }
    }

    private func isSubstantiveSentence(_ sentence: String) -> Bool {
        let trimmed = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        guard !isSponsorOrShoutoutContent(trimmed) else { return false }
        guard !isOverlyGenericSummary(trimmed) else { return false }
        let wordCount = trimmed.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count
        guard wordCount >= 7 else { return false }
        guard specificityScore(for: trimmed) >= 0.25 else { return false }
        guard interestingnessScore(for: trimmed) >= 0.12 else { return false }
        return true
    }

    private func depthScore(for sentence: String) -> Double {
        let lowered = sentence.lowercased()
        let words = sentence.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count
        var score = min(Double(words), 36) / 9.0

        let reasoningSignals = [
            "because", "therefore", "however", "although", "implies", "means",
            "evidence", "argument", "assumption", "consequence", "tradeoff",
            "principle", "why", "how", "impact"
        ]
        for signal in reasoningSignals where lowered.contains(signal) {
            score += 0.28
        }

        if words > 44 { score -= 0.9 }
        if sentence.contains("?") { score += 0.15 }
        return score
    }

    private func isSponsorOrShoutoutContent(_ text: String) -> Bool {
        let lowered = text.lowercased()
        let blockedPhrases = [
            "this episode is brought to you by",
            "brought to you by",
            "our sponsor",
            "sponsored by",
            "sponsor",
            "promo code",
            "discount code",
            "use code",
            "offer code",
            "ad break",
            "advertisement",
            "advertiser",
            "support this show",
            "patreon.com",
            "affiliate link",
            "shout out",
            "shoutout",
            "special thanks to",
            "follow us",
            "rate and review",
            "subscribe to our channel",
            "merch"
        ]
        return blockedPhrases.contains { lowered.contains($0) }
    }

    private func evenlySpacedPromptTimes(audioDuration: Double, count: Int) -> [Double] {
        guard count > 0 else { return [] }
        let duration = max(audioDuration, 1)
        let startPad = min(45, max(8, duration * 0.08))
        let endPad = min(30, max(6, duration * 0.06))
        let usableStart = min(startPad, duration)
        let usableEnd = max(usableStart, duration - endPad)
        let span = max(usableEnd - usableStart, 0)

        if count == 1 {
            return [min(max(duration * 0.5, usableStart), usableEnd)]
        }

        return (1...count).map { i in
            let ratio = Double(i) / Double(count + 1)
            return usableStart + ratio * span
        }
    }

    private func splitIntoParagraphs(_ text: String) -> [String] {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        // Split on double newlines (common paragraph separator). If none, return the whole text.
        let parts = normalized.components(separatedBy: "\n\n")
        return parts.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    private func pickStopIndices(sentencesByParagraph: [[String]], desiredCount: Int) -> [Int] {
        // Build a flat index map and record paragraph ends
        var flatSentences: [String] = []
        var paragraphEndIndices = Set<Int>()
        var running = 0
        for para in sentencesByParagraph {
            if para.isEmpty { continue }
            for (i, s) in para.enumerated() {
                flatSentences.append(s)
                if i == para.count - 1 { paragraphEndIndices.insert(running + i) }
            }
            running += para.count
        }
        let total = flatSentences.count
        guard total > 0 else { return [] }

        let window = max(10, total / 10)
        var used = Set<Int>()
        var picks: [Int] = []

        func nearestIndex(to target: Int, preferParagraphEnd: Bool) -> Int? {
            var offset = 0
            while offset <= window {
                let left = target - offset
                if left >= 0 && !used.contains(left) {
                    if preferParagraphEnd && paragraphEndIndices.contains(left) { return left }
                    if !preferParagraphEnd { return left }
                }
                let right = target + offset
                if right < total && !used.contains(right) {
                    if preferParagraphEnd && paragraphEndIndices.contains(right) { return right }
                    if !preferParagraphEnd { return right }
                }
                offset += 1
            }
            return nil
        }

        func nearestPunctuatedIndex(to target: Int) -> Int? {
            var offset = 0
            while offset <= window {
                let left = target - offset
                if left >= 0 && !used.contains(left) {
                    let s = flatSentences[left].trimmingCharacters(in: .whitespacesAndNewlines)
                    if s.hasSuffix("?") || s.hasSuffix("!") { return left }
                }
                let right = target + offset
                if right < total && !used.contains(right) {
                    let s = flatSentences[right].trimmingCharacters(in: .whitespacesAndNewlines)
                    if s.hasSuffix("?") || s.hasSuffix("!") { return right }
                }
                offset += 1
            }
            return nil
        }

        // Choose evenly spaced targets across the content
        let picksToMake = min(desiredCount, max(1, total))
        for i in 1...picksToMake {
            let target = Int(round((Double(i) / Double(desiredCount + 1)) * Double(max(total - 1, 0))))

            // 1) Prefer a paragraph end near the target
            if let idx = nearestIndex(to: target, preferParagraphEnd: true) {
                used.insert(idx)
                picks.append(idx)
                continue
            }
            // 2) Then a punctuated sentence (question/exclamation) near the target
            if let idx = nearestPunctuatedIndex(to: target) {
                used.insert(idx)
                picks.append(idx)
                continue
            }
            // 3) Finally any nearest unused sentence
            if let idx = nearestIndex(to: target, preferParagraphEnd: false) {
                used.insert(idx)
                picks.append(idx)
                continue
            }
        }

        // Ensure ascending order for beginning/middle/end mapping
        return picks.sorted()
    }

    private func splitIntoSentences(_ text: String) -> [String] {
        // Simple sentence splitter on punctuation followed by space
        let pattern = "(?<=[.!?])\n|(?<=[.!?])\\s+"
        let parts = text.components(separatedBy: .newlines).joined(separator: " ").components(separatedBy: .whitespacesAndNewlines)
        let joined = parts.joined(separator: " ")
        let regex = try? NSRegularExpression(pattern: pattern, options: [])
        let range = NSRange(joined.startIndex..<joined.endIndex, in: joined)
        var sentences: [String] = []
        var last = 0
        regex?.enumerateMatches(in: joined, options: [], range: range) { match, _, _ in
            guard let match = match else { return }
            let end = match.range.location + match.range.length
            let r = NSRange(location: last, length: end - last)
            if let swiftRange = Range(r, in: joined) {
                let s = joined[swiftRange].trimmingCharacters(in: .whitespacesAndNewlines)
                if !s.isEmpty { sentences.append(s) }
            }
            last = end
        }
        if last < range.length {
            let r = NSRange(location: last, length: range.length - last)
            if let swiftRange = Range(r, in: joined) {
                let s = joined[swiftRange].trimmingCharacters(in: .whitespacesAndNewlines)
                if !s.isEmpty { sentences.append(s) }
            }
        }
        return sentences
    }
}

private struct ScoreResponse: Codable {
    let score: Int
    let feedback: String
    let awardedPoints: Int
}

import Foundation

struct AIResult {
    let score: Int
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

    func evaluateAnswer(question: String, expectedAnswer: String, userAnswer: String, transcript: String? = nil, progressSeconds: Double? = nil) async -> AIResult {
        if let endpointURL {
            do {
                return try await callEndpoint(url: endpointURL, question: question, expectedAnswer: expectedAnswer, userAnswer: userAnswer, transcript: transcript, progressSeconds: progressSeconds)
            } catch {
                return localScore(expectedAnswer: expectedAnswer, userAnswer: userAnswer, progressSeconds: progressSeconds)
            }
        }

        return localScore(expectedAnswer: expectedAnswer, userAnswer: userAnswer, progressSeconds: progressSeconds)
    }

    private func localScore(expectedAnswer: String, userAnswer: String, progressSeconds: Double?) -> AIResult {
        let expectedTokens = tokenize(expectedAnswer)
        let userTokens = tokenize(userAnswer)

        let overlap = expectedTokens.intersection(userTokens)
        let ratio = expectedTokens.isEmpty ? 0.0 : Double(overlap.count) / Double(expectedTokens.count)
        let score = min(100, max(0, Int((ratio * 100.0).rounded())))

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

        let awardedPoints = score
        return AIResult(score: score, feedback: feedback, awardedPoints: awardedPoints)
    }

    private func tokenize(_ text: String) -> Set<String> {
        let cleaned = text
            .lowercased()
            .replacingOccurrences(of: "[^a-z0-9 ]", with: " ", options: .regularExpression)
        let parts = cleaned.split(separator: " ")
        return Set(parts.map { String($0) })
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
        return AIResult(score: responseModel.score, feedback: responseModel.feedback, awardedPoints: responseModel.awardedPoints)
    }

    // MARK: - Prompt generation from transcript
    func generatePrompts(transcript: String, audioDuration: Double, desiredCount: Int = 3) async -> [Prompt] {
        // Attempt a remote generation if your backend supports it at /prompts; otherwise fall back to local
        if let base = endpointURL {
            let promptsURL = base.appendingPathComponent("prompts")
            do {
                var request = URLRequest(url: promptsURL)
                request.httpMethod = "POST"
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.timeoutInterval = 10
                let body: [String: Any] = [
                    "transcript": transcript,
                    "duration": audioDuration,
                    "count": desiredCount
                ]
                request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [])
                let (data, response) = try await URLSession.shared.data(for: request)
                if let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) {
                    if let remote = try? JSONDecoder().decode([GeneratedPrompt].self, from: data) {
                        let mapped = remote.map { Prompt(id: UUID(), timestampSeconds: min(max($0.time, 0), audioDuration), question: $0.question, expectedAnswer: $0.expectedAnswer, leadTimeSeconds: 0) }
                        if mapped.count >= desiredCount {
                            return Array(mapped.prefix(desiredCount))
                        } else if !mapped.isEmpty {
                            let needed = max(0, desiredCount - mapped.count)
                            let extra = localGeneratePrompts(transcript: transcript, audioDuration: audioDuration, desiredCount: needed)
                            return Array((mapped + extra).prefix(desiredCount))
                        }
                    }
                }
            } catch {
                // fall through to local
            }
        }

        // Local fallback: split transcript into chunks and create prompts aligned across duration
        return localGeneratePrompts(transcript: transcript, audioDuration: audioDuration, desiredCount: desiredCount)
    }

    private struct GeneratedPrompt: Decodable {
        let time: Double
        let question: String
        let expectedAnswer: String
    }

    private func localGeneratePrompts(transcript: String, audioDuration: Double, desiredCount: Int) -> [Prompt] {
        // Prefer to place prompts at natural stopping points and scale to episode length.
        // Ensure prompts appear only after the referenced content and are well spaced.
        let raw = transcript
        let paragraphs = splitIntoParagraphs(raw)
        let sentencesByParagraph = paragraphs.map { splitIntoSentences($0) }.filter { !$0.isEmpty }
        let totalSentences = sentencesByParagraph.reduce(0) { $0 + $1.count }
        guard totalSentences > 0 else { return [] }

        // Flatten sentences and compute paragraph end indices
        var flat: [String] = []
        var paragraphEndIndices = Set<Int>()
        var running = 0
        for para in sentencesByParagraph {
            if para.isEmpty { continue }
            for (i, s) in para.enumerated() {
                flat.append(s)
                if i == para.count - 1 { paragraphEndIndices.insert(running + i) }
            }
            running += para.count
        }

        // Timing constraints
        let minStart = max(30, min(60, audioDuration * 0.20)) // beginning should be 30–60s in, scaled
        let safeEnd = max(minStart + 5, audioDuration - 20)   // keep a tail at the end
        let postAnswerBuffer: Double = 4                      // appear after the answer
        let minGap = max(10, min(60, audioDuration * 0.10))   // spacing between prompts

        func clampTime(_ t: Double) -> Double { min(max(t, minStart), safeEnd) }

        // Helper to find the best sentence index at or before a target index
        let window = max(10, totalSentences / 10)
        func bestIndex(around target: Int) -> Int {
            let clampedTarget = max(0, min(target, totalSentences - 1))
            // 1) Prefer paragraph end at or before target
            var offset = 0
            while offset <= window {
                let left = clampedTarget - offset
                if left >= 0, paragraphEndIndices.contains(left) { return left }
                offset += 1
            }
            // 2) Prefer punctuated sentence at or before target
            offset = 0
            while offset <= window {
                let left = clampedTarget - offset
                if left >= 0 {
                    let s = flat[left].trimmingCharacters(in: .whitespacesAndNewlines)
                    if s.hasSuffix("?") || s.hasSuffix("!") { return left }
                }
                offset += 1
            }
            // 3) Fallback: the target itself (or 0)
            return clampedTarget
        }

        func indexForTime(_ time: Double) -> Int {
            let ratio = max(0, min(1, (time - postAnswerBuffer) / max(audioDuration, 1)))
            let idx = Int(round(ratio * Double(max(totalSentences - 1, 0))))
            return max(0, min(idx, totalSentences - 1))
        }

        var prompts: [Prompt] = []
        let count = max(1, desiredCount)

        if count == 3 {
            // Anchor to ~20%, ~50%, ~85% of the episode, with spacing and clamping
            var beginTime = clampTime(max(audioDuration * 0.20 + postAnswerBuffer, minStart))
            beginTime = min(beginTime, safeEnd - 2 * minGap)

            var midTime = clampTime(max(audioDuration * 0.50 + postAnswerBuffer, beginTime + minGap))
            midTime = min(midTime, safeEnd - minGap)

            var endTime = clampTime(max(audioDuration * 0.85 + postAnswerBuffer, midTime + minGap))

            let times = [beginTime, midTime, endTime]
            for (i, t) in times.enumerated() {
                let idxTarget = indexForTime(t)
                let idx = bestIndex(around: idxTarget)
                let expected = flat[idx].trimmingCharacters(in: .whitespacesAndNewlines)
                let question: String
                switch i {
                case 0: question = "Beginning check-in: What's the main idea introduced so far?"
                case 1: question = "Middle check-in: What example or argument was just presented?"
                default: question = "Final check-in: What's the key takeaway from this section?"
                }
                let prompt = Prompt(
                    id: UUID(),
                    timestampSeconds: t,
                    question: question,
                    expectedAnswer: expected,
                    leadTimeSeconds: 0
                )
                prompts.append(prompt)
            }
            return prompts
        } else {
            // General case: distribute prompts between ~20% and ~85% of duration
            let startRatio = 0.20
            let endRatio = 0.85
            for i in 1...count {
                let r = startRatio + (endRatio - startRatio) * (Double(i) / Double(count + 1))
                var t = clampTime(r * max(audioDuration, 1) + postAnswerBuffer)
                if let last = prompts.last { t = max(t, last.timestampSeconds + minGap) }
                let idxTarget = indexForTime(t)
                let idx = bestIndex(around: idxTarget)
                let expected = flat[idx].trimmingCharacters(in: .whitespacesAndNewlines)
                let prompt = Prompt(
                    id: UUID(),
                    timestampSeconds: t,
                    question: "Quick check: What was the main point just discussed?",
                    expectedAnswer: expected,
                    leadTimeSeconds: 0
                )
                prompts.append(prompt)
            }
            return prompts
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

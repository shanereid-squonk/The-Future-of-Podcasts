import Foundation

@MainActor
final class PointsStore: ObservableObject {
    @Published private(set) var totalPoints: Int = 0
    @Published private(set) var isEnabled: Bool = false
    private let userIDKey = "TheAgoraLA.Auth.UserID"
    private var currentUserID: String? = nil

    private let storageKeyBase = "TheAgoraLA.Points.Total"
    private var storageKey: String {
        if let id = currentUserID { return storageKeyBase + "." + id }
        return storageKeyBase + ".guest"
    }

    init() {
        if let last = UserDefaults.standard.string(forKey: userIDKey) {
            currentUserID = last
            isEnabled = true
            totalPoints = UserDefaults.standard.integer(forKey: storageKey)
        } else {
            isEnabled = false
            totalPoints = 0
        }
    }

    func add(points: Int) {
        guard points > 0, isEnabled else { return }
        totalPoints += points
        UserDefaults.standard.set(totalPoints, forKey: storageKey)
    }

    func reset() {
        totalPoints = 0
        UserDefaults.standard.set(0, forKey: storageKey)
    }

    func setUser(id: String?) {
        let normalized = id?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        currentUserID = normalized
        isEnabled = (normalized != nil)
        if let normalized {
            UserDefaults.standard.set(normalized, forKey: userIDKey)
            totalPoints = UserDefaults.standard.integer(forKey: storageKey)
        } else {
            UserDefaults.standard.removeObject(forKey: userIDKey)
            totalPoints = 0
        }
    }

    func signOut() {
        currentUserID = nil
        isEnabled = false
        totalPoints = 0
        UserDefaults.standard.removeObject(forKey: userIDKey)
    }

    func restoreLastUser() {
        if let last = UserDefaults.standard.string(forKey: userIDKey) {
            currentUserID = last
            isEnabled = true
            totalPoints = UserDefaults.standard.integer(forKey: storageKey)
        } else {
            currentUserID = nil
            isEnabled = false
            totalPoints = 0
        }
    }
}

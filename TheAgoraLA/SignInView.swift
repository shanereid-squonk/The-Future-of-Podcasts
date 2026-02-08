import SwiftUI

struct SignInView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var pointsStore: PointsStore
    @State private var userID: String = ""
    @State private var showInvalid = false

    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("Sign in to collect Agora Points")) {
                    TextField("Email or username", text: $userID)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }

                Section {
                    Button(action: signIn) {
                        Text("Sign In")
                            .frame(maxWidth: .infinity)
                    }
                    .disabled(userID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .navigationTitle("Agora Account")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .alert("Invalid ID", isPresented: $showInvalid) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("Please enter a valid email or username.")
            }
        }
    }

    private func signIn() {
        let trimmed = userID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { showInvalid = true; return }
        pointsStore.setUser(id: trimmed)
        dismiss()
    }
}

#Preview {
    SignInView()
        .environmentObject(PointsStore())
}

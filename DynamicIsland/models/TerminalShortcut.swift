import Defaults
import Foundation

struct TerminalShortcut: Identifiable, Codable, Equatable, Defaults.Serializable {
    var id = UUID()
    var name = ""
    var command = ""

    var isValid: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && command.rangeOfCharacter(from: .controlCharacters.union(.newlines)) == nil
    }
}

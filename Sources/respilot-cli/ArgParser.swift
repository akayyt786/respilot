import Foundation

/// Minimal `--flag value` / `--boolFlag` parser. Deliberately hand-rolled
/// instead of depending on swift-argument-parser so this tool builds with
/// zero external packages.
struct ArgParser {
    private let values: [String: String]
    private let flags: Set<String>
    let positionals: [String]

    init(_ arguments: [String]) {
        var values: [String: String] = [:]
        var flags: Set<String> = []
        var positionals: [String] = []
        var i = 0
        while i < arguments.count {
            let arg = arguments[i]
            if arg.hasPrefix("--") {
                let name = String(arg.dropFirst(2))
                if i + 1 < arguments.count, !arguments[i + 1].hasPrefix("--") {
                    values[name] = arguments[i + 1]
                    i += 2
                } else {
                    flags.insert(name)
                    i += 1
                }
            } else {
                positionals.append(arg)
                i += 1
            }
        }
        self.values = values
        self.flags = flags
        self.positionals = positionals
    }

    func string(_ name: String) -> String? { values[name] }

    func requiredString(_ name: String) throws -> String {
        guard let value = values[name] else { throw CLIError.missingArgument(name) }
        return value
    }

    func int(_ name: String) -> Int? { values[name].flatMap { Int($0) } }

    func flag(_ name: String) -> Bool { flags.contains(name) }
}

enum CLIError: Error, LocalizedError {
    case missingArgument(String)
    case invalidValue(String, String)
    case unknownCommand(String)

    var errorDescription: String? {
        switch self {
        case .missingArgument(let name):
            return "Missing required argument --\(name)"
        case .invalidValue(let name, let detail):
            return "Invalid value for --\(name): \(detail)"
        case .unknownCommand(let name):
            return "Unknown command: \(name). Run \"respilot help\" for usage."
        }
    }
}

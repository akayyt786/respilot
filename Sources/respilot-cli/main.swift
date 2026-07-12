import Foundation
import ResPilotCore

let rawArguments = Array(CommandLine.arguments.dropFirst())

guard let command = rawArguments.first else {
    printHelp()
    exit(0)
}

let args = ArgParser(Array(rawArguments.dropFirst()))

do {
    switch command {
    case "list-displays":
        try cmdListDisplays()
    case "list-bottles":
        cmdListBottles()
    case "list-profiles":
        try cmdListProfiles()
    case "show-profile":
        try cmdShowProfile(args)
    case "add-profile":
        try cmdAddProfile(args)
    case "remove-profile":
        try cmdRemoveProfile(args)
    case "apply":
        try await cmdApply(args)
    case "restore":
        try cmdRestore()
    case "list-apps":
        cmdListApps()
    case "install-app":
        try await cmdInstallApp(args)
    case "install-engine":
        try await cmdInstallEngine()
    case "help", "--help", "-h":
        printHelp()
    default:
        throw CLIError.unknownCommand(command)
    }
} catch {
    FileHandle.standardError.write("Error: \(error.localizedDescription)\n".data(using: .utf8)!)
    exit(1)
}

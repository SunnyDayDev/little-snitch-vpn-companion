import Foundation

let result = StatusCommand.execute(Array(CommandLine.arguments.dropFirst())) {
    try StatusClient().read(detectorID: $0)
}
FileHandle.standardOutput.write(Data(result.stdout.utf8))
FileHandle.standardError.write(Data(result.stderr.utf8))
exit(result.code)

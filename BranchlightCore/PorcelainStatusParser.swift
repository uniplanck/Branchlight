import Foundation

public enum PorcelainStatusParser {
    public static func parse(_ data: Data) throws -> [GitPathStatus] {
        let records = data.split(separator: 0, omittingEmptySubsequences: true)
        var result: [GitPathStatus] = []
        var index = 0

        while index < records.count {
            let record = records[index]
            guard record.count >= 4 else {
                index += 1
                continue
            }

            guard let string = String(data: Data(record), encoding: .utf8) else {
                throw GitEngineError.invalidOutput("git status produced non-UTF-8 path data")
            }

            let characters = Array(string)
            guard characters.count >= 4 else {
                index += 1
                continue
            }

            let indexCode = String(characters[0])
            let workTreeCode = String(characters[1])
            let path = String(characters.dropFirst(3))
            let kind = GitStatusClassifier.classify(index: indexCode, workTree: workTreeCode)

            result.append(
                GitPathStatus(
                    path: path,
                    indexCode: indexCode,
                    workTreeCode: workTreeCode,
                    kind: kind
                )
            )

            if indexCode == "R" || indexCode == "C" || workTreeCode == "R" || workTreeCode == "C" {
                index += 1 // porcelain -z emits the second path as the following NUL record
            }
            index += 1
        }

        return result
    }
}

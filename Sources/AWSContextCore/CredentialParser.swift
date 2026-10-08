import Foundation

/// Extracts credentials from text people typically copy around:
///
/// - `credentials` file snippets (`[name]` / `aws_access_key_id = …`)
/// - shell exports from the AWS access portal (`export AWS_ACCESS_KEY_ID="…"`)
/// - Windows `set` / PowerShell `$Env:` variants
/// - JSON from `aws sts get-session-token` / `assume-role`
public enum CredentialParser {
    public static func parse(_ text: String) -> NewProfile? {
        var result = NewProfile()
        if let json = parseJSON(text) {
            result = json
        } else {
            for rawLine in text.components(separatedBy: .newlines) {
                var line = rawLine.trimmingCharacters(in: .whitespaces)
                if line.hasPrefix("["), let name = INIDocument.sectionName(of: line) {
                    result.name = name.hasPrefix("profile ") ? String(name.dropFirst(8)) : name
                    continue
                }
                for prefix in ["export ", "set ", "$env:", "$Env:", "$ENV:"] where line.hasPrefix(prefix) {
                    line = String(line.dropFirst(prefix.count))
                }
                guard let eq = line.firstIndex(of: "=") else { continue }
                let key = line[..<eq].trimmingCharacters(in: .whitespaces).lowercased()
                let value = unquote(line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces))
                switch key {
                case "aws_access_key_id": result.accessKeyId = value
                case "aws_secret_access_key": result.secretAccessKey = value
                case "aws_session_token": result.sessionToken = value
                case "region", "aws_region", "aws_default_region": result.region = value
                case "output", "aws_default_output": result.output = value
                default: break
                }
            }
        }
        return result.accessKeyId.isEmpty && result.secretAccessKey.isEmpty ? nil : result
    }

    private static func parseJSON(_ text: String) -> NewProfile? {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let credentials = object["Credentials"] as? [String: Any] ?? object
        guard let keyId = credentials["AccessKeyId"] as? String else { return nil }
        return NewProfile(
            accessKeyId: keyId,
            secretAccessKey: credentials["SecretAccessKey"] as? String ?? "",
            sessionToken: credentials["SessionToken"] as? String ?? ""
        )
    }

    private static func unquote(_ value: String) -> String {
        var value = value
        if value.hasSuffix(";") { value.removeLast() }
        for quote in ["\"", "'"] where value.count >= 2 && value.hasPrefix(quote) && value.hasSuffix(quote) {
            value = String(value.dropFirst().dropLast())
        }
        return value
    }
}

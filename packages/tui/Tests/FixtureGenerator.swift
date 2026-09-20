import Foundation

let fileManager = FileManager.default
let arguments = CommandLine.arguments
guard arguments.count == 2 else {
    FileHandle.standardError.write(Data("Usage: swift FixtureGenerator.swift <destination>\n".utf8))
    exit(64)
}

let root = URL(fileURLWithPath: arguments[1], isDirectory: true).standardizedFileURL
let systemTemporary = fileManager.temporaryDirectory.standardizedFileURL.path
let temporaryRoots = ["/private/tmp/ai-manager-", systemTemporary + (systemTemporary.hasSuffix("/") ? "" : "/") + "ai-manager-"]
guard temporaryRoots.contains(where: root.path.hasPrefix) else {
    FileHandle.standardError.write(Data("Destination must be an ai-manager-* directory under the system temporary directory.\n".utf8))
    exit(64)
}
guard !fileManager.fileExists(atPath: root.path) else {
    FileHandle.standardError.write(Data("Destination already exists. Choose a new temporary directory.\n".utf8))
    exit(73)
}
try fileManager.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])

func write(_ text: String, to relativePath: String, permissions: Int = 0o600) throws {
    let url = root.appending(path: relativePath)
    try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    try Data(text.utf8).write(to: url, options: .atomic)
    try fileManager.setAttributes([.posixPermissions: permissions], ofItemAtPath: url.path)
}

func auth(account: String, workspace: String, email: String) throws -> String {
    let claims = try JSONSerialization.data(withJSONObject: [
        "email": email,
        "chatgpt_user_id": "user-\(email)",
        "chatgpt_account_id": account,
        "workspace_id": workspace,
    ])
    let payload = claims.base64EncodedString()
        .replacingOccurrences(of: "=", with: "")
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
    let value: [String: Any] = [
        "last_refresh": "2026-01-01T00:00:00Z",
        "tokens": [
            "access_token": "synthetic.\(payload).signature",
            "account_id": account,
            "refresh_token": "synthetic",
        ],
    ]
    return String(decoding: try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]), as: UTF8.self)
}

func transcript(id: String, events: [String]) throws -> String {
    let records: [[String: Any]] = [["type": "session_meta", "payload": ["id": id]]]
        + events.map { ["type": "event", "payload": ["marker": $0]] }
    return try records.map { String(decoding: try JSONSerialization.data(withJSONObject: $0, options: [.sortedKeys]), as: UTF8.self) }
        .joined(separator: "\n") + "\n"
}

try write(try auth(account: "account-one", workspace: "workspace-a", email: "one@example.test"), to: "source-one/auth.json")
try write(try auth(account: "account-two", workspace: "workspace-b", email: "two@example.test"), to: "source-two/auth.json")
try write("model = \"imported\"\n", to: "source-one/config.toml")
try write("model = \"second\"\n", to: "source-two/config.toml")
try write("model = \"shared\"\n", to: "default-home/config.toml")
try write("allow = [\"synthetic\"]\n", to: "external-rules/example.toml")
try fileManager.createSymbolicLink(
    at: root.appending(path: "source-one/rules"),
    withDestinationURL: root.appending(path: "external-rules")
)
try write(try transcript(id: "thread-divergent", events: ["imported branch"]), to: "source-one/sessions/2026/01/01/thread-divergent.jsonl")
try write(try transcript(id: "thread-new", events: ["new chat"]), to: "source-one/sessions/2026/01/01/thread-new.jsonl")
try write(try transcript(id: "thread-divergent", events: ["shared branch"]), to: "default-home/sessions/2026/01/01/thread-divergent.jsonl")
try write(try transcript(id: "thread-extended", events: ["first", "second"]), to: "source-two/sessions/2026/01/01/thread-extended.jsonl")
try write(try transcript(id: "thread-extended", events: ["first"]), to: "default-home/sessions/2026/01/01/thread-extended.jsonl")

let log = root.appending(path: "launch.log").path.replacingOccurrences(of: "'", with: "'\\''")
let fakeCodex = """
#!/bin/sh
if [ "$1 $2" = "app-server --stdio" ]; then
  account_id="$(jq -r '.tokens.account_id' "$CODEX_HOME/auth.json")"
  case "$account_id" in
    account-one) email='one@example.test' ;;
    account-two) email='two@example.test' ;;
    *) email='person@example.test' ;;
  esac
  IFS= read -r line
  printf '%s\n' '{"id":1,"result":{"codexHome":"synthetic","platformFamily":"unix","platformOs":"test","userAgent":"test"}}'
  IFS= read -r line
  IFS= read -r line
  IFS= read -r line
  IFS= read -r line
  printf '{"id":2,"result":{"account":{"type":"chatgpt","email":"%s","planType":"plus"},"requiresOpenaiAuth":false}}\n' "$email"
  printf '{"id":3,"result":{"accountId":"%s","ordinaryUsageAllowed":true,"rateLimits":{"limitId":"codex","primary":{"usedPercent":25}}}}\n' "$account_id"
  today="$(date -u +%F)"
  printf '{"id":4,"result":{"summary":{"lifetimeTokens":1200},"dailyUsageBuckets":[{"startDate":"%s","tokens":1200}]}}\n' "$today"
  exit 0
fi
if [ "$3 $4" = "login status" ] || [ "$4 $5" = "login status" ]; then
  printf '%s\n' 'Logged in using ChatGPT'
  exit 0
fi
if [ "$3" = "login" ]; then
  exit 0
fi
printf '%s\\t%s\n' "$CODEX_HOME" "$*" >> '\(log)'
"""
try write(fakeCodex, to: "fake-codex", permissions: 0o700)

func recoveryHeader(id: String) throws -> String {
    let accountID = UUID(uuidString: id)!.uuidString
    let destination = root.appending(path: "application-support/accounts/\(accountID)/home")
    let backup = root.appending(path: "application-support/backups/\(id)")
    let value: [String: Any] = [
        "id": id,
        "kind": "import",
        "phase": "conflicted",
        "source": root.appending(path: "source-one").absoluteString,
        "destination": destination.absoluteString,
        "backup": backup.absoluteString,
        "expectedDigest": "synthetic-expected-digest",
        "previousDigest": "4a760c51b2523437cd79805c5da8206f17b1239169361d1494ce1e8aacb19c45",
        "registryAccountID": id,
    ]
    try write(
        try auth(
            account: "recovery-\(id)",
            workspace: "recovery-workspace",
            email: "recovery@example.test"
        ),
        to: "application-support/accounts/\(accountID)/home/auth.json"
    )
    try write("protected original\n", to: "application-support/backups/\(id)/account-home/auth.json")
    return String(decoding: try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]), as: UTF8.self)
}

let directRecoveryID = "11111111-1111-4111-8111-111111111111"
let interactiveRecoveryID = "22222222-2222-4222-8222-222222222222"
try write(try recoveryHeader(id: directRecoveryID), to: "recovery-fixtures/\(directRecoveryID).json")
try write(try recoveryHeader(id: interactiveRecoveryID), to: "recovery-fixtures/\(interactiveRecoveryID).json")

print(root.path)

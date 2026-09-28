#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// MARK: - agy file token storage payload

/// JSON payload of the `fileTokenStorage` fallback file that `agy` maintains at
/// `<home>/.gemini/antigravity-cli/antigravity-oauth-token`. `agy`'s composite token
/// storage reads this file whenever the OS keyring is unavailable, so a staged `HOME`
/// scopes the account without touching the user's Keychain item.
struct AntigravityAgyFileTokenPayload: Codable, Equatable, Sendable {
    struct Token: Codable, Equatable, Sendable {
        let accessToken: String
        let tokenType: String
        let refreshToken: String
        let expiry: String

        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case tokenType = "token_type"
            case refreshToken = "refresh_token"
            case expiry
        }
    }

    let token: Token
    let authMethod: String
    let idToken: String?

    enum CodingKeys: String, CodingKey {
        case token
        case authMethod = "auth_method"
        case idToken = "id_token"
    }
}

enum AntigravityAgyFileTokenEncoder {
    static func encode(credentials: AntigravityOAuthCredentials) -> Data? {
        guard let accessToken = credentials.accessToken?.trimmingCharacters(in: .whitespacesAndNewlines),
              !accessToken.isEmpty,
              let refreshToken = credentials.refreshToken?.trimmingCharacters(in: .whitespacesAndNewlines),
              !refreshToken.isEmpty,
              let expiryDate = credentials.expiryDate
        else {
            return nil
        }

        let payload = AntigravityAgyFileTokenPayload(
            token: .init(
                accessToken: accessToken,
                tokenType: "Bearer",
                refreshToken: refreshToken,
                expiry: expiryString(for: expiryDate)),
            authMethod: "consumer",
            idToken: credentials.idToken)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try? encoder.encode(payload)
    }

    static func decode(data: Data) -> AntigravityAgyFileTokenPayload? {
        try? JSONDecoder().decode(AntigravityAgyFileTokenPayload.self, from: data)
    }

    private static func expiryString(for date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: date)
    }

    static func expiryDate(from string: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: string) {
            return date
        }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: string)
    }
}

// MARK: - Scoped staging

enum AntigravityScopedStagingError: LocalizedError, Sendable, Equatable {
    case credentialsMissingRequiredFields
    case identityUnverifiable

    var errorDescription: String? {
        switch self {
        case .credentialsMissingRequiredFields:
            "Antigravity account credentials lack required token or expiry fields."
        case .identityUnverifiable:
            "Antigravity scoped credentials could not be verified against the selected account."
        }
    }
}

/// Stages the selected account's credentials into a fresh private `HOME` for a
/// single `agy` print invocation. The directory is deleted by the caller's `defer`,
/// so no account lifecycle tracking, locking, or persistent credential copies exist.
enum AntigravityScopedAgyStaging {
    /// Provider-specific by design: agy's file token storage path is a fixed external contract.
    static let tokenRelativePath = [".gemini", "antigravity-cli", "antigravity-oauth-token"]

    /// Allowlist environment for the scoped child. Nothing else is inherited:
    /// injected credentials, other providers' tokens, and ambient tool settings
    /// cannot leak into the `agy` process. A non-empty `SSH_TTY` makes `agy`
    /// select file-based token storage outright, so it never consults the OS keyring.
    static func childEnvironment(
        from environment: [String: String],
        home: URL) -> [String: String]
    {
        var child: [String: String] = [:]
        for key in [
            "PATH",
            "TMPDIR",
            "LANG",
            "LC_ALL",
            "HTTP_PROXY",
            "HTTPS_PROXY",
            "ALL_PROXY",
            "NO_PROXY",
            "http_proxy",
            "https_proxy",
            "all_proxy",
            "no_proxy",
        ] {
            if let value = environment[key]?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
                child[key] = value
            }
        }
        child["PATH"] = PathBuilder.effectivePATH(
            purposes: [.tty], env: child, loginPATH: LoginShellPathCache.shared.current)
        child["HOME"] = home.path
        child["PWD"] = home.path
        child["SSH_TTY"] = "codexbar-scoped"
        return child
    }

    /// Creates a fresh 0700 staging directory, writes the token file, then
    /// re-reads it and verifies the staged `id_token` claim against the
    /// expected account when a claim is present. Saved credentials may carry
    /// no `id_token` at all (the OAuth scopes CodexBar requests do not include
    /// `openid`); those stage unchecked here because the post-run userinfo
    /// verification binds the effective account anyway.
    static func stage(
        credentials: AntigravityOAuthCredentials,
        expectedAccountEmail: String,
        fileManager: FileManager = .default) throws -> (stagingRoot: URL, home: URL)
    {
        guard let tokenData = AntigravityAgyFileTokenEncoder.encode(credentials: credentials) else {
            throw AntigravityScopedStagingError.credentialsMissingRequiredFields
        }
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("codexbar-agy-scoped-" + UUID().uuidString, isDirectory: true)
        let home = root.appendingPathComponent("home", isDirectory: true)
        do {
            try fileManager.createDirectory(
                at: home, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            var tokenURL = home
            for component in Self.tokenRelativePath.dropLast() {
                tokenURL.appendPathComponent(component, isDirectory: true)
            }
            try fileManager.createDirectory(
                at: tokenURL, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            tokenURL.appendPathComponent(Self.tokenRelativePath.last!)
            try CredentialFileWriter.writePrivate(tokenData, to: tokenURL)

            guard let staged = try? Data(contentsOf: tokenURL),
                  let payload = AntigravityAgyFileTokenEncoder.decode(data: staged)
            else {
                throw AntigravityScopedStagingError.identityUnverifiable
            }
            if let stagedEmail = Self.normalizedEmail(
                AntigravityOAuthCredentials.email(fromIDToken: payload.idToken)),
                stagedEmail != Self.normalizedEmail(expectedAccountEmail)
            {
                throw AntigravityScopedStagingError.identityUnverifiable
            }
            return (root, home)
        } catch {
            try? fileManager.removeItem(at: root)
            throw error
        }
    }

    static func normalizedEmail(_ email: String?) -> String? {
        guard let trimmed = email?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed.lowercased()
    }

    /// Reads the staged token file as `agy` left it after a run. `agy` rewrites
    /// this file when it refreshes an expired grant, so the payload may carry a
    /// newer access token, refresh token, expiry, and `id_token` than what was
    /// staged.
    static func stagedTokenPayload(
        home: URL,
        fileManager: FileManager = .default) -> AntigravityAgyFileTokenPayload?
    {
        var tokenURL = home
        for component in Self.tokenRelativePath {
            tokenURL.appendPathComponent(component, isDirectory: false)
        }
        guard let data = fileManager.contents(atPath: tokenURL.path) else { return nil }
        return AntigravityAgyFileTokenEncoder.decode(data: data)
    }

    /// Returns the saved-account form of the staged payload when `agy` changed
    /// it (typically a token refresh), or nil when the file is unchanged. The
    /// caller must only persist the result after the effective account has been
    /// verified — the payload alone does not prove which account it belongs to.
    static func refreshedCredentials(
        home: URL,
        original: AntigravityOAuthCredentials,
        fileManager: FileManager = .default) -> AntigravityOAuthCredentials?
    {
        guard let payload = stagedTokenPayload(home: home, fileManager: fileManager),
              let originalData = AntigravityAgyFileTokenEncoder.encode(credentials: original),
              let originalPayload = AntigravityAgyFileTokenEncoder.decode(data: originalData),
              payload != originalPayload
        else {
            return nil
        }
        var updated = original
        let accessToken = payload.token.accessToken.trimmingCharacters(in: .whitespacesAndNewlines)
        let refreshToken = payload.token.refreshToken.trimmingCharacters(in: .whitespacesAndNewlines)
        if !accessToken.isEmpty {
            updated.accessToken = accessToken
        }
        if !refreshToken.isEmpty {
            updated.refreshToken = refreshToken
        }
        if let expiry = AntigravityAgyFileTokenEncoder.expiryDate(from: payload.token.expiry) {
            updated.expiryDateMilliseconds = expiry.timeIntervalSince1970 * 1000
        }
        if let idToken = payload.idToken?.trimmingCharacters(in: .whitespacesAndNewlines), !idToken.isEmpty {
            updated.idToken = idToken
        }
        return updated
    }

    /// The account whose credential `agy` actually used during a run. After the
    /// child exits, its staged token file holds the access token that made the
    /// API calls — refreshed in place when the staged grant was expired — so
    /// resolving that token through Google's `userinfo` endpoint binds the
    /// result to the effective credential, not to the `id_token` claim (which
    /// could disagree with the access/refresh tokens in a corrupted file).
    static func runEffectiveAccountEmail(
        home: URL,
        timeout: TimeInterval,
        dataLoader: @escaping @Sendable (URLRequest) async throws -> (Data, URLResponse),
        fileManager: FileManager = .default) async -> String?
    {
        guard let payload = stagedTokenPayload(home: home, fileManager: fileManager)
        else {
            return nil
        }
        let accessToken = payload.token.accessToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !accessToken.isEmpty,
              let url = URL(string: "https://www.googleapis.com/oauth2/v3/userinfo")
        else {
            return nil
        }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = min(timeout, 15)
        guard let (responseData, response) = try? await dataLoader(request),
              let http = response as? HTTPURLResponse, http.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any]
        else {
            return nil
        }
        return self.normalizedEmail(json["email"] as? String)
    }
}

// MARK: - Scoped print fetch

#if os(macOS)
extension AntigravityCLIHTTPSFetchStrategy {
    private static let scopedPrintLog = CodexBarLog.logger(LogCategories.provider(.antigravity))

    /// Runs `agy -p /usage` scoped to the injected token account's credentials:
    /// the account's OAuth tokens are staged into a private per-run `HOME`, the
    /// child receives an allowlist environment, and the staged token's `id_token`
    /// claim, when present, is verified against the selected account before
    /// launch. Because the
    /// CLI authenticates with the staged access/refresh tokens — which could
    /// disagree with the `id_token` claim — the access token `agy` actually used
    /// is resolved through Google's `userinfo` endpoint after the run and must
    /// match the selected account before the report is labeled with it. When the
    /// identity check succeeds and `agy` refreshed the staged grant, the updated
    /// credentials are handed to `credentialsUpdateHandler` (the same guarded
    /// token-account updater the OAuth strategy uses) so the next refresh starts
    /// from the refreshed token instead of the discarded expired one. Fails
    /// closed: any error propagates so the pipeline falls through to the
    /// account-scoped OAuth strategy; ambient reports are never substituted for
    /// a selected account.
    func fetchScopedPrintUsage(
        binary: String,
        environment: [String: String],
        timeout: TimeInterval = 90,
        dataLoader: (@Sendable (URLRequest) async throws -> (Data, URLResponse))? = nil,
        credentialsUpdateHandler: (@Sendable (AntigravityOAuthCredentials) async throws -> Void)? = nil)
        async throws
        -> ProviderFetchResult
    {
        guard let value = environment[AntigravityOAuthCredentialsStore.environmentCredentialsKey],
              let credentials = AntigravityOAuthCredentialsStore.credentials(fromTokenAccountValue: value),
              let expectedAccountEmail = credentials.resolvedAccountEmail
        else {
            throw AntigravityScopedStagingError.credentialsMissingRequiredFields
        }

        let staged = try AntigravityScopedAgyStaging.stage(
            credentials: credentials,
            expectedAccountEmail: expectedAccountEmail)
        defer { try? FileManager.default.removeItem(at: staged.stagingRoot) }
        let scopedEnvironment = AntigravityScopedAgyStaging.childEnvironment(
            from: environment, home: staged.home)

        let result: SubprocessResult
        do {
            let version = try await Self.agyVersion(binary: binary, environment: scopedEnvironment)
            guard let version, version >= (1, 1, 11)
            else { throw AntigravityStatusProbeError.parseFailed("CLI usage reports require agy 1.1.11 or later") }
            result = try await SubprocessRunner.run(
                binary: binary,
                arguments: ["-p", "/usage", "--output-format", "json", "--print-timeout", "90s"],
                environment: scopedEnvironment,
                timeout: timeout,
                maxOutputBytes: 1_048_576,
                standardInput: FileHandle.nullDevice,
                currentDirectoryURL: staged.home,
                reapDescendants: true,
                label: "antigravity-cli-scoped-usage")
        } catch let error as SubprocessRunnerError {
            try Task.checkCancellation()
            // Subprocess errors may contain raw stderr; classify them into safe,
            // fixed diagnostics instead of surfacing the process output.
            throw AntigravityCLIPrintFailure.error(for: error)
        }

        let parsed = try AntigravityStatusProbe.parseCLIUsageReport(Data(result.stdout.utf8))
        if let reportedEmail = AntigravityScopedAgyStaging.normalizedEmail(parsed.accountEmail),
           reportedEmail != AntigravityScopedAgyStaging.normalizedEmail(expectedAccountEmail)
        {
            Self.scopedPrintLog.info(
                "Scoped agy usage report rejected: report identity does not match the selected account")
            throw AntigravityStatusProbeError.accountMismatch(
                expected: expectedAccountEmail, found: parsed.accountEmail)
        }
        let loader = dataLoader ?? { request in try await URLSession.shared.data(for: request) }
        let effectiveEmail = await AntigravityScopedAgyStaging.runEffectiveAccountEmail(
            home: staged.home,
            timeout: timeout,
            dataLoader: loader)
        guard let effectiveEmail else {
            Self.scopedPrintLog.info(
                "Scoped agy usage report rejected: CLI effective account could not be verified")
            throw AntigravityScopedStagingError.identityUnverifiable
        }
        guard effectiveEmail == AntigravityScopedAgyStaging.normalizedEmail(expectedAccountEmail) else {
            Self.scopedPrintLog.info(
                "Scoped agy usage report rejected: CLI effective account does not match the selected account")
            throw AntigravityStatusProbeError.accountMismatch(
                expected: expectedAccountEmail, found: effectiveEmail)
        }
        // `agy` may have refreshed the staged grant in place; persist the verified
        // refreshed credential so the next run does not start from the expired token.
        if let credentialsUpdateHandler,
           let refreshed = AntigravityScopedAgyStaging.refreshedCredentials(
               home: staged.home, original: credentials)
        {
            do {
                try await credentialsUpdateHandler(refreshed)
            } catch {
                Self.scopedPrintLog.warning(
                    "Scoped agy usage: could not persist refreshed credentials (\(error.localizedDescription))")
            }
        }
        let snapshot = parsed.withIdentity(from: AntigravityStatusSnapshot(
            modelQuotas: [], accountEmail: expectedAccountEmail, accountPlan: nil, source: parsed.source))
        return try self.makeResult(usage: snapshot.toUsageSnapshot(), sourceLabel: Self.sourceLabel)
    }
}
#endif

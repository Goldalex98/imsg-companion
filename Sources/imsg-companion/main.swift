import AppKit
import CompanionCore
import Contacts
import Foundation

// Wiring only: the behaviour lives in CompanionCore, where it is tested.

let support = CompanionConfig.defaultURL(supportFolder: CompanionConfig.supportFolder).deletingLastPathComponent()
let configURL = support.appendingPathComponent("companion.json")
let databasePath = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Messages/chat.db").path
let tokens = KeychainTokenStore()
/// Set by scripts/build-app.sh (plan Task 10); "dev" for a `swift run`.
let agentVersion = Bundle.main.object(forInfoDictionaryKey: "ImsgCompanionGitSHA") as? String ?? "dev"

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var set = false
    var value: Bool { lock.withLock { set } }
    func raise() { lock.withLock { set = true } }
}

final class Latest: @unchecked Sendable {
    private let lock = NSLock()
    private var readerState = CompanionStatus(state: .idle)
    private var senderState = CompanionSendStatus(state: .off)
    var reader: CompanionStatus {
        get { lock.withLock { readerState } }
        set { lock.withLock { readerState = newValue } }
    }
    var sender: CompanionSendStatus {
        get { lock.withLock { senderState } }
        set { lock.withLock { senderState = newValue } }
    }
}

/// A status post that succeeded also proves HomeChat is reachable for the health mark.
struct MarkingStatusUplink: StatusUplinking {
    let client: UplinkClient
    let health: HealthMarkStore
    func postStatus(_ status: AgentStatus) async throws(UplinkError) {
        try await client.postStatus(status)
        health.homechatOK(now: Date())
    }
}

func permissions(_ names: ContactsNameResolver, _ last: LastScriptResult) -> AgentStatus.Permissions {
    .init(fullDiskAccess: Permissions.fullDiskAccess(path: databasePath),
          automationMessages: Permissions.automation(from: last.value), contacts: names.permission)
}

func pace(seconds: Double) async { try? await Task.sleep(for: .seconds(seconds)) }

func runAgent() async -> Never {
    let pause = PauseState()
    let guardian = ForkGuard(pause: pause)
    let stopping = Flag()
    let latest = Latest()
    let serializer = UplinkSerializer()
    let names = ContactsNameResolver()
    let lastScript = LastScriptResult()
    let health = HealthMarkStore(folder: support)
    try? health.start(version: agentVersion, now: Date())
    let preflights = PreflightFiles(folder: support)

    let service = CompanionService(databasePath: databasePath, configURL: configURL, tokens: tokens, names: names,
                                   makeUplink: { UplinkClient(baseURL: $0, token: $1) }, serializer: serializer,
                                   isPaused: { guardian.blocksUplink() })
    let relay = UnsendRelay(events: UnsendRelay.watcherEvents(databasePath: databasePath), databasePath: databasePath,
                            configURL: configURL, tokens: tokens, names: names,
                            makeUplink: { UplinkClient(baseURL: $0, token: $1) }, serializer: serializer,
                            isPaused: { guardian.blocksUplink() })
    // A stop request counts as a pause for the executor: a send fetched after SIGTERM is ignored, not dispatched.
    let executor = CompanionSendExecutor(databasePath: databasePath, configURL: configURL,
                                         ledgerFolder: support.appendingPathComponent("companion-sends"),
                                         tokens: tokens, makeUplink: { UplinkClient(baseURL: $0, token: $1) },
                                         runner: ObservedRunner(OsascriptRunner(), last: lastScript),
                                         isPaused: { guardian.blocksUplink() || stopping.value },
                                         onControl: { pause.apply($0) })
    let snapshot: @Sendable () async -> AgentStatus = {
        StatusSnapshot.make(config: CompanionConfig.load(from: configURL), agentVersion: agentVersion,
                            reader: latest.reader, sender: latest.sender, permissions: permissions(names, lastScript),
                            remotePaused: pause.remotePaused, watcherRestarts: await relay.restarts,
                            forkRunning: guardian.forkRunning, update: UpdateState.load(from: updaterPaths.state))
    }
    let reporter = StatusReporter(configURL: configURL, tokens: tokens,
                                  makeUplink: { MarkingStatusUplink(client: UplinkClient(baseURL: $0, token: $1),
                                                                    health: health) },
                                  snapshot: snapshot)
    let statusFile = AgentStatusFile(folder: support)
    let present = PresentReconciler(configURL: configURL, tokens: tokens,
                                    makeUplink: { UplinkClient(baseURL: $0, token: $1) }, serializer: serializer,
                                    snapshot: { await service.presentSnapshot(sinceUnix: $0) })
    let presentFiles = PresentFiles(folder: support)

    Task {
        while !stopping.value {
            let status = await service.tick()
            latest.reader = status
            health.record(status, now: Date())
            await relay.flush()
            await preflights.handle(now: Date()) { await executor.preflight(chatRowID: $0) }
            // Straight after the tick that left the reader idle, with no tick in between its read and its posts.
            await presentFiles.handle { await present.runIfDue(after: status, force: $0) }
            await pace(seconds: 2)
        }
    }
    Task { await relay.run() }
    Task {
        while !stopping.value {
            await reporter.tick(now: Date())
            statusFile.write(await snapshot(), at: Date())
            await pace(seconds: 30)
        }
    }
    let sender = Task {
        while !stopping.value {
            let status = await executor.cycle()
            latest.sender = status
            // The fetch long-polls while sends are possible; every other state returns at once, so pace it.
            if status.state != .waiting { await pace(seconds: 5) }
        }
    }

    signal(SIGTERM, SIG_IGN)
    let terminate = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .global())
    terminate.setEventHandler { stopping.raise() }
    terminate.resume()
    // Stop taking sends, let an in-flight dispatch and its read-back finish, then exit.
    await sender.value
    terminate.cancel()
    exit(0)
}

let agentLabel = "io.github.goldalex98.imsg-companion"
let updaterPaths = UpdaterPaths(
    support: support,
    app: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications/ImsgCompanion.app"),
    agentPlist: FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/LaunchAgents/\(agentLabel).plist"))

func runUpdate() async {
    let ledger = CompanionSendLedger(folder: support.appendingPathComponent("companion-sends"))
    let health = HealthMarkStore(folder: support)
    let updater = Updater(
        paths: updaterPaths, label: agentLabel, uid: getuid(), runner: ProcessRunner(), github: GitHubUpdateSource(),
        // The running agent posts its status at least every 15 minutes, so a recent 2xx means HomeChat is up.
        homechatReachable: { (health.read()?.homechatOKAt).map { Date().timeIntervalSince($0) < 1800 } ?? false },
        sendInProgress: { !ledger.inProgress().isEmpty },
        // The local flag, or the running agent's last snapshot (which includes HomeChat's pause).
        isPaused: { CompanionConfig.load(from: configURL).paused || AgentStatusFile(folder: support).read()?.status.paused == true },
        installedVersion: {
            let info = NSDictionary(contentsOf: updaterPaths.app.appendingPathComponent("Contents/Info.plist"))
            return info?["ImsgCompanionGitSHA"] as? String
        },
        health: { health.read() })
    printJSON(await updater.runOnce())
}

func printJSON<T: Encodable>(_ value: T) {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    guard let data = try? encoder.encode(value) else { fail("couldn't encode") }
    print(String(decoding: data, as: UTF8.self))
}

guard let command = Command.parse(Array(CommandLine.arguments.dropFirst())) else { fail(Command.usage) }

switch command {
case .run:
    await runAgent()

case .setup(let url):
    FileHandle.standardError.write(Data("Paste the uplink token, then press Return: ".utf8))
    let token = readLine(strippingNewline: true) ?? ""
    let outcome = ConfigEdits.setup(url: url, tokenInput: token, configURL: configURL, tokens: tokens)
    if let error = outcome.error { fail(error) }
    print("saved: host \(outcome.host ?? "-"), device \(outcome.deviceID ?? "-"), token saved")
    // Contacts can only be asked for from the app itself, so its prompt names the app.
    if CNContactStore.authorizationStatus(for: .contacts) == .notDetermined,
       Bundle.main.bundleURL.pathExtension == "app" {
        let open = Process()
        open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        open.arguments = ["-n", "-a", Bundle.main.bundleURL.path, "--args", "prompt-contacts"]
        try? open.run()
        open.waitUntilExit()
    }

case .promptContacts:
    let granted = (try? await CNContactStore().requestAccess(for: .contacts)) ?? false
    print(granted ? "contacts: granted" : "contacts: denied")

case .status:
    if let entry = AgentStatusFile(folder: support).read() {
        print("the running agent's last snapshot:")
        printJSON(entry)
    } else {
        print("no snapshot from a running agent; readouts below are this terminal's own, not the agent's")
    }
    let config = CompanionConfig.load(from: configURL)
    let names = ContactsNameResolver()
    let status = StatusSnapshot.make(config: config, agentVersion: agentVersion, reader: CompanionStatus(state: .idle),
                                     sender: CompanionSendStatus(state: config.sendsEnabled ? .waiting : .off),
                                     permissions: permissions(names, LastScriptResult()), remotePaused: false,
                                     watcherRestarts: 0, forkRunning: RunningForkDetector().isForkRunning(),
                                     update: UpdateState.load(from: updaterPaths.state))
    printJSON(status)
    if let mark = HealthMarkStore(folder: support).read() { printJSON(mark) }
    if let result = PreflightFiles(folder: support).result() { printJSON(result) }

case .pause, .resume:
    do { try ConfigEdits.setPaused(command == .pause, configURL: configURL) } catch { fail("couldn't save the config") }
    print(command == .pause ? "paused" : "resumed")

case .sendsOn, .sendsOff:
    do {
        try ConfigEdits.setSendsEnabled(command == .sendsOn, configURL: configURL)
    } catch {
        fail("couldn't save the config")
    }
    print(command == .sendsOn ? "sends on" : "sends off")

case .update:
    await runUpdate()

case .resetCursor:
    do { try ConfigEdits.resetCursor(configURL: configURL) } catch { fail("couldn't save the config") }
    print("cursor reset: the next read starts from the first-run window")

case .presentNow:
    do { try PresentFiles(folder: support).request() } catch { fail("couldn't write the request") }
    print("requested; the running agent writes present-result.json once its reader is idle")

case .preflight(let chatRowID):
    do { try PreflightFiles(folder: support).request(chatRowID: chatRowID) } catch { fail("couldn't write the request") }
    print("requested; the running agent writes preflight-result.json (see `imsg-companion status`)")
}

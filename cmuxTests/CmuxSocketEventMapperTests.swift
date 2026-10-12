import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite(.serialized)
struct CmuxSocketEventMapperTests {
    @Test
    func paneResizeEventDistinguishesAppliedFromRemoteRequested() {
        CmuxEventBus.shared.resetForTesting()
        defer { CmuxEventBus.shared.resetForTesting() }
        let command = #"{"id":1,"method":"pane.resize","params":{"direction":"right","amount":10}}"#
        let localResponse = #"{"id":1,"ok":true,"result":{"pane_id":"local-pane"}}"#
        let remoteResponse = #"{"id":1,"ok":true,"result":{"pane_id":"remote-pane","remote":true}}"#

        CmuxSocketEventMapper.publish(command: command, response: localResponse)
        CmuxSocketEventMapper.publish(command: command, response: remoteResponse)

        let events = CmuxEventBus.shared.retainedSnapshot()
        #expect(events.compactMap { $0["name"] as? String } == [
            "pane.resized",
            "pane.resize_requested",
        ])
        #expect(events.compactMap { $0["pane_id"] as? String } == [
            "local-pane",
            "remote-pane",
        ])
    }

    // cmux-rbf (#cm-119.2): `reload_config` answers `ERROR: cmux.json can't be read: ...` when the
    // terminal config reloaded and cmux.json could not be read. The mapper must still publish
    // `config.reloaded` for that answer (AutomationEngine reloads automations.json on it) and for
    // no other `ERROR` answer. Reject a revert of this test on upstream sync.
    struct V1Row: CustomTestStringConvertible, Sendable {
        let name: String
        let command: String
        let response: String
        let publishes: Bool
        var testDescription: String { name }
    }

    static let unreadableFileAnswer = CmuxSettingsFileReadState
        .notRead(CmuxSettingsFileReadFailure(path: "/tmp/x/cmux.json", reason: .doesNotParse, line: 4, words: "No value for key in object"))
        .reloadConfigAnswer

    static let reloadConfigRows: [V1Row] = [
        V1Row(name: "reload_config, OK Reloaded config", command: "reload_config", response: "OK Reloaded config", publishes: true),
        V1Row(name: "reload_config, cmux.json can't be read", command: "reload_config", response: unreadableFileAnswer, publishes: true),
        V1Row(name: "reload_config, failed", command: "reload_config", response: "ERROR: reload_config failed", publishes: false),
        V1Row(name: "reload_config, busy", command: "reload_config", response: "ERROR: reload_config busy", publishes: false),
        V1Row(name: "reload_config, timed out", command: "reload_config", response: "ERROR: reload_config timed out", publishes: false),
        V1Row(name: "reload_config, usage", command: "reload_config", response: "ERROR: Usage: reload_config", publishes: false),
        V1Row(name: "another command with the same answer", command: "notify title", response: unreadableFileAnswer, publishes: false),
    ]

    @Test(arguments: reloadConfigRows)
    func configReloadedIsPublishedOnlyWhenTheTerminalConfigReloaded(row: V1Row) {
        CmuxEventBus.shared.resetForTesting()
        defer { CmuxEventBus.shared.resetForTesting() }

        CmuxSocketEventMapper.publish(command: row.command, response: row.response)

        let names = CmuxEventBus.shared.retainedSnapshot().compactMap { $0["name"] as? String }
        #expect(names == (row.publishes ? ["config.reloaded"] : []))
    }
}

import Foundation
@testable import SecretAgentMan
import Testing

struct UsageMonitorTests {
    // MARK: - Claude Parsing

    @Test
    func parseClaudeAgentStatusWithValidData() throws {
        let json: [String: Any] = [
            "session_id": "test-session",
            "rate_limits": [
                "five_hour": [
                    "used_percentage": 29.0,
                    "resets_at": 1_775_685_600.0,
                ],
                "seven_day": [
                    "used_percentage": 5.0,
                    "resets_at": 1_776_276_000.0,
                ],
            ],
        ]
        let data = try JSONSerialization.data(withJSONObject: json)

        let result = UsageMonitor.parseClaudeAgentStatus(data)

        #expect(result != nil)
        #expect(result?.shortWindow.usedPercent == 29.0)
        #expect(result?.shortWindow.windowLabel == "5h")
        #expect(result?.shortWindow.resetsAt == Date(timeIntervalSince1970: 1_775_685_600))
        #expect(result?.longWindow.usedPercent == 5.0)
        #expect(result?.longWindow.windowLabel == "7d")
    }

    @Test
    func parseClaudeAgentStatusMissingRateLimits() throws {
        let json: [String: Any] = ["session_id": "test"]
        let data = try JSONSerialization.data(withJSONObject: json)

        #expect(UsageMonitor.parseClaudeAgentStatus(data) == nil)
    }

    @Test
    func parseClaudeAgentStatusMissingOneWindow() throws {
        let json: [String: Any] = [
            "rate_limits": [
                "five_hour": [
                    "used_percentage": 50.0,
                    "resets_at": 1_000_000.0,
                ],
            ],
        ]
        let data = try JSONSerialization.data(withJSONObject: json)

        #expect(UsageMonitor.parseClaudeAgentStatus(data) == nil)
    }

    @Test
    func parseClaudeAgentStatusInvalidJSON() {
        let data = Data("not json".utf8)

        #expect(UsageMonitor.parseClaudeAgentStatus(data) == nil)
    }

    // MARK: - Codex Parsing

    @Test
    func parseCodexSessionFindsLastTokenCount() {
        let tokenCount1 = codexTokenCountLine(primary: 10.0, secondary: 2.0)
        let tokenCount2 = codexTokenCountLine(primary: 49.0, secondary: 8.0)
        let other = """
        {"type":"event_msg","payload":{"type":"agent_message"}}
        """
        let content = [tokenCount1, other, tokenCount2].joined(separator: "\n")

        let result = UsageMonitor.parseCodexSessionContent(content)

        // Should find the LAST token_count (49%, not 10%)
        #expect(result != nil)
        #expect(result?.shortWindow.usedPercent == 49.0)
        #expect(result?.longWindow.usedPercent == 8.0)
    }

    @Test
    func parseCodexSessionDerivesWindowLabels() {
        let content = codexTokenCountLine(primary: 50.0, secondary: 10.0)

        let result = UsageMonitor.parseCodexSessionContent(content)

        #expect(result?.shortWindow.windowLabel == "5h")
        #expect(result?.longWindow.windowLabel == "7d")
    }

    @Test
    func parseCodexSessionNoTokenCountEvents() {
        let content = """
        {"type":"session_meta","payload":{"id":"test","cwd":"/tmp"}}
        {"type":"event_msg","payload":{"type":"agent_message"}}
        """

        #expect(UsageMonitor.parseCodexSessionContent(content) == nil)
    }

    @Test
    func parseCodexSessionEmptyContent() {
        #expect(UsageMonitor.parseCodexSessionContent("") == nil)
    }

    // MARK: - Window Parsing

    @Test
    func parseWindowWithAllFields() {
        let dict: [String: Any] = [
            "used_percent": 75.5,
            "resets_at": 1_775_685_600.0,
            "window_minutes": 300,
        ]

        let result = UsageMonitor.parseWindow(
            dict, percentKey: "used_percent", label: "fallback"
        )

        #expect(result?.usedPercent == 75.5)
        #expect(result?.resetsAt == Date(timeIntervalSince1970: 1_775_685_600))
        #expect(result?.windowLabel == "5h")
    }

    @Test
    func parseWindowFallsBackToLabel() {
        let dict: [String: Any] = ["used_percent": 30.0]

        let result = UsageMonitor.parseWindow(
            dict, percentKey: "used_percent", label: "5h"
        )

        #expect(result?.usedPercent == 30.0)
        #expect(result?.resetsAt == nil)
        #expect(result?.windowLabel == "5h")
    }

    @Test
    func parseWindowNilDict() {
        #expect(
            UsageMonitor.parseWindow(nil, percentKey: "used_percent", label: "5h") == nil
        )
    }

    @Test
    func parseWindowMissingPercent() {
        let dict: [String: Any] = ["resets_at": 1_000_000.0]

        #expect(
            UsageMonitor.parseWindow(dict, percentKey: "used_percent", label: "5h") == nil
        )
    }

    @Test
    func parseWindowMinutesLabels() {
        // Under 120 min -> show minutes
        let m60: [String: Any] = ["used_percent": 1.0, "window_minutes": 60]
        #expect(
            UsageMonitor.parseWindow(m60, percentKey: "used_percent", label: "")?.windowLabel
                == "60m"
        )

        // 120..1440 -> show hours
        let m300: [String: Any] = ["used_percent": 1.0, "window_minutes": 300]
        #expect(
            UsageMonitor.parseWindow(m300, percentKey: "used_percent", label: "")?.windowLabel
                == "5h"
        )

        // >= 1440 -> show days
        let m10080: [String: Any] = ["used_percent": 1.0, "window_minutes": 10080]
        #expect(
            UsageMonitor.parseWindow(m10080, percentKey: "used_percent", label: "")?.windowLabel
                == "7d"
        )
    }

    // MARK: - Helpers

    private func codexTokenCountLine(primary: Double, secondary: Double) -> String {
        """
        {"type":"event_msg","payload":{"type":"token_count",\
        "rate_limits":{"primary":{"used_percent":\(primary),\
        "window_minutes":300,"resets_at":1000000},\
        "secondary":{"used_percent":\(secondary),\
        "window_minutes":10080,"resets_at":2000000}}}}
        """
    }
}

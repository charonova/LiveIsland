import Foundation

/// Transcript lines shaped like the real ones Claude Code and Codex write.
enum Fixture {
    static func data(_ text: String) -> Data { Data(text.utf8) }

    static func claudeAssistant(
        id: String = "msg_01ABC", at timestamp: String = "2026-10-22T10:15:00.000Z", stop: String? = "tool_use",
        input: Int = 10, output: Int = 200, cacheWrite: Int = 300, cacheRead: Int = 4_000,
        content: String = #"[{"type":"text","text":"Running the build"}]"#
    ) -> String {
        let reason = stop.map { "\"\($0)\"" } ?? "null"
        return #"{"parentUuid":"p1","isSidechain":false,"cwd":"/Users/me/Code/app","sessionId":"s1","message":{"model":"claude-opus-5-5","id":"\#(id)","type":"message","role":"assistant","content":\#(content),"stop_reason":\#(reason),"usage":{"input_tokens":\#(input),"cache_creation_input_tokens":\#(cacheWrite),"cache_read_input_tokens":\#(cacheRead),"output_tokens":\#(output),"server_tool_use":{"web_search_requests":0},"cache_creation":{"ephemeral_1h_input_tokens":\#(cacheWrite)}}},"requestId":"req_1","type":"assistant","uuid":"u1","timestamp":"\#(timestamp)"}"#
    }

    static func claudePrompt(at timestamp: String = "2026-10-22T10:14:00.000Z", text: String = "build it") -> String {
        #"{"parentUuid":null,"cwd":"/Users/me/Code/app","message":{"role":"user","content":"\#(text)"},"type":"user","uuid":"u0","timestamp":"\#(timestamp)"}"#
    }

    static func claudeToolResult(at timestamp: String = "2026-10-22T10:15:05.000Z") -> String {
        #"{"cwd":"/Users/me/Code/app","message":{"role":"user","content":[{"tool_use_id":"toolu_1","type":"tool_result","content":"ok"}]},"type":"user","uuid":"u2","timestamp":"\#(timestamp)"}"#
    }

    static let claudeTitle = #"{"type":"ai-title","aiTitle":"Fix the \"login\" bug","sessionId":"s1"}"#

    static let claudeLimit = #"{"type":"assistant","isApiErrorMessage":true,"apiErrorParams":{"rate_limit_info":{"status":"rejected","resetsAt":1792818000,"rateLimitType":"seven_day","overageStatus":"rejected"}},"timestamp":"2026-10-20T08:00:00.000Z"}"#

    static func codexTokenCount(primaryUsed: Double = 12.5, resets: String = #""resets_at":1792837722"#, total: Int = 52_000) -> String {
        #"{"timestamp":"2026-10-16T15:20:00.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":50000,"output_tokens":2000,"total_tokens":\#(total)},"last_token_usage":{"total_tokens":900},"model_context_window":272000},"rate_limits":{"limit_id":"codex","primary":{"used_percent":\#(primaryUsed),"window_minutes":300,\#(resets)},"secondary":{"used_percent":40.0,"window_minutes":10080,"resets_at":1793000000},"credits":{"has_credits":false}}}}"#
    }

    static let codexMeta = #"{"timestamp":"2026-10-16T15:05:16.000Z","type":"session_meta","payload":{"id":"abc","cwd":"/Users/me/Code/api","cli_version":"0.99.0"}}"#

    static func codexEvent(_ type: String, at timestamp: String) -> String {
        #"{"timestamp":"\#(timestamp)","type":"event_msg","payload":{"type":"\#(type)"}}"#
    }
}

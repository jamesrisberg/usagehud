import Foundation
@testable import UsageHUDKit

/// times; Codex's `wham/usage` answer and session log record are real reads (2026-10-13) with
/// every identifier (user, account, email) removed.
enum Fixtures {
    /// 2026-10-13T16:00:00Z
    static let now = Date(timeIntervalSince1970: 1_791_907_200)

    static let claudeUsage = """
    {
      "five_hour": {"utilization": 42.0, "resets_at": "2026-10-13T18:13:00.493577+00:00"},
      "seven_day": {"utilization": 23.0, "resets_at": "2026-10-16T03:00:00.493604+00:00"},
      "seven_day_oauth_apps": null,
      "seven_day_opus": {"utilization": 0.0, "resets_at": null},
      "seven_day_sonnet": null,
      "seven_day_cowork": {"utilization": 0.0, "resets_at": null},
      "iguana_necktie": {"utilization": 58.0, "resets_at": "2026-10-16T03:00:00.493617+00:00"},
      "extra_usage": {"is_enabled": false, "monthly_limit": null, "used_credits": null, "utilization": null},
      "limits": [
        {"kind": "weekly_scoped", "percent": 61, "is_active": true, "resets_at": "2026-10-16T03:00:00Z",
         "scope": {"model": {"display_name": "Fable 5"}}}
      ]
    }
    """

    static let claudeUsageWithoutLimits = """
    {
      "five_hour": {"utilization": 130, "resets_at": 1791915180},
      "seven_day": {"utilization": -3, "resets_at": 1792119600000},
      "iguana_necktie": {"utilization": 90, "resets_at": "2026-10-16T03:00:00Z"}
    }
    """

    /// The real `wham/usage` answer: a Pro plan with one weekly window and credits.
    static let codexUsage = """
    {
      "plan_type": "pro",
      "rate_limit": {
        "allowed": true,
        "limit_reached": false,
        "primary_window": {"used_percent": 0, "limit_window_seconds": 604800, "reset_after_seconds": 604516, "reset_at": 1792511708},
        "secondary_window": null
      },
      "code_review_rate_limit": null,
      "additional_rate_limits": null,
      "model_usage": {"gpt-6-astra": {"available": true, "available_at": null, "credits_would_enable": false}},
      "credits": {
        "has_credits": true, "unlimited": false, "overage_limit_reached": false,
        "balance": "62500.0000000000", "approx_local_messages": [15625, 81250], "approx_cloud_messages": [2500, 15625]
      },
      "spend_control": {"reached": false, "individual_limit": null},
      "rate_limit_reached_type": null,
      "promo": null,
      "rate_limit_reset_credits": {"available_count": 2, "applicable_available_count": 0}
    }
    """

    /// The reference's two-window shape, listed long window first.
    static let codexUsageTwoWindows = """
    {
      "plan_type": "plus",
      "rate_limit": {
        "primary_window": {"used_percent": 10, "limit_window_seconds": 604800, "reset_at": "2026-10-17T09:00:00Z"},
        "secondary_window": {"used_percent": 62.2, "limit_window_seconds": 18000, "reset_after_seconds": 4080}
      }
    }
    """

    /// A real `token_count` record (the shape Codex writes every turn).
    static func sessionRecord(timestamp: String, usedPercent: Double, windowMinutes: Int = 10080,
                              resetsAt: Int = 1_792_511_708, secondary: String = "null") -> String {
        #"{"timestamp":"\#(timestamp)","ordinal":12,"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":1200,"output_tokens":300}},"rate_limits":{"limit_id":"codex","limit_name":null,"primary":{"used_percent":\#(usedPercent),"window_minutes":\#(windowMinutes),"resets_at":\#(resetsAt)},"secondary":\#(secondary),"credits":{"has_credits":true,"unlimited":false,"balance":"62500.0000000000"},"individual_limit":null,"spend_control_reached":null,"plan_type":"pro","rate_limit_reached_type":null}}}"#
    }

    static let sessionLog = [
        #"{"timestamp":"2026-10-13T15:00:00.000Z","type":"session_meta","payload":{"id":"x","cwd":"/tmp"}}"#,
        sessionRecord(timestamp: "2026-10-13T15:10:00.000Z", usedPercent: 3),
        #"{"timestamp":"2026-10-13T15:20:00.000Z","type":"response_item","payload":{"type":"message","content":[{"type":"output_text","text":"no rate_limits here"}]}}"#,
        sessionRecord(timestamp: "2026-10-13T15:58:42.070Z", usedPercent: 4.5,
                      secondary: #"{"used_percent":71,"window_minutes":300,"resets_at":1791910800}"#),
        #"{"timestamp":"2026-10-13T15:59:00.000Z","type":"event_msg","payload":{"type":"token_count","info":null,"rate_limits":null}}"#,
    ].joined(separator: "\n") + "\n"

    // MARK: Credentials

    static let claudeAccess = "sk-ant-oat01-ACCESS-fixture"
    static let claudeRefresh = "sk-ant-ort01-REFRESH-fixture"

    static func claudeCredentials(access: String = claudeAccess, expiresAt: Date) -> Data {
        Data(#"{"claudeAiOauth":{"accessToken":"\#(access)","refreshToken":"\#(claudeRefresh)","expiresAt":\#(Int(expiresAt.timeIntervalSince1970 * 1000)),"scopes":["user:inference","user:profile"],"subscriptionType":"max"}}"#.utf8)
    }

    static let codexRefresh = "codex-REFRESH-fixture"

    /// An unsigned JWT whose payload is `{"exp": <expiry>}`.
    static func jwt(expiresAt: Date, marker: String = "A") -> String {
        func b64(_ s: String) -> String {
            Data(s.utf8).base64EncodedString().replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        }
        return b64(#"{"alg":"none"}"#) + "." + b64(#"{"exp":\#(Int(expiresAt.timeIntervalSince1970)),"m":"\#(marker)"}"#) + ".sig"
    }

    static func codexAuth(access: String, accountID: String = "acct-fixture") -> Data {
        Data(#"{"auth_mode":"chatgpt","OPENAI_API_KEY":null,"tokens":{"id_token":"id","access_token":"\#(access)","refresh_token":"\#(codexRefresh)","account_id":"\#(accountID)"},"last_refresh":"2026-10-13T10:00:00Z"}"#.utf8)
    }
}

import Foundation
import Testing

@testable import AgentModeCore

/// Contract for `ProbeEvaluator` (design §8.4 P1; plan "Enfoque de revisión" item 1).
/// Any HTTP status from api.anthropic.com counts as internet; captive.apple.com counts only with
/// 200 and a body containing "Success", so a captive portal login page counts as offline.
@Suite struct ProbeEvaluatorTests {
    static let anthropic = URL(string: "https://api.anthropic.com")!
    static let captive = URL(string: "https://captive.apple.com/hotspot-detect.html")!
    static let appleSuccessBody = "<HTML><HEAD><TITLE>Success</TITLE></HEAD><BODY>Success</BODY></HTML>"
    static let portalLoginBody = """
        <html><head><title>Hotel Example Guest Wi-Fi</title></head>
        <body><form action="/login" method="post">Room number <input name="room"></form></body></html>
        """

    @Test(arguments: [200, 401, 404])
    func anthropicAnyHTTPStatusIsReachable(statusCode: Int) {
        #expect(ProbeEvaluator.isReachable(url: Self.anthropic, statusCode: statusCode, body: nil))
    }

    @Test func anthropicWithoutStatusIsUnreachable() {
        #expect(!ProbeEvaluator.isReachable(url: Self.anthropic, statusCode: nil, body: nil))
    }

    @Test func captiveSuccessIsReachable() {
        #expect(ProbeEvaluator.isReachable(url: Self.captive, statusCode: 200, body: Self.appleSuccessBody))
    }

    @Test func captivePortalPageCountsAsOffline() {
        #expect(!ProbeEvaluator.isReachable(url: Self.captive, statusCode: 200, body: Self.portalLoginBody))
    }

    // Edge of the same rule: captive.apple.com without a 200 is offline even if a body says "Success".
    @Test(arguments: [302 as Int?, 404 as Int?, nil])
    func captiveWithoutOKStatusIsOffline(statusCode: Int?) {
        #expect(!ProbeEvaluator.isReachable(url: Self.captive, statusCode: statusCode, body: Self.appleSuccessBody))
    }
}

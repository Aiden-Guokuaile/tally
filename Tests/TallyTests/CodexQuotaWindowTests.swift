import XCTest
@testable import Tally

final class CodexQuotaWindowTests: XCTestCase {

    private func limit(_ used: Double) -> UsageLimit { UsageLimit(used: used, limit: 100) }

    func testSingleWeeklyWindowGoesToWeekSlot() {
        // 本机账号实测：只有一个 604800 秒的 primary_window
        let r = CodexQuotaClient.assign(windows: [(seconds: 604_800, limit: limit(33))])
        XCTAssertNil(r.session)
        XCTAssertEqual(r.week?.used, 33)
    }

    func testFiveHourAndWeeklyWindowsBothAssigned() {
        let r = CodexQuotaClient.assign(windows: [(seconds: 18_000, limit: limit(10)), (seconds: 604_800, limit: limit(40))])
        XCTAssertEqual(r.session?.used, 10)
        XCTAssertEqual(r.week?.used, 40)
    }

    func testMissingLengthFallsBackToPosition() {
        let r = CodexQuotaClient.assign(windows: [(seconds: nil, limit: limit(1)), (seconds: nil, limit: limit(2))])
        XCTAssertEqual(r.session?.used, 1)
        XCTAssertEqual(r.week?.used, 2)
    }

    func testTwoWindowsInSameSlotKeepFirst() {
        let r = CodexQuotaClient.assign(windows: [(seconds: 604_800, limit: limit(5)), (seconds: 2_592_000, limit: limit(9))])
        XCTAssertNil(r.session)
        XCTAssertEqual(r.week?.used, 5)
    }

    /// 登录过期（access_token 有效期 10 天）时界面要说人话，不能只是静默少两条配额。
    func testAuthFailureGetsNote() {
        XCTAssertEqual(CodexQuotaClient.authNote(status: 401), "登录已过期，去 Codex 跑一轮")
        XCTAssertEqual(CodexQuotaClient.authNote(status: 403), "登录已过期，去 Codex 跑一轮")
    }

    /// 网络断、5xx、响应变形不是用户能动手解决的，不写提示，只留日志。
    func testNonAuthFailureGetsNoNote() {
        XCTAssertNil(CodexQuotaClient.authNote(status: 500))
        XCTAssertNil(CodexQuotaClient.authNote(status: 200))
        XCTAssertNil(CodexQuotaClient.authNote(status: -1))
    }
}

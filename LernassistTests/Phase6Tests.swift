import XCTest
@testable import Lernassist

final class Phase6Tests: XCTestCase {
    func testDisplayTextRoundTripsAndDoesNotChangeModelContent() throws {
        var msg = ChatMessage(role: "user", content: "Recherchiere ausführlich zu X …")
        msg.displayText = "/search X"
        let data = try JSONEncoder().encode(msg)
        let decoded = try JSONDecoder().decode(ChatMessage.self, from: data)
        XCTAssertEqual(decoded.displayText, "/search X")
        XCTAssertEqual(decoded.content, "Recherchiere ausführlich zu X …")
    }

    func testOldMessagesWithoutDisplayTextStillDecode() throws {
        let json = #"{"id":"\#(UUID().uuidString)","role":"user","content":"Hallo"}"#
        let decoded = try JSONDecoder().decode(ChatMessage.self, from: Data(json.utf8))
        XCTAssertNil(decoded.displayText)
    }
}

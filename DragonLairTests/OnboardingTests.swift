import Testing
@testable import DragonLair

struct KeyFormatTests {
    @Test func acceptsEachProvidersKeyShape() {
        #expect(AIProviderKind.gemini.keyLooksValid("AIzaSyA1b2C3d4E5f6G7h8I9j0KlMnOpQrStUv"))
        #expect(AIProviderKind.claude.keyLooksValid("sk-ant-api03-abcdefghijklmnopqrstuvwxyz"))
        #expect(AIProviderKind.openai.keyLooksValid("sk-proj-abcdefghijklmnopqrstuvwxyz"))
    }

    @Test func trimsWhitespaceAroundAPaste() {
        #expect(AIProviderKind.gemini.keyLooksValid("  AIzaSyA1b2C3d4E5f6G7h8I9j0KlMnOpQrStUv\n"))
    }

    @Test func rejectsWrongPastes() {
        // A password, half a key, a key with a space in it.
        #expect(!AIProviderKind.gemini.keyLooksValid("my-google-password"))
        #expect(!AIProviderKind.gemini.keyLooksValid("AIzaSyA1b2"))
        #expect(!AIProviderKind.gemini.keyLooksValid("AIzaSyA1b2C3d4E5 f6G7h8I9j0KlMnOp"))
    }

    @Test func rejectsAnotherProvidersKey() {
        #expect(!AIProviderKind.openai.keyLooksValid("sk-ant-api03-abcdefghijklmnopqrstuvwxyz"))
        #expect(!AIProviderKind.claude.keyLooksValid("sk-proj-abcdefghijklmnopqrstuvwxyz"))
        #expect(!AIProviderKind.gemini.keyLooksValid("sk-proj-abcdefghijklmnopqrstuvwxyz"))
    }
}

struct KeyCheckTests {
    @Test func readsTheProvidersAnswer() {
        #expect(AIClient.keyCheck(status: 200, provider: .claude) == .works)
        #expect(AIClient.keyCheck(status: 401, provider: .claude) == .rejected)
        #expect(AIClient.keyCheck(status: 403, provider: .openai) == .rejected)
        #expect(AIClient.keyCheck(status: 400, provider: .gemini) == .rejected)
    }

    @Test func busyOrOddAnswersAreNotCalledABadKey() {
        #expect(AIClient.keyCheck(status: 429, provider: .gemini) != .rejected)
        #expect(AIClient.keyCheck(status: 503, provider: .claude) != .rejected)
        #expect(AIClient.keyCheck(status: 400, provider: .openai) != .rejected)
    }
}

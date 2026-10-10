import ArgumentParser
import CCCore
import CCMCP

/// stdio MCP サーバー（Claude Code / Hermes から起動される）。Wave 0 では起動の枠だけ。
@main
struct CCMCPCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "cc-mcp",
        abstract: "Context Capture の記録を MCP で公開する（stdio）"
    )

    func run() async throws {
        throw ValidationError("cc-mcp はまだ実装されていない（Wave 4）")
    }
}

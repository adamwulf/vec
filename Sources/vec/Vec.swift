import Foundation
import ArgumentParser
import VecKit

@main
struct Vec: AsyncParsableCommand {

    static var configuration = CommandConfiguration(
        commandName: "vec",
        abstract: "A CLI tool for creating and querying local vector databases",
        version: "0.1.0",
        subcommands: [
            InitCommand.self,
            DeinitCommand.self,
            UpdateIndexCommand.self,
            SearchCommand.self,
            InsertCommand.self,
            RemoveCommand.self,
            ListCommand.self,
            InfoCommand.self,
            ChunkCommand.self,
            ResetCommand.self
        ],
        defaultSubcommand: SearchCommand.self
    )
}

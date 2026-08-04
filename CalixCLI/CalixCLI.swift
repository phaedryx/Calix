//
//  CalixCLI.swift
//  CalixCLI
//
//  Entry point for the Calix command-line tool.
//

import ArgumentParser

@main
struct CalixCLI: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "calix",
        abstract: "Calix terminal CLI",
        subcommands: [BrowserCommand.self]
    )
}

struct BrowserCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "browser",
        abstract: "Browser automation commands",
        subcommands: [
            BrowserList.self,
            BrowserOpen.self,
            BrowserNavigate.self,
            BrowserSnapshot.self,
            BrowserScreenshot.self,
            BrowserClick.self,
            BrowserFill.self,
            BrowserType.self,
            BrowserPress.self,
            BrowserSelect.self,
            BrowserCheck.self,
            BrowserUncheck.self,
            BrowserGetText.self,
            BrowserGetHTML.self,
            BrowserEval.self,
            BrowserWait.self,
            BrowserBack.self,
            BrowserForward.self,
            BrowserReload.self,
            BrowserGetAttribute.self,
            BrowserGetLinks.self,
            BrowserGetInputs.self,
            BrowserIsVisible.self,
            BrowserHover.self,
            BrowserScroll.self,
        ]
    )
}

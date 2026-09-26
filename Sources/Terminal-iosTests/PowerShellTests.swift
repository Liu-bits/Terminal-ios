// Copyright © 2026 Liu-bits. All rights reserved.

@testable import Terminal_ios
import Foundation
import Testing

/// The PowerShell cmdlet surface and the `winget` UX, driven through the shell.
struct PowerShellTests {

    private func makeEngine() -> ShellEngine {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return ShellEngine(environment: ShellEnvironment(root: root))
    }

    @Test("locations and items behave like their cmdlets")
    func locationsAndItems() throws {
        let engine = makeEngine()
        #expect(engine.run("Get-Location").output == "~")
        #expect(engine.run("gl").output == "~")
        #expect(engine.run("get-location").output == "~")
        #expect(engine.run("Set-Location /").exitCode == 0)
        #expect(engine.run("New-Item -ItemType directory -Path ps/dir").exitCode == 0)
        #expect(engine.run("New-Item -ItemType file -Path ps/dir/a.txt").exitCode == 0)
        #expect(engine.run("Test-Path ps/dir/a.txt").output == "True")
        #expect(engine.run("Test-Path ps/missing").output == "False")
        #expect(engine.run("gci -Path ps/dir").output.contains("a.txt"))
        #expect(engine.run("Get-ChildItem -Path ps/dir -Filter '*.txt'").output.contains("a.txt"))
        #expect(engine.run("Get-ChildItem -Path ps -Recurse").output.contains("a.txt"))
        #expect(engine.run("Get-PSDrive").output.contains("Sandbox"))
        #expect(engine.run("Get-Item -Path ps/dir").output.contains("Directory"))
    }

    @Test("content cmdlets read and write line-terminated records")
    func content() throws {
        let engine = makeEngine()
        #expect(engine.run("New-Item -ItemType directory -Path w").exitCode == 0)
        #expect(engine.run("Set-Content -Path w/a.txt -Value alpha").exitCode == 0)
        #expect(engine.run("Add-Content -Path w/a.txt -Value beta").exitCode == 0)
        #expect(engine.run("Get-Content -Path w/a.txt").output == "alpha\nbeta")
        #expect(engine.run("Get-Content -Path w/a.txt -Head 1").output == "alpha")
        #expect(engine.run("Get-Content -Path w/a.txt -Tail 1").output == "beta")
        #expect(engine.run("gc -Path w/a.txt").output == "alpha\nbeta")
        #expect(engine.run("Get-Content -Path w/none.txt").exitCode == 1)
    }

    @Test("item cmdlets reuse the POSIX implementations")
    func itemManipulation() throws {
        let engine = makeEngine()
        #expect(engine.run("New-Item -ItemType directory -Path m").exitCode == 0)
        #expect(engine.run("Set-Content -Path m/a.txt -Value one").exitCode == 0)
        #expect(engine.run("Copy-Item -Path m/a.txt -Destination m/b.txt").exitCode == 0)
        #expect(engine.run("Rename-Item -Path m/b.txt -NewName c.txt").exitCode == 0)
        #expect(engine.run("Move-Item -Path m/c.txt -Destination m/d.txt").exitCode == 0)
        #expect(engine.run("Get-ChildItem -Path m").output == "a.txt\nd.txt")
        #expect(engine.run("Remove-Item -Path m/a.txt").exitCode == 0)
        #expect(engine.run("Remove-Item -Path m -Recurse -Force").exitCode == 0)
        #expect(engine.run("Test-Path m").output == "False")
        #expect(engine.run("Remove-Item -Path nope.txt").exitCode == 1)
    }

    @Test("pipeline cmdlets filter, count and select")
    func pipelineCmdlets() throws {
        let engine = makeEngine()
        _ = engine.run("Set-Content -Path list.txt -Value alpha")
        _ = engine.run("Add-Content -Path list.txt -Value beta")
        _ = engine.run("Add-Content -Path list.txt -Value alpha")
        #expect(engine.run("Get-Content -Path list.txt | Select-String -Pattern beta").output == "2:beta")
        #expect(engine.run("Get-Content -Path list.txt | Select-String -Pattern alpha -NotMatch").output == "2:beta")
        #expect(engine.run("Get-Content -Path list.txt | Measure-Object -Line").output.contains("Lines          : 3"))
        #expect(engine.run("Get-Content -Path list.txt | Sort-Object -Descending").output == "beta\nalpha\nalpha")
        #expect(engine.run("Get-Content -Path list.txt | Sort-Object -Unique").output == "alpha\nbeta")
        #expect(engine.run("Get-Content -Path list.txt | Select-Object -First 2").output == "alpha\nbeta")
        #expect(engine.run("Get-Content -Path list.txt | Select-Object -Last 1").output == "alpha")
        #expect(engine.run("Get-Content -Path list.txt | Select-Object -Skip 1").output == "beta\nalpha")
        #expect(engine.run("Get-Content -Path list.txt | Where-Object -Match beta").output == "beta")
        #expect(engine.run("Get-Content -Path list.txt | Where-Object -Match beta -NotMatch").output == "alpha\nalpha")
    }

    @Test("help and introspection cover both command families")
    func introspection() throws {
        let engine = makeEngine()
        #expect(engine.run("Write-Output hello ps").output == "hello ps")
        #expect(engine.run("Get-Command -Name select-string").output.contains("Select-String"))
        #expect(engine.run("Get-Help Select-String").output.contains("search for text"))
        #expect(engine.run("Get-Help ls").output.contains("list directory contents"))
        #expect(engine.run("Get-Date").output.contains(","))
        #expect(engine.run("Start-Sleep -Seconds 0").exitCode == 0)
        #expect(engine.run("Get-Process").output.contains("Terminal-ios"))
        #expect(engine.run("type Get-ChildItem").output.contains("shell built-in"))
        #expect(engine.run("help").output.contains("PowerShell cmdlets"))
    }

    @Test("winget drives the catalogs")
    func winget() throws {
        let engine = makeEngine()
        #expect(engine.run("winget --version").output.hasPrefix("v"))
        #expect(engine.run("winget search hello").output.contains("Terminal-ios.hello"))
        #expect(engine.run("winget show Terminal-ios.hello").output.contains("Id: Terminal-ios.hello"))
        #expect(engine.run("winget list").output.contains("Terminal-ios.hello"))
        #expect(engine.run("winget install Terminal-ios.hello").exitCode == 0)
        #expect(engine.run("winget install Terminal-ios.hello").output.contains("Successfully installed"))
        #expect(engine.run("hello winget").output == "hello, winget")
        #expect(engine.run("winget install nosuch.package").exitCode == 1)
        #expect(engine.run("winget source list").output.contains("Allowed hosts"))
        #expect(engine.run("winget source add evil https://evil.example.com/c.json").exitCode == 1)
        #expect(engine.run("winget uninstall Terminal-ios.hello").exitCode == 0)
        #expect(engine.run("hello").exitCode == 127)
        #expect(engine.run("winget help").exitCode == 2)
    }
}

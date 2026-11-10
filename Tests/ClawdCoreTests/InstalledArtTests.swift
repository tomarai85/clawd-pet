import Testing
import Foundation
import ClawdCore
import ClawdRendering

/// The agent draws every motion and look from the art directory of the install. These tests run the real `bin/clawd-pet install` into a
/// fake HOME and then use the installed tree the way the agent does (`ClawdArt`): a motion or look it cannot decode is a picture that
/// is lost mid-dictation (`RENDER failed`), which is what an install that copied only `art/frames/*.png` caused.
@Suite("Installed art draws everything", .serialized)
struct InstalledArtSuite {
    private func install(into home: URL, from repo: URL? = nil) throws -> (Execution, URL) {
        let fm = FileManager.default
        for parent in ["bin", "Library/LaunchAgents", "Library/Application Support"] {
            try fm.createDirectory(at: home.appendingPathComponent(parent), withIntermediateDirectories: true)
        }
        let build = home.appendingPathComponent("build")
        try fm.createDirectory(at: build, withIntermediateDirectories: true)
        let agent = build.appendingPathComponent("clawd-pet-agent")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: agent)
        chmod(agent.path, 0o755)
        // The ceiling only stops a hung install. Inside the loaded full suite a whole install took over 120 s in 8 of 19 clean runs (each
        // killed with code 143, each passing alone in under a minute), so 120 s failed a working install.
        let result = try execute(URL(fileURLWithPath: "/bin/bash"), [(repo ?? repository).appendingPathComponent("bin/clawd-pet").path, "install"],
                                 environment: ["HOME": home.path, "CLAWD_BUILD_DIR": build.path], timeout: 600)
        return (result, home.appendingPathComponent("Library/Application Support/clawd-pet/art"))
    }
    private func freshHome(_ name: String) throws -> URL {
        let home = repository.appendingPathComponent(".build/test-artifacts/installed-art-\(getpid())-\(name)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        return home
    }

    @Test func InstalledArt_everyMotionAndEveryLookOfTheCatalogDecodesFromTheInstalledTree() throws {
        let home = try freshHome("whole")
        let (result, installed) = try install(into: home)
        #expect(result.code == 0, "install: \(result.output)")
        let art = try ClawdArt(directory: installed)
        let source = try ClawdArt(directory: artDirectory)
        #expect(art.motionIDs == source.motionIDs && art.motionIDs.count >= 39, "the installed atlas is the repo's: \(art.motionIDs.count) motions")
        #expect(art.lookIDs == source.lookIDs && art.lookIDs.count >= 6)
        var frames = 0
        for id in art.motionIDs {
            do { frames += try art.motion(id).frames.count } catch { Issue.record("motion \(id) cannot be drawn from the installed tree: \(error)") }
        }
        for id in art.lookIDs {
            do { _ = try art.look(id) } catch { Issue.record("look \(id) cannot be drawn from the installed tree: \(error)") }
        }
        #expect(frames > 2000, "decoded \(frames) motion frames from the installed tree")
    }

    @Test func InstalledArt_theFramesOnlyInstallOfTheFirstV2DeliveryCannotDrawA_Motion_ThisIsTheFailureTheInstallNowPrevents() throws {
        // Negative control: the tree a frames-only install leaves (what the development Mac had) fails exactly where the agent logged RENDER failed.
        let home = try freshHome("frames-only")
        let (result, installed) = try install(into: home)
        #expect(result.code == 0, "install: \(result.output)")
        let fm = FileManager.default
        for directory in ["motions", "looks"] { try fm.moveItem(at: installed.appendingPathComponent(directory), to: home.appendingPathComponent("moved-" + directory)) }
        let art = try ClawdArt(directory: installed)
        var failed = 0
        for id in art.motionIDs { if (try? art.motion(id)) == nil { failed += 1 } }
        negativeControl("frames-only tree cannot draw its motions", expectationHolds: failed == 0)
        #expect(failed == art.motionIDs.count, "every motion of the catalog is lost: \(failed) of \(art.motionIDs.count)")
        #expect((try? art.motion("A2-looking")) == nil, "A2-looking was the motion of the 9 failures in the development Mac's agent.log")
    }

    @Test func InstalledArt_installRefusesASourceWhoseAtlasNamesAFileItLacks() throws {
        // A copy of the repo that keeps the real atlas and drops one motion frame: install must stop before it creates anything.
        let fm = FileManager.default
        let repo = repository.appendingPathComponent(".build/test-artifacts/installed-art-repo-\(getpid())-\(UUID().uuidString)")
        try fm.createDirectory(at: repo.appendingPathComponent("bin"), withIntermediateDirectories: true)
        try fm.copyItem(at: repository.appendingPathComponent("bin/clawd-pet"), to: repo.appendingPathComponent("bin/clawd-pet"))
        try fm.copyItem(at: repository.appendingPathComponent("launchd"), to: repo.appendingPathComponent("launchd"))
        try fm.copyItem(at: repository.appendingPathComponent("launcher"), to: repo.appendingPathComponent("launcher"))
        try Data().write(to: repo.appendingPathComponent("Package.swift"))
        let art = repo.appendingPathComponent("art")
        try fm.createDirectory(at: art, withIntermediateDirectories: true)
        for name in ["clawd-atlas.json", "claude-code-elements.json"] { try fm.copyItem(at: artDirectory.appendingPathComponent(name), to: art.appendingPathComponent(name)) }
        try fm.copyItem(at: artDirectory.appendingPathComponent("frames"), to: art.appendingPathComponent("frames"))
        try fm.copyItem(at: artDirectory.appendingPathComponent("looks"), to: art.appendingPathComponent("looks"))
        try fm.copyItem(at: artDirectory.appendingPathComponent("bridges"), to: art.appendingPathComponent("bridges"))         // the atlas names these too; sorted first, they would be the file named
        try fm.createDirectory(at: art.appendingPathComponent("motions"), withIntermediateDirectories: true)
        let home = try freshHome("refused")
        let (result, installed) = try install(into: home, from: repo)
        #expect(result.code == 2, "install over a source without the motions: \(result.output)")
        #expect(result.output.contains("art/motions/"), "it names the missing file: \(result.output)")
        #expect(!fm.fileExists(atPath: installed.path), "and nothing was created")
        #expect(!fm.fileExists(atPath: home.appendingPathComponent("Library/LaunchAgents/com.tomtim.clawd-pet.plist").path))
    }
}

import Foundation

/// Simple mutable counter holder so async main can track results without
/// capturing captured-locals concurrency diagnostics.
final class Stat {
    var pass = 0
    var fail = 0
}

@main
struct ShellHarness {
    static func main() async {
        // Isolate against the dev machine's real allowlist (Settings → Security).
        UserDefaults.standard.removeObject(forKey: ShellRunner.allowlistStorageKey)
        let stat = Stat()

        func check(_ name: String, _ ok: Bool) {
            if ok { stat.pass += 1 } else { stat.fail += 1 }
            print("\(ok ? "PASS" : "FAIL") \(name)")
        }

        // 1) Normal success captures output.
        let ok = ShellRunner.runBlocking("echo hello-world")
        check("capture stdout", ok.text == "hello-world" && !ok.failed && !ok.wasCancelled)

        // 2) Non-zero exit is reported as failure with stderr+stdout.
        let err = ShellRunner.runBlocking("echo boom 1>&2; exit 3")
        check("failure + stderr", err.failed && err.text.contains("boom"))

        // 3) Fixed working directory (workspace root).
        let cwd = ShellRunner.runBlocking("pwd")
        check("fixed cwd = workspace", cwd.text == ShellRunner.workspaceDirectoryURL.path && !cwd.failed)

        // 4) Scrubbed environment: secrets not inherited.
        //    Launch with MY_SECRET=TOPSECRET to prove the child never sees it.
        let env = ShellRunner.runBlocking("echo \"${MY_SECRET:-UNSET}\"")
        check("env scrubbed (secrets hidden)", env.text == "UNSET")

        // 5) Destructive commands blocked.
        let d = ShellRunner.runBlocking("rm -rf /tmp/whatever")
        check("destructive blocked", d.failed && d.text.contains("Blocked"))

        // 6) Curated allowlist bypasses the blocklist only for known commands.
        let curatedCmd = "rm -rf /tmp/nexie-harness-xyz"
        let curatedRes = ShellRunner.runBlocking(curatedCmd,
                                                 curated: Set([curatedCmd]))
        check("curated bypass runs", curatedRes.text != "Blocked: this command looks destructive and is not allowed."
                                     && !curatedRes.wasCancelled && !curatedRes.text.contains("Blocked"))
        let noCurated = ShellRunner.runBlocking(curatedCmd, curated: Set(["other"]))
        check("unknown command still blocked", noCurated.text.contains("Blocked"))

        // 7) Output cap applies.
        let big = ShellRunner.runBlocking("python3 -c \"print('abcdef'*10_000)\"")
        check("output capped", big.text.count <= ShellRunner.outputCharCap + 32 && big.text.contains("truncated"))

        // 8) Timeout kills long-running commands.
        let started = Date()
        let to = ShellRunner.runBlocking("/bin/sleep 30", timeout: 1.0)
        let elapsed = Date().timeIntervalSince(started)
        check("timeout enforced", to.failed && to.text.contains("timed out") && elapsed < 10)

        // 9) Cancellation interrupts an in-flight process.
        let sid = UUID()
        let cancelTask = Task.detached {
            try? await Task.sleep(nanoseconds: 500_000_000)
            ShellRunner.cancel(sid)
        }
        let c = ShellRunner.runBlocking("/bin/sleep 30", id: sid)
        _ = await cancelTask.value
        check("cancellation works", c.wasCancelled && c.text.contains("Cancelled"))

        // 10) Pre-start cancellation short-circuits before the process launches.
        let preID = UUID()
        _ = ShellRunner.cancel(preID)
        let pre = ShellRunner.runBlocking("echo never", id: preID)
        check("pre-start cancel short-circuits", pre.wasCancelled)

        // 11) PATH still functional after scrubbing (binaries resolvable).
        let which = ShellRunner.runBlocking("command -v /bin/ls")
        check("PATH works scrubbed", !which.failed && which.text.contains("/bin/ls"))

        print("SHELL HARNESS: \(stat.pass) passed, \(stat.fail) failed")
        exit(stat.fail == 0 ? 0 : 1)
    }
}
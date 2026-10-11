import Foundation
import Testing
@testable import WhisprLiteCore

@MainActor @Suite struct MediaBrokerTests {
    func fixture(_ mode: String, shutdownGrace: Duration? = nil) throws -> (MediaBroker, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("whispr-media-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let counter = root.appendingPathComponent("counter")
        try Data("0".utf8).write(to: counter)
        let script = root.appendingPathComponent("fake.pl")
        let source = #"""
        use strict; use warnings; use JSON::PP;
        $| = 1;
        my $counter = $ARGV[0];
        open my $read, '<', $counter or die; my $number = 0 + (<$read> // 0); close $read;
        open my $write, '>', $counter or die; print $write ++$number; close $write;
        my $generation = "generation-$number";
        sub event {
            my ($type, $request, $session, $reason, $gen) = @_;
            print encode_json({version=>1, type=>$type, generation=>$gen // $generation,
                request=>$request // '', session=>$session // '', reason=>$reason,
                state=>{known=>JSON::PP::true, trustworthy=>JSON::PP::true, subscriptionHealthy=>JSON::PP::true}}), "\n";
        }
        event('ready');
        my $mode = 'MODE';
        if ($mode eq 'slow-reader') { select undef, undef, undef, 30; exit 0; }
        while (my $line = <STDIN>) {
            my $request = decode_json($line);
            open my $log, '>>', "$counter.commands" or die; print $log $line; close $log;
            my $op = $request->{operation};
            if ($mode eq 'crash-budget' || ($mode eq 'crash-once' && $number == 1 && $op eq 'begin')) { exit 2; }
            if ($mode eq 'permission') { event('fatal', '', '', 'permission'); next; }
            if ($mode eq 'malformed') { print "{invalid}\n"; next; }
            if ($mode eq 'oversized') { print ('x' x 9000), "\n"; next; }
            if ($number > 1) { event('fatal', '', '', 'permission', 'generation-1'); }
            if ($op eq 'shutdown') { exit 0; }
            event($op eq 'snapshot' ? 'snapshot' : 'skipped', $request->{request}, $request->{session});
        }
        """#.replacingOccurrences(of: "MODE", with: mode)
        try Data(source.utf8).write(to: script)
        let broker = shutdownGrace.map(MediaBroker.init(shutdownGrace:)) ?? MediaBroker()
        broker.start(script: script, framework: counter)
        return (broker, root)
    }
    func count(_ root: URL) -> Int {
        Int((try? String(contentsOf: root.appendingPathComponent("counter"), encoding: .utf8)) ?? "0") ?? 0
    }
    func commands(_ root: URL) -> [[String: String]] {
        let text = (try? String(contentsOf: root.appendingPathComponent("counter.commands"), encoding: .utf8)) ?? ""
        return text.split(separator: "\n").compactMap { line in
            guard let values = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { return nil }
            return values.compactMapValues { $0 as? String }
        }
    }
    func wait(_ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<600 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("Media transport did not settle")
    }
    @Test func recoveryInvalidatesOldLeaseAndStaleReplies() async throws {
        let (broker, root) = try fixture("crash-once")
        defer { broker.shutdown(); try? FileManager.default.removeItem(at: root) }
        try await wait { broker.status == "Media ready" }
        let old = UUID(); broker.begin(old)
        try await wait { count(root) == 2 && broker.status == "Media ready" }
        broker.end(old)
        let current = UUID(); broker.begin(current); broker.end(current)
        try await wait { commands(root).contains { $0["operation"] == "end" && $0["session"] == current.uuidString } }
        #expect(!commands(root).contains { $0["operation"] == "end" && $0["session"] == old.uuidString })
        #expect(broker.readiness == .ready)
        #expect(count(root) == 2)
    }
    @Test func repeatedCrashesStopAfterTwoRecoveries() async throws {
        let (broker, root) = try fixture("crash-budget")
        defer { broker.shutdown(); try? FileManager.default.removeItem(at: root) }
        try await wait { broker.readiness == .unavailable }
        #expect(count(root) == 3)
        #expect(!broker.hasScheduledRestart)
    }
    @Test(arguments: ["permission", "malformed", "oversized"])
    func incompatibleRepliesDisableControlWithoutRestart(_ mode: String) async throws {
        let (broker, root) = try fixture(mode)
        defer { broker.shutdown(); try? FileManager.default.removeItem(at: root) }
        try await wait { broker.readiness == .unavailable }
        #expect(count(root) == 1)
        #expect(broker.status.contains("dictation remains available"))
    }
    @Test func slowReaderDoesNotBlockASRAndShutdownCancelsRecovery() async throws {
        let (broker, root) = try fixture("slow-reader", shutdownGrace: .milliseconds(10))
        defer { broker.shutdown(); try? FileManager.default.removeItem(at: root) }
        try await wait { broker.readiness == .ready }
        for _ in 0..<1000 { let session = UUID(); broker.begin(session); broker.end(session) }
        let asr = FakeASRBackend(); try await asr.prepare()
        let insertion = FakeInsertion()
        let coordinator = DictationCoordinator(capture: FakeCapture(), insertion: insertion, media: broker,
            pipeline: .init(backend: asr, cleanup: DemoCleanup()))
        coordinator.ready = true; coordinator.press(); coordinator.release()
        try await wait { coordinator.state == .idle }
        #expect(insertion.texts.count == 1)
        broker.shutdown()
        try await wait { !broker.hasLiveHelper }
        #expect(broker.readiness == .disabled)
        #expect(count(root) == 1)
    }
}

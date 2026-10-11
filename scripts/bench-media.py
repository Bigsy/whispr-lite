#!/usr/bin/env python3
"""Read-only media spike. Control cycles are opt-in; submission != observed transition."""
import argparse
import json
from pathlib import Path
import statistics
import subprocess
import time
from broker_client import BrokerClient
from cleanup_bench import nearest_rank, run_guarded, write_report

ROOT = Path(__file__).resolve().parent.parent
MEDIA_REVISION = json.loads((ROOT / 'stack.lock.json').read_text())['media_adapter']['revision']
VENDOR = ROOT / 'Vendor/mediaremote-adapter'
FRAMEWORK = ROOT / '.build/media/MediaRemoteAdapter.framework'
UPSTREAM_FRAMEWORK = ROOT / '.build/media-upstream/MediaRemoteAdapter.framework'


def distribution(values):
    return dict(count=len(values), median_ms=statistics.median(values),
                p90_ms=nearest_rank(values, .9), p95_ms=nearest_rank(values, .95)) if values else None


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--cycles', action='store_true', help='Actually pause/resume the active identifiable player for 30 cycles')
    args = parser.parse_args()
    subprocess.run([str(ROOT / 'scripts/build-media.sh')], check=True)
    subprocess.run([str(ROOT / 'scripts/build-media-upstream.sh')], check=True)
    sdk = subprocess.check_output(['xcrun', '--sdk', 'macosx', '--show-sdk-path'], text=True).strip()
    native_source = ROOT / '.build/media-upstream/native-probe.m'
    native_source.write_text('void adapter_get(void); int main(void) { adapter_get(); return 0; }\n')
    native = ROOT / '.build/media-upstream/native-probe'
    subprocess.run(['xcrun', 'clang', '-isysroot', sdk, '-arch', 'arm64', str(native_source),
                    '-F', str(UPSTREAM_FRAMEWORK.parent), '-framework', 'MediaRemoteAdapter',
                    '-Wl,-rpath,' + str(UPSTREAM_FRAMEWORK.parent), '-o', str(native)], check=True)
    native_result = subprocess.run([str(native)], capture_output=True, timeout=5)
    try:
        native_state = json.loads(native_result.stdout)
        native_known = isinstance(native_state, dict) and 'playing' in native_state
    except (ValueError, TypeError):
        native_known = False
    one_shot = []
    for _ in range(30):
        start = time.monotonic()
        # Keep metadata in process memory only; report no media titles.
        subprocess.run(['/usr/bin/perl', str(VENDOR / 'bin/mediaremote-adapter.pl'), str(UPSTREAM_FRAMEWORK),
                        'get', '--no-artwork'], capture_output=True, check=True, timeout=5)
        one_shot.append((time.monotonic()-start)*1000)
    process = subprocess.Popen(['/usr/bin/perl', str(VENDOR / 'patches/broker.pl'), str(FRAMEWORK / 'MediaRemoteAdapter')],
                               stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    client = BrokerClient(process)
    wait, send = client.wait, client.send
    snapshots = []; state = {}
    pauses = []; resumes = []
    try:
        start = time.monotonic()
        wait('ready')
        startup_ms = (time.monotonic()-start)*1000
        for _ in range(30):
            start = time.monotonic(); request = send('snapshot')
            state = wait('snapshot', request).get('state', {})
            snapshots.append((time.monotonic()-start)*1000)
        if args.cycles:
            if not state.get('known') or not state.get('trustworthy') or not state.get('playing'):
                raise RuntimeError('Control benchmark requires a playing, identifiable active session')
            for cycle in range(30):
                session = 'bench-' + str(cycle)
                start = time.monotonic(); request = send('begin', session)
                wait('paused', request); pauses.append((time.monotonic()-start)*1000)
                start = time.monotonic(); send('end', session)
                # Resume belongs to the lease opened by begin, so it carries the begin request ID.
                wait('resumed', request); resumes.append((time.monotonic()-start)*1000)
        try:
            usage = subprocess.check_output(['ps', '-o', 'rss=,%cpu=', '-p', str(process.pid)], text=True).strip()
        except (OSError, subprocess.CalledProcessError):
            usage = 'unavailable in this execution sandbox'
        report = dict(schema=1, mode='real-media-probe', adapter_revision=MEDIA_REVISION,
                      native_known=native_known, broker_known=state.get('known', False),
                      broker_trustworthy_identity=state.get('trustworthy', False),
                      startup_ms=startup_ms, one_shot_get_ms=one_shot, one_shot_summary=distribution(one_shot),
                      broker_snapshot_ms=snapshots, broker_summary=distribution(snapshots),
                      observed_pause_ms=pauses, observed_resume_ms=resumes,
                      pause_summary=distribution(pauses), resume_summary=distribution(resumes),
                      process_rss_kib_and_cpu_percent=usage, physical_footprint_measured=False,
                      focus_preservation_measured=False, idle_power_measured=False,
                      launches_per_dictation_after_ready=0)
        destination = ROOT / 'bench/results/media-probe.json'
        report = write_report(destination, report, 'real-media-probe')
        print(json.dumps({k:v for k,v in report.items() if not isinstance(v, list)}, indent=2))
    finally:
        # EOF settles an owned lease even if an observation wait failed.
        client.close()

if __name__ == '__main__':
    run_guarded(main, 'Media probe', {'Media response deadline',
                                     'Control benchmark requires a playing, identifiable active session'})

#!/usr/bin/env python3
"""Compare Apple's on-device model with Gemma; save aggregate metrics only."""

import argparse
import collections
import importlib.util
import json
import pathlib
import statistics
import subprocess
import sys
import time


ROOT = pathlib.Path(__file__).resolve().parent.parent
SPEC = importlib.util.spec_from_file_location('cleanup_bench', ROOT / 'scripts/bench-cleanup-models.py')
BENCH = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(BENCH)


def apple_clean(process, instructions, raw, framing, rules):
    user = (f'<transcript>\n{raw}\n</transcript>\n\nOutput only the cleaned transcript.'
            if framing == 'openWhispr' else raw)
    limit = min(1024, max(128, len(raw.encode()) // 2 + 64))
    request = {'instructions': instructions, 'transcript': user, 'limit': limit}
    start = time.monotonic()
    process.stdin.write(json.dumps(request, ensure_ascii=False) + '\n')
    process.stdin.flush()
    line = process.stdout.readline()
    elapsed = (time.monotonic() - start) * 1000
    if not line:
        raise RuntimeError('Foundation Models bridge exited')
    response = json.loads(line)
    if 'error' in response:
        return None, elapsed, response['error']
    return BENCH.apply_rules(response['content'].strip(), rules), elapsed, None


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--history', type=pathlib.Path, default=BENCH.HISTORY)
    parser.add_argument('--support', type=pathlib.Path, default=BENCH.SUPPORT)
    parser.add_argument('--output', type=pathlib.Path,
                        default=ROOT / 'bench/results/cleanup-apple-foundation.json')
    args = parser.parse_args()
    binary = ROOT / '.build/bench-apple-cleanup'
    cache = ROOT / '.build/swift-module-cache'
    cache.mkdir(parents=True, exist_ok=True)
    source = ROOT / 'scripts/bench-apple-cleanup.swift'
    if not binary.exists() or binary.stat().st_mtime < source.stat().st_mtime:
        sdk = subprocess.check_output(['xcrun', '--sdk', 'macosx', '--show-sdk-path'], text=True).strip()
        compiler = subprocess.run(['swiftc', '-parse-as-library', '-sdk', sdk,
                                   '-target', 'arm64-apple-macosx26.0',
                                   '-module-cache-path', str(cache), '-o', str(binary), str(source)],
                                  capture_output=True, text=True)
        if compiler.returncode:
            raise RuntimeError('Swift bridge compile failed: ' + compiler.stderr[:1000])

    preferences = json.loads((args.support / 'preferences.json').read_text())
    prompt = (args.support / 'prompt.txt').read_text().strip()
    dictionary = (args.support / 'dictionary.txt').read_text()
    vocabulary, rules = BENCH.vocabulary_and_rules(dictionary)
    suffix = preferences.get('cleanupDictionaryPrefix', '\nCustom dictionary:\n') + vocabulary if vocabulary else ''
    system = prompt + suffix
    synthetic_system = (ROOT / 'Resources/cleanup-prompt.txt').read_text().strip()
    synthetic_system += '\nCustom dictionary:\nClojure, mapv, Parakeet, Gemma, Whispr Lite'
    framing = preferences.get('cleanupInputFormat', 'plain')
    samples = BENCH.load_history(args.history)
    fixtures = (json.loads((ROOT / 'bench/prompt-fixtures.json').read_text())
                + json.loads((ROOT / 'bench/model-cleanup-fixtures.json').read_text()))
    endpoint = BENCH.local_endpoint(preferences['cleanupEndpoint'])
    baseline_alias = 'gemma4-e2b-cleanup:latest'
    if baseline_alias not in [item['id'] for item in BENCH.get(endpoint, '/v1/models')['data']]:
        raise RuntimeError('installed Gemma baseline is not ready')
    print('real_samples', len(samples), 'synthetic_samples', len(fixtures), flush=True)
    historical = [cleaned for _, cleaned in samples]
    baseline, baseline_metrics = BENCH.run_model('gemma4-e2b', endpoint, baseline_alias,
                                                system, synthetic_system, framing, rules,
                                                samples, fixtures)
    baseline_metrics['versus_historical'] = BENCH.describe(historical, baseline)

    with subprocess.Popen([str(binary)], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                          stderr=subprocess.DEVNULL, text=True, bufsize=1) as process:
        apple_clean(process, system, 'synthetic warmup', framing, rules)
        outputs, latency, errors = [], [], collections.Counter()
        for index, (raw, _) in enumerate(samples, 1):
            output, elapsed, error = apple_clean(process, system, raw, framing, rules)
            outputs.append(output)
            if error:
                errors[error] += 1
            else:
                latency.append(elapsed)
            if index % 20 == 0:
                print('apple_real_completed', index, flush=True)
        failed = []
        for fixture in fixtures:
            output, _, error = apple_clean(process, synthetic_system, fixture['raw'], framing, [])
            if error or not BENCH.matches_synthetic(fixture, output):
                failed.append(fixture['id'])

    metrics = {'real_count': len(samples), 'real_errors': dict(errors),
               'synthetic_passed': len(fixtures) - len(failed),
               'synthetic_total': len(fixtures), 'synthetic_failed_ids': failed,
               'warm_median_ms': round(statistics.median(latency), 2) if latency else None,
               'warm_p95_ms': round(sorted(latency)[int((len(latency) - 1) * .95)], 2) if latency else None,
               'versus_historical': BENCH.describe(historical, outputs),
               'versus_gemma': BENCH.describe(baseline, outputs)}
    report = {'schema': 1, 'method': 'local-real-history-and-synthetic',
              'real_source': 'OpenWhispr completed raw/cleaned pairs, immutable SQLite read',
              'real_prompt': 'saved private prompt and dictionary, held in RAM',
              'synthetic_prompt': 'bundled default and public synthetic dictionary',
              'reference_note': 'Historical cleaned text and Gemma output are references, not reviewed ground truth.',
              'framing': framing, 'sampling': 'greedy', 'private_text_saved': False,
              'model_results': {'gemma4-e2b': baseline_metrics, 'apple_foundation': metrics}}
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, indent=2) + '\n')
    print('apple_real_success', len(latency), 'synthetic', metrics['synthetic_passed'],
          '/', len(fixtures), flush=True)
    print('aggregate_report', args.output, flush=True)


if __name__ == '__main__':
    main()

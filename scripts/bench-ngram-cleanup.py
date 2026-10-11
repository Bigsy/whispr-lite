#!/usr/bin/env python3
"""Compare pinned Gemma MTP with combined n-gram speculation on public text only.

The installed service is never touched. Responses stay in memory; the ignored report
contains only timings, completion counts, and exact-parity counts.
"""

import argparse
from datetime import datetime, timezone
from importlib.util import module_from_spec, spec_from_file_location
import json
from pathlib import Path
import statistics
import subprocess
import time
from urllib.request import ProxyHandler, Request, build_opener


ROOT = Path(__file__).resolve().parent.parent
ENDPOINT = 'http://127.0.0.1:11437'


def module(name, path):
    spec = spec_from_file_location(name, path)
    value = module_from_spec(spec)
    spec.loader.exec_module(value)
    return value


def summary(values):
    if not values:
        return None
    values = sorted(values)
    return {'median': round(statistics.median(values), 2),
            'p95': round(values[int((len(values) - 1) * .95 + .999999)], 2)}


def post(opener, body):
    request = Request(ENDPOINT + '/v1/chat/completions', data=json.dumps(body).encode(),
                      headers={'Content-Type': 'application/json'})
    with opener.open(request, timeout=30) as response:
        return json.load(response)


def ready(opener, process):
    until = time.monotonic() + 90
    while time.monotonic() < until:
        if process.poll() is not None:
            return False
        try:
            with opener.open(ENDPOINT + '/health', timeout=.5) as response:
                if json.load(response).get('status') == 'ok':
                    return True
        except OSError:
            time.sleep(.5)
    return False


def run(args):
    service = module('cleanup_service', ROOT / 'scripts/cleanup-service.py')
    service.free_port(11437)
    base = service.arguments(service.DEFAULT_DIRECTORY, 11437) + ['--cache-ram', '0']
    spec_index = base.index('--spec-type') + 1
    public = json.loads((ROOT / 'bench/model-cleanup-fixtures.json').read_text())
    fixtures = {item['id']: item['raw'] for item in public}
    cases = {
        'short_question': fixtures['model_short_question'],
        'short_correction': fixtures['model_number_correction'],
        'short_instruction': fixtures['model_instruction_as_content'],
        'long_mixed': '. '.join(item['raw'] for item in public),
        'long_copy': ' '.join(["Please send the revised report to the team on Friday."] * 14),
    }
    prompt = (ROOT / 'Resources/cleanup-prompt.txt').read_text().strip()
    system = prompt + '\nCustom dictionary:\nClojure, mapv, Parakeet, Gemma, Whispr Lite'
    opener = build_opener(ProxyHandler({}))
    modes = [('mtp_before', 'draft-mtp', [])]
    for kind in ('ngram-simple', 'ngram-map-k', 'ngram-mod'):
        for n in (3, 4):
            flags = ([f'--spec-{kind}-size-n', str(n), f'--spec-{kind}-size-m', '8']
                     if kind != 'ngram-mod' else
                     ['--spec-ngram-mod-n-match', str(n), '--spec-ngram-mod-n-min', '4',
                      '--spec-ngram-mod-n-max', '8'])
            modes.append((kind + str(n), 'draft-mtp,' + kind, flags))
    modes.append(('mtp_after', 'draft-mtp', []))
    if args.focus:
        modes = [mode for mode in modes if mode[0] in ('mtp_before', args.focus, 'mtp_after')]
    reference = {}
    results = []
    for label, spec_type, extra in modes:
        command = base.copy()
        command[spec_index] = spec_type
        process = subprocess.Popen(command + extra, env=service.runtime_environment(),
                                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        try:
            if not ready(opener, process):
                if label == 'mtp_before':
                    raise RuntimeError('Pinned MTP baseline could not start; check Metal session access')
                results.append({'mode': label, 'startup': 'failed', 'repetitions': 0})
                print(label, 'startup failed', flush=True)
                continue
            body = lambda raw: {'model': service.LOCK['alias'], 'messages': [
                {'role': 'system', 'content': system}, {'role': 'user', 'content': raw}],
                'temperature': 0, 'max_tokens': min(1024, max(128, len(raw.encode()) // 2 + 64)),
                'stream': False, 'cache_prompt': True, 'id_slot': 0,
                'chat_template_kwargs': {'enable_thinking': False}}
            post(opener, body('synthetic warmup'))
            rows = {name: [] for name in cases}
            draft = {name: [] for name in cases}
            exact = {name: 0 for name in cases}
            completed = {name: 0 for name in cases}
            timing_fields = set()
            for repetition in range(args.repetitions):
                names = list(cases)
                names = names[repetition % len(names):] + names[:repetition % len(names)]
                for name in names:
                    started = time.monotonic()
                    response = post(opener, body(cases[name]))
                    elapsed = (time.monotonic() - started) * 1000
                    choice = response['choices'][0]
                    if choice.get('finish_reason') != 'stop':
                        continue
                    completed[name] += 1
                    output = choice['message']['content'].strip()
                    if label == 'mtp_before':
                        reference.setdefault(name, output)
                    exact[name] += output == reference[name]
                    rows[name].append(elapsed)
                    timings = response.get('timings', {})
                    draft[name].append({key: timings.get(key, 0) for key in
                                        ('draft_n', 'draft_n_accepted', 'predicted_n')})
                    timing_fields.update(timings.keys())
            results.append({'mode': label, 'startup': 'ready', 'spec_type': spec_type,
                            'lookup_tokens': None if label.startswith('mtp_') else int(label[-1]),
                            'repetitions': args.repetitions,
                            'cases': {name: {'completed': completed[name], 'exact_to_mtp': exact[name],
                                             'latency_ms': summary(rows[name]),
                                             'draft_tokens': sum(row['draft_n'] for row in draft[name]),
                                             'accepted_tokens': sum(row['draft_n_accepted'] for row in draft[name]),
                                             'predicted_tokens': sum(row['predicted_n'] for row in draft[name])}
                                      for name in cases},
                            'timing_fields': sorted(timing_fields)})
            print(label, 'complete', sum(completed.values()), 'of', len(cases) * args.repetitions,
                  'exact', sum(exact.values()), flush=True)
        finally:
            process.terminate()
            try:
                process.wait(timeout=15)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()
    report = {'schema': 1, 'experiment': 'mtp-plus-ngram-public-synthetic',
              'created_utc': datetime.now(timezone.utc).isoformat(),
              'pinned_binary_and_weights': True, 'isolated_server': True,
              'installed_service_changed': False, 'private_content_recorded': False,
              'fixture_words': {name: len(raw.split()) for name, raw in cases.items()},
              'model_output_recorded': False, 'asr_or_insertion_measured': False,
              'results': results}
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, indent=2) + '\n')
    print('aggregate_report', args.output, flush=True)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--repetitions', type=int, default=10)
    parser.add_argument('--focus', choices=('ngram-simple3', 'ngram-simple4', 'ngram-map-k3',
                                            'ngram-map-k4', 'ngram-mod3', 'ngram-mod4'))
    parser.add_argument('--output', type=Path, default=ROOT / 'bench/results/ngram-cleanup.json')
    arguments = parser.parse_args()
    if arguments.repetitions < 1:
        parser.error('Positive repetitions required')
    try:
        run(arguments)
    except Exception as error:
        parser.exit(1, f'N-gram cleanup probe failed ({type(error).__name__}); text suppressed.\n')

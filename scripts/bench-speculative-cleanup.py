#!/usr/bin/env python3
"""Mock full cleanup from synthetic streaming partials; report metrics only."""
import argparse
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timezone
from importlib.util import module_from_spec, spec_from_file_location
import json
from pathlib import Path
import statistics
import subprocess
import time
from urllib.request import ProxyHandler, Request, build_opener

ROOT = Path(__file__).resolve().parent.parent


def module(name, path):
    spec = spec_from_file_location(name, path)
    value = module_from_spec(spec)
    spec.loader.exec_module(value)
    return value


def summary(values):
    values = sorted(values)
    return dict(median=statistics.median(values),
                p90=values[int((len(values) - 1) * .9 + .999999)],
                p95=values[int((len(values) - 1) * .95 + .999999)])


def run(args):
    service = module('cleanup_service', ROOT / 'scripts/cleanup-service.py')
    previous = module('prefill_bench', ROOT / 'scripts/bench-prefill.py')
    service.free_port(11437)
    server = subprocess.Popen(service.arguments(service.DEFAULT_DIRECTORY, 11437) + ['--cache-ram', '0'],
                              env=service.runtime_environment(), stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    endpoint = 'http://127.0.0.1:11437'

    def post(route, body):
        request = Request(endpoint + route, data=json.dumps(body).encode(), headers={'Content-Type': 'application/json'})
        with build_opener(ProxyHandler({})).open(request, timeout=30) as response:
            return json.load(response)

    try:
        for _ in range(120):
            if server.poll() is not None:
                raise RuntimeError('Temporary server exited')
            try:
                with build_opener(ProxyHandler({})).open(endpoint + '/health', timeout=.5) as response:
                    if json.load(response).get('status') == 'ok':
                        break
            except OSError:
                time.sleep(.5)
        else:
            raise RuntimeError('Temporary server not ready')

        settings = json.loads((args.settings_dir / 'preferences.json').read_text())
        prompt = (args.settings_dir / 'prompt.txt').read_text()
        dictionary_file = args.settings_dir / 'dictionary.txt'
        dictionary = previous.vocabulary(dictionary_file.read_text()) if dictionary_file.exists() else ''
        system = prompt + (settings.get('cleanupDictionaryPrefix', '\nCustom dictionary:\n') + dictionary if dictionary else '')

        def messages(raw):
            user = f'<transcript>\n{raw}\n</transcript>\n\nOutput only the cleaned transcript.' if settings.get('cleanupInputFormat') == 'openWhispr' else raw
            if len(system.encode()) + len(user.encode()) > 16384:
                raise ValueError('Byte budget exceeded')
            return [dict(role='system', content=system), dict(role='user', content=user)]

        def tokens(raw):
            rendered = post('/apply-template', dict(messages=messages(raw), chat_template_kwargs=dict(enable_thinking=False)))['prompt']
            ids = post('/tokenize', dict(content=rendered, add_special=True, parse_special=True))['tokens']
            if len(ids) + 512 > 4096:
                raise ValueError('Context budget exceeded')
            return ids

        left, right = tokens('ZZZ synthetic marker'), tokens('aaa different marker')
        # The marker strings differ at the first user token; the common part is contiguous.
        prefix = left[:next((i for i, (a, b) in enumerate(zip(left, right)) if a != b), min(len(left), len(right)))]

        def reset():
            result = post('/completion', dict(prompt=prefix, n_predict=0, cache_prompt=False,
                temperature=0, stream=False, return_tokens=True, id_slot=0))
            if result.get('truncated') or not 0 <= result['tokens_predicted'] <= 1:
                raise ValueError('Unexpected prefix evaluation')

        def complete(raw):
            started = time.monotonic()
            result = post('/v1/chat/completions', dict(model='gemma4-e2b-cleanup:latest', messages=messages(raw),
                temperature=0, max_tokens=512, stream=False, cache_prompt=True, id_slot=0,
                chat_template_kwargs=dict(enable_thinking=False)))
            if result['choices'][0]['finish_reason'] != 'stop':
                raise ValueError('Incomplete cleanup')
            return (time.monotonic() - started) * 1000, result['choices'][0]['message']['content'].strip()

        sources = [json.loads(path.read_text()) for path in args.snapshots]
        cases = []
        no_partial = []
        for source in sources:
            for fixture in source['fixtures']:
                final = fixture['streaming'][0]['text']
                candidates = [s for s in fixture['streaming'][0]['partial_snapshots']
                              if s['at_ms'] < fixture['audio_seconds'] * 1000]
                if not candidates:
                    no_partial.append(fixture['fixture'])
                    continue
                selected = [candidates[0]]
                exact = next((s for s in candidates if s['text'] == final), None)
                if exact is not None and exact is not candidates[0]:
                    selected.append(exact)
                for index, partial in enumerate(selected):
                    cases.append(dict(id=fixture['fixture'], snapshot=index + 1, raw=final,
                        partial=partial['text'], exact=partial['text'] == final,
                        lead_ms=fixture['audio_seconds'] * 1000 - partial['at_ms']))

        aggregates = []
        for case in cases:
            rows = []
            outputs = set()
            for repetition in range(args.repetitions):
                pair = {}
                for speculative in ((False, True) if repetition % 2 == 0 else (True, False)):
                    reset()
                    speculative_ms = 0
                    if speculative:
                        speculative_ms, speculative_output = complete(case['partial'])
                        if case['exact']:
                            pair['speculative'] = max(0, speculative_ms - case['lead_ms'])
                            outputs.add(speculative_output)
                            rows.append(dict(speculative_ms=speculative_ms, final_ms=0))
                            continue
                    final_ms, output = complete(case['raw'])
                    outputs.add(output)
                    if speculative:
                        pair['speculative'] = max(0, speculative_ms - case['lead_ms']) + final_ms
                        rows.append(dict(speculative_ms=speculative_ms, final_ms=final_ms))
                    else:
                        pair['baseline'] = final_ms
                        rows.append(dict(baseline_ms=final_ms))
                rows.append(dict(saving_ms=pair['baseline'] - pair['speculative']))
            if len(outputs) != 1:
                raise ValueError('Output parity failed')
            case['expected_output'] = next(iter(outputs))
            aggregates.append(dict(fixture=case['id'], snapshot=case['snapshot'], exact_match=case['exact'],
                lead_ms=case['lead_ms'], repetitions=args.repetitions, output_parity=True,
                baseline_release_ms=summary([r['baseline_ms'] for r in rows if 'baseline_ms' in r]),
                speculative_generation_ms=summary([r['speculative_ms'] for r in rows if 'speculative_ms' in r]),
                wasted_generation_ms=summary([r['speculative_ms'] for r in rows if 'speculative_ms' in r]) if not case['exact'] else None,
                final_after_wrong_guess_ms=summary([r['final_ms'] for r in rows if 'final_ms' in r]) if not case['exact'] else None,
                projected_release_saving_ms=summary([r['saving_ms'] for r in rows if 'saving_ms' in r])))
            print(case['id'], 'snapshot', case['snapshot'], 'exact=', case['exact'],
                  'projected_median_saving_ms=', aggregates[-1]['projected_release_saving_ms']['median'], flush=True)

        # Submit a stale request just before release, then submit the authoritative final
        # request to the same slot. This measures queueing/failure under actual overlap.
        stale = next(c for c in cases if c['id'] == 'correction.wav' and not c['exact'])
        contention = []
        with ThreadPoolExecutor(max_workers=2) as pool:
            for repetition in range(args.repetitions):
                reset()
                first = pool.submit(complete, stale['partial'])
                time.sleep(.005)
                started = time.monotonic()
                second = pool.submit(complete, stale['raw'])
                try:
                    final_ms, final_output = second.result()
                    release_ms = (time.monotonic() - started) * 1000
                    speculative_ms, _ = first.result()
                    if final_output != stale['expected_output']:
                        raise ValueError('Contended final output mismatch')
                    contention.append(dict(release_ms=release_ms, final_ms=final_ms,
                                           speculative_ms=speculative_ms, success=True))
                except OSError:
                    first.result()
                    contention.append(dict(success=False))
        successful = [r for r in contention if r['success']]
        report = dict(schema=1, experiment='speculative-full-cleanup-mock',
            created_utc=datetime.now(timezone.utc).isoformat(), repetitions=args.repetitions,
            isolated_server=True, ram_prompt_cache_disabled=True, private_content_recorded=False,
            physical_capture_asr_insertion_measured=False, projected_release_saving=True,
            no_partial_fixtures=no_partial, cases=aggregates,
            contention=dict(repetitions=args.repetitions, success_count=len(successful),
                release_ms=summary([r['release_ms'] for r in successful]) if successful else None,
                speculative_ms=summary([r['speculative_ms'] for r in successful]) if successful else None))
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(json.dumps(report, indent=2) + '\n')
        print('contention successes=', len(successful), 'of', args.repetitions, flush=True)
    finally:
        server.terminate()
        try:
            server.wait(timeout=10)
        except subprocess.TimeoutExpired:
            server.kill()
            server.wait()


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--settings-dir', type=Path, default=Path.home() / 'Library/Application Support/WhisprLite')
    parser.add_argument('--snapshots', type=Path, nargs='+', default=[ROOT / 'bench/results/streaming-snapshots.json',
        ROOT / 'bench/results/speculative-snapshots.json'])
    parser.add_argument('--output', type=Path, default=ROOT / 'bench/results/speculative-cleanup.json')
    parser.add_argument('--repetitions', type=int, default=30)
    args = parser.parse_args()
    if args.repetitions < 1:
        parser.error('Positive repetition count required')
    try:
        run(args)
    except Exception as error:
        parser.exit(1, f'Speculative cleanup mock failed ({type(error).__name__}); request content suppressed.\n')

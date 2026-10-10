#!/usr/bin/env python3
"""Synthetic cleanup mock comparing current token check with direct final request."""
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


def load_module(name, path):
    spec = spec_from_file_location(name, path)
    module = module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def summary(values):
    values = sorted(values)
    return dict(median=statistics.median(values), p95=values[int((len(values) - 1) * .95 + .999999)])


def run(args):
    previous = load_module('prefill_bench', ROOT / 'scripts/bench-prefill.py')
    service = load_module('cleanup_service', ROOT / 'scripts/cleanup-service.py')
    service.free_port(11437)
    server = subprocess.Popen(service.arguments(service.DEFAULT_DIRECTORY, 11437) + ['--cache-ram', '0'],
        env=service.runtime_environment(), stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    opener = build_opener(ProxyHandler({}))
    endpoint = 'http://127.0.0.1:11437'
    try:
        for _ in range(120):
            if server.poll() is not None:
                raise RuntimeError('Temporary server exited')
            try:
                with opener.open(endpoint + '/health', timeout=.5) as response:
                    if json.load(response).get('status') == 'ok':
                        break
            except OSError:
                time.sleep(.5)
        else:
            raise RuntimeError('Temporary server not ready')

        settings = json.loads((args.settings_dir / 'preferences.json').read_text())
        prompt = (args.settings_dir / 'prompt.txt').read_text()
        dictionary_path = args.settings_dir / 'dictionary.txt'
        dictionary = previous.vocabulary(dictionary_path.read_text()) if dictionary_path.exists() else ''
        system = prompt + (settings.get('cleanupDictionaryPrefix', '\nCustom dictionary:\n') + dictionary if dictionary else '')
        source = json.loads(args.fixtures.read_text())
        fixtures = [(f['fixture'], f['streaming'][0]['text']) for f in source['fixtures']]

        def post(route, body):
            request = Request(endpoint + route, data=json.dumps(body).encode(), headers={'Content-Type': 'application/json'})
            with opener.open(request, timeout=30) as response:
                return json.load(response)

        def messages(raw):
            user = f'<transcript>\n{raw}\n</transcript>\n\nOutput only the cleaned transcript.' if settings.get('cleanupInputFormat') == 'openWhispr' else raw
            if len(system.encode()) + len(user.encode()) > 16384:
                raise ValueError('Byte budget exceeded')
            return [dict(role='system', content=system), dict(role='user', content=user)]

        def tokens(raw):
            rendered = post('/apply-template', dict(messages=messages(raw), chat_template_kwargs=dict(enable_thinking=False)))['prompt']
            return post('/tokenize', dict(content=rendered, add_special=True, parse_special=True))['tokens']

        marker_a, marker_b = tokens('ZZZ synthetic marker'), tokens('aaa different marker')
        prefix = []
        for left, right in zip(marker_a, marker_b):
            if left != right:
                break
            prefix.append(left)
        if not prefix:
            raise ValueError('No common prefix')

        def reset_prefix():
            result = post('/completion', dict(prompt=prefix, n_predict=0, cache_prompt=False,
                temperature=0, stream=False, return_tokens=True, id_slot=0))
            if result.get('truncated') or not 0 <= result['tokens_predicted'] <= 1:
                raise ValueError('Unexpected prefill generation')

        observations = []
        outputs = {}
        for repetition in range(args.repetitions):
            for name, raw in fixtures[repetition % len(fixtures):] + fixtures[:repetition % len(fixtures)]:
                for checked in (True, False) if repetition % 2 == 0 else (False, True):
                    reset_prefix()
                    started = time.monotonic()
                    checked_tokens = tokens(raw) if checked else None
                    preparation_ms = (time.monotonic() - started) * 1000
                    if checked_tokens is not None and len(checked_tokens) + 512 > 4096:
                        raise ValueError('Context budget exceeded')
                    final = post('/v1/chat/completions', dict(model='gemma4-e2b-cleanup:latest', messages=messages(raw),
                        temperature=0, max_tokens=512, stream=False, cache_prompt=True, id_slot=0,
                        chat_template_kwargs=dict(enable_thinking=False)))
                    total_ms = (time.monotonic() - started) * 1000
                    if final['choices'][0]['finish_reason'] != 'stop':
                        raise ValueError('Incomplete final output')
                    output = final['choices'][0]['message']['content'].strip()
                    outputs.setdefault(name, set()).add(output)
                    observations.append(dict(fixture=name, repetition=repetition, condition='checked' if checked else 'direct',
                        total_ms=total_ms, preparation_ms=preparation_ms, prompt_ms=final['timings']['prompt_ms'],
                        cached_tokens=final['timings']['cache_n'], checked_token_count=len(checked_tokens) if checked else None))
            print('round', repetition + 1, 'of', args.repetitions, flush=True)

        aggregates = []
        for name, _ in fixtures:
            if len(outputs[name]) != 1:
                raise ValueError('Output parity failed')
            rows = [o for o in observations if o['fixture'] == name]
            by_condition = {c: [o for o in rows if o['condition'] == c] for c in ('checked', 'direct')}
            paired_savings = [next(o['total_ms'] for o in by_condition['checked'] if o['repetition'] == i)
                - next(o['total_ms'] for o in by_condition['direct'] if o['repetition'] == i)
                for i in range(args.repetitions)]
            aggregates.append(dict(fixture=name, exact_output_parity=True, paired_saving_ms=summary(paired_savings),
                checked={k: summary([o[k] for o in by_condition['checked']]) for k in ('total_ms', 'preparation_ms', 'prompt_ms', 'cached_tokens')},
                direct={k: summary([o[k] for o in by_condition['direct']]) for k in ('total_ms', 'preparation_ms', 'prompt_ms', 'cached_tokens')},
                checked_token_count=by_condition['checked'][0]['checked_token_count']))
        report = dict(schema=1, experiment='cleanup-token-roundtrips-mock',
            created_utc=datetime.now(timezone.utc).isoformat(), repetitions=args.repetitions,
            fixed_prefix_tokens=len(prefix), isolated_server=True, ram_prompt_cache_disabled=True,
            direct_mode_skips_exact_context_validation=True, private_content_recorded=False,
            physical_capture_asr_insertion_measured=False, aggregates=aggregates)
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(json.dumps(report, indent=2) + '\n')
        for row in aggregates:
            print(row['fixture'], 'paired_median_saving_ms=', row['paired_saving_ms']['median'], flush=True)
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
    parser.add_argument('--fixtures', type=Path, default=ROOT / 'bench/results/streaming-snapshots.json')
    parser.add_argument('--output', type=Path, default=ROOT / 'bench/results/cleanup-roundtrips.json')
    parser.add_argument('--repetitions', type=int, default=30)
    args = parser.parse_args()
    if args.repetitions < 1:
        parser.error('Positive repetition count required')
    try:
        run(args)
    except Exception as error:
        parser.exit(1, f'Cleanup roundtrip mock failed ({type(error).__name__}); request content suppressed.\n')

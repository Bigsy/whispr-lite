#!/usr/bin/env python3
"""Mock Gemma prefill from synthetic ASR partials; no capture or app wiring."""
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
    return dict(median=statistics.median(values), p90=values[int((len(values) - 1) * .9 + .999999)],
                p95=values[int((len(values) - 1) * .95 + .999999)])


def common_count(left, right):
    return next((i for i, pair in enumerate(zip(left, right)) if pair[0] != pair[1]), min(len(left), len(right)))


def run(args):
    previous = load_module('prefill_bench', ROOT / 'scripts/bench-prefill.py')
    service = load_module('cleanup_service', ROOT / 'scripts/cleanup-service.py')
    service.free_port(11437)
    command = service.arguments(service.DEFAULT_DIRECTORY, 11437) + ['--cache-ram', '0']
    server = subprocess.Popen(command, env=service.runtime_environment(), stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
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

        def post(route, body):
            request = Request(endpoint + route, data=json.dumps(body).encode(), headers={'Content-Type': 'application/json'})
            with opener.open(request, timeout=30) as response:
                return json.load(response)

        def messages(raw):
            user = f'<transcript>\n{raw}\n</transcript>\n\nOutput only the cleaned transcript.' if settings.get('cleanupInputFormat') == 'openWhispr' else raw
            return [dict(role='system', content=system), dict(role='user', content=user)]

        def tokens(raw):
            rendered = post('/apply-template', dict(messages=messages(raw), chat_template_kwargs=dict(enable_thinking=False)))['prompt']
            result = post('/tokenize', dict(content=rendered, add_special=True, parse_special=True))['tokens']
            if len(result) + 512 > 4096:
                raise ValueError('Context budget exceeded')
            return result

        def prefill(token_ids, cached):
            started = time.monotonic()
            result = post('/completion', dict(prompt=token_ids, n_predict=0, cache_prompt=cached,
                temperature=0, stream=False, return_tokens=True, id_slot=0))
            elapsed = (time.monotonic() - started) * 1000
            if result.get('truncated') or not 0 <= result['tokens_predicted'] <= 1:
                raise ValueError('Unexpected prefill generation')
            return elapsed

        def finish(raw):
            started = time.monotonic()
            result = post('/v1/chat/completions', dict(model='gemma4-e2b-cleanup:latest', messages=messages(raw),
                temperature=0, max_tokens=512, stream=False, cache_prompt=True, id_slot=0,
                chat_template_kwargs=dict(enable_thinking=False)))
            elapsed = (time.monotonic() - started) * 1000
            if result['choices'][0]['finish_reason'] != 'stop':
                raise ValueError('Incomplete final output')
            return elapsed, result['timings']['prompt_ms'], result['timings']['cache_n'], result['choices'][0]['message']['content'].strip()

        left, right = tokens('ZZZ synthetic marker'), tokens('aaa different marker')
        prefix = left[:common_count(left, right)]
        source = json.loads(args.snapshots.read_text())
        fixtures = []
        for fixture in source['fixtures']:
            snapshots = fixture['streaming'][0]['partial_snapshots']
            before_release = [s for s in snapshots if s['at_ms'] < fixture['audio_seconds'] * 1000]
            if not before_release:
                fixtures.append(dict(id=fixture['fixture'], usable=False, audio_ms=fixture['audio_seconds'] * 1000))
                continue
            first = before_release[0]
            final = fixture['streaming'][0]['text']
            partial_ids, final_ids = tokens(first['text']), tokens(final)
            shared = common_count(partial_ids, final_ids)
            if final_ids[:len(prefix)] != prefix or partial_ids[:len(prefix)] != prefix:
                raise ValueError('Fixed prefix mismatch')
            fixtures.append(dict(id=fixture['fixture'], usable=True, raw=final, partial_ids=partial_ids,
                first_partial_ms=first['at_ms'], lead_ms=fixture['audio_seconds'] * 1000 - first['at_ms'],
                shared_tokens=shared, added_shared_tokens=max(0, shared - len(prefix))))
        print('fixed_prefix_tokens=', len(prefix), 'partial_extra_tokens=',
              {f['id']: f.get('added_shared_tokens', 0) for f in fixtures}, flush=True)

        for fixture in fixtures:
            if not fixture['usable']:
                continue
            observations = []
            for repetition in range(args.repetitions):
                for candidate in (False, True) if repetition % 2 == 0 else (True, False):
                    prefill(prefix, False)  # Reset the isolated slot to press-time warm prefix.
                    partial_ms = prefill(fixture['partial_ids'], True) if candidate else 0
                    final_ms, prompt_ms, cached, output = finish(fixture['raw'])
                    if cached < len(prefix) - 1 or cached > fixture['shared_tokens'] + 2:
                        raise ValueError('Unexpected prompt reuse')
                    observations.append(dict(repetition=repetition, condition='partial' if candidate else 'baseline',
                        final_ms=final_ms, prompt_ms=prompt_ms, cached_tokens=cached, partial_prefill_ms=partial_ms,
                        projected_release_ms=final_ms + max(0, partial_ms - fixture['lead_ms'])))
                    fixture.setdefault('outputs', set()).add(output)
            if len(fixture['outputs']) != 1:
                raise ValueError('Output parity failed')
            del fixture['outputs']
            fixture['baseline'] = {key: summary([o[key] for o in observations if o['condition'] == 'baseline'])
                                   for key in ('final_ms', 'prompt_ms', 'cached_tokens')}
            fixture['partial'] = {key: summary([o[key] for o in observations if o['condition'] == 'partial'])
                                  for key in ('final_ms', 'prompt_ms', 'cached_tokens', 'partial_prefill_ms')}
            fixture['projected_saving_ms'] = summary([
                next(o['final_ms'] for o in observations if o['repetition'] == i and o['condition'] == 'baseline')
                - next(o['projected_release_ms'] for o in observations if o['repetition'] == i and o['condition'] == 'partial')
                for i in range(args.repetitions)])
            fixture['exact_output_parity'] = True
            print(fixture['id'], 'projected_median_saving_ms=', fixture['projected_saving_ms']['median'], flush=True)
        report = dict(schema=1, experiment='partial-to-gemma-prefill-mock',
            created_utc=datetime.now(timezone.utc).isoformat(), repetitions=args.repetitions,
            fixed_prefix_tokens=len(prefix), isolated_server=True, ram_prompt_cache_disabled=True,
            physical_capture_asr_insertion_measured=False, projected_release_saving=True,
            private_content_recorded=False, fixtures=[{k: v for k, v in f.items() if k not in ('raw', 'partial_ids')}
                for f in fixtures])
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(json.dumps(report, indent=2) + '\n')
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
    parser.add_argument('--snapshots', type=Path, default=ROOT / 'bench/results/streaming-snapshots.json')
    parser.add_argument('--output', type=Path, default=ROOT / 'bench/results/partial-prefill.json')
    parser.add_argument('--repetitions', type=int, default=30)
    args = parser.parse_args()
    if args.repetitions < 1:
        parser.error('Positive repetition count required')
    try:
        run(args)
    except Exception as error:
        parser.exit(1, f'Partial prefill mock failed ({type(error).__name__}); request content suppressed.\n')

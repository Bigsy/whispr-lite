#!/usr/bin/env python3
"""Compare local cleanup models without persisting private transcripts or outputs."""

import argparse
import collections
import difflib
import json
import pathlib
import sqlite3
import statistics
import subprocess
import time
import urllib.error
from cleanup_bench import (DEFAULT_PROMPT, LOCK, DictionaryCorrections, LocalHTTP,
                           isolated_server, load_saved_cleanup, loopback_url)


ROOT = pathlib.Path(__file__).resolve().parent.parent
SUPPORT = pathlib.Path.home() / 'Library/Application Support/WhisprLite'
HISTORY = pathlib.Path.home() / 'Library/Application Support/open-whispr/transcriptions.db'


def post(endpoint, path, payload, timeout=120):
    return LocalHTTP(endpoint).post(path, payload, timeout=timeout)


def get(endpoint, path, timeout=2):
    return LocalHTTP(endpoint).get(path, timeout=timeout)


def local_endpoint(value):
    return loopback_url(value)


def words(text):
    import re
    return re.findall(r'\w+', text.casefold())


def matches_synthetic(fixture, output):
    if fixture['expected'] == ['']:
        return output == ''
    return (any(words(output) == words(expected) for expected in fixture['expected'])
            and output.count('\n') >= fixture.get('minimum_line_breaks', 0)
            and output.endswith(fixture.get('required_suffix', '')))


def describe(reference, output):
    valid = [(left, right) for left, right in zip(reference, output) if left is not None and right is not None]
    return {
        'evaluated': len(valid),
        'exact': sum(left.strip() == right.strip() for left, right in valid),
        'word_sequence': sum(words(left) == words(right) for left, right in valid),
        'median_character_similarity': round(statistics.median(
            difflib.SequenceMatcher(None, left.casefold(), right.casefold(), autojunk=False).ratio()
            for left, right in valid), 4) if valid else None,
    }


def load_history(path):
    # Immutable read keeps the application's SQLite files untouched.
    with sqlite3.connect(path.as_uri() + '?mode=ro&immutable=1', uri=True) as connection:
        rows = connection.execute("select raw_text, text from transcriptions "
                                  "where status='completed' and deleted_at is null order by id").fetchall()
    return [(raw, cleaned) for raw, cleaned in rows if raw and raw.strip() and cleaned is not None]


def clean(endpoint, alias, system, raw, framing, corrections):
    user = (f'<transcript>\n{raw}\n</transcript>\n\nOutput only the cleaned transcript.'
            if framing == 'openWhispr' else raw)
    limit = min(1024, max(128, len(raw.encode()) // 2 + 64))
    start = time.monotonic()
    try:
        response = post(endpoint, '/v1/chat/completions', {
            'model': alias, 'messages': [{'role': 'system', 'content': system}, {'role': 'user', 'content': user}],
            'temperature': 0, 'max_tokens': limit, 'stream': False,
            'chat_template_kwargs': {'enable_thinking': False}})
        choice = response['choices'][0]
        if choice.get('finish_reason') != 'stop' or not isinstance(choice['message'].get('content'), str):
            return None, (time.monotonic() - start) * 1000, 'incomplete'
        output = corrections.apply(choice['message']['content'].strip())
        return output, (time.monotonic() - start) * 1000, None
    except (OSError, ValueError, KeyError, IndexError, TypeError, urllib.error.URLError):
        return None, (time.monotonic() - start) * 1000, 'request_failed'


def run_model(label, endpoint, alias, system, synthetic_system, framing, corrections, samples, fixtures):
    # Prime the fixed prefix before measuring; all inputs and outputs stay in RAM.
    clean(endpoint, alias, system, 'synthetic warmup', framing, corrections)
    actual, latency, errors = [], [], collections.Counter()
    for raw, _ in samples:
        output, elapsed, error = clean(endpoint, alias, system, raw, framing, corrections)
        actual.append(output)
        if error:
            errors[error] += 1
        else:
            latency.append(elapsed)
    synthetic_failed = []
    for fixture in fixtures:
        output, _, error = clean(endpoint, alias, synthetic_system, fixture['raw'], framing, DictionaryCorrections(''))
        if error or not matches_synthetic(fixture, output):
            synthetic_failed.append(fixture['id'])
    metrics = {'real_count': len(samples), 'real_errors': dict(errors),
               'synthetic_passed': len(fixtures) - len(synthetic_failed),
               'synthetic_total': len(fixtures), 'synthetic_failed_ids': synthetic_failed,
               'warm_median_ms': round(statistics.median(latency), 2) if latency else None,
               'warm_p95_ms': round(sorted(latency)[int((len(latency) - 1) * .95)], 2) if latency else None}
    print(label, 'real_success', len(latency), 'synthetic', metrics['synthetic_passed'], '/', len(fixtures), flush=True)
    return actual, metrics


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--history', type=pathlib.Path, default=HISTORY)
    parser.add_argument('--support', type=pathlib.Path, default=SUPPORT)
    parser.add_argument('--binary', type=pathlib.Path, required=True)
    parser.add_argument('--candidate', action='append', nargs=3, metavar=('LABEL', 'GGUF', 'ALIAS'), required=True)
    parser.add_argument('--candidate-prompt', action='append', nargs=2, metavar=('LABEL', 'PROMPT_FILE'), default=[])
    parser.add_argument('--output', type=pathlib.Path, default=ROOT / 'bench/results/cleanup-models.json')
    args = parser.parse_args()
    saved = load_saved_cleanup(args.support)
    prompt = saved.prompt
    dictionary = saved.dictionary
    corrections = DictionaryCorrections(dictionary)
    vocabulary = corrections.vocabulary
    dictionary_suffix = saved.dictionary_prefix + vocabulary if vocabulary else ''
    system = prompt + dictionary_suffix
    candidate_prompts = {label: pathlib.Path(path).read_text().strip() for label, path in args.candidate_prompt}
    synthetic_prompt = DEFAULT_PROMPT
    synthetic_dictionary = '\nCustom dictionary:\nClojure, mapv, Parakeet, Gemma, Whispr Lite'
    framing = saved.input_format
    samples = load_history(args.history)
    fixtures = (json.loads((ROOT / 'bench/prompt-fixtures.json').read_text())
                + json.loads((ROOT / 'bench/model-cleanup-fixtures.json').read_text()))
    endpoint = local_endpoint(saved.endpoint)
    baseline_alias = LOCK['alias']
    if baseline_alias not in [item['id'] for item in get(endpoint, '/v1/models')['data']]:
        raise RuntimeError('installed Gemma baseline is not ready')
    print('real_samples', len(samples), 'synthetic_samples', len(fixtures), flush=True)
    historical = [cleaned for _, cleaned in samples]
    baseline, baseline_metrics = run_model('gemma4-e2b', endpoint, baseline_alias, system,
                                           synthetic_prompt + synthetic_dictionary, framing, corrections, samples, fixtures)
    baseline_metrics['versus_historical'] = describe(historical, baseline)
    report = {'schema': 1, 'method': 'local-real-history-and-synthetic',
              'real_source': 'OpenWhispr completed raw/cleaned pairs, immutable SQLite read',
              'real_prompt': 'saved private prompt and dictionary, held in RAM',
              'synthetic_prompt': 'bundled default and public synthetic dictionary',
              'reference_note': 'Historical cleaned text and Gemma output are references, not reviewed ground truth.',
              'framing': framing, 'temperature': 0, 'private_text_saved': False,
              'model_results': {'gemma4-e2b': baseline_metrics}}
    for label, path, alias in args.candidate:
        with isolated_server(spec_type='none', model=path, alias=alias, binary=args.binary,
                             extra=('--cache-ram', '0')) as server:
            server_endpoint = server.endpoint
            model_system = candidate_prompts.get(label, prompt) + dictionary_suffix
            model_synthetic = candidate_prompts.get(label, synthetic_prompt) + synthetic_dictionary
            output, metrics = run_model(label, server_endpoint, alias, model_system,
                                        model_synthetic, framing, corrections, samples, fixtures)
            metrics['prompt_profile'] = 'candidate' if label in candidate_prompts else 'saved'
            metrics['versus_historical'] = describe(historical, output)
            metrics['versus_gemma'] = describe(baseline, output)
            consensus = [i for i, (old, gemma) in enumerate(zip(historical, baseline)) if gemma is not None and old.strip() == gemma.strip()]
            metrics['versus_consensus'] = describe([historical[i] for i in consensus], [output[i] for i in consensus])
            metrics['model_bytes'] = pathlib.Path(path).stat().st_size
            rss = subprocess.run(['ps', '-o', 'rss=', '-p', str(server.process.pid)], capture_output=True, text=True, check=False)
            metrics['server_rss_kib_after'] = int(rss.stdout.strip()) if rss.stdout.strip().isdigit() else None
            report['model_results'][label] = metrics
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, indent=2) + '\n')
    print('aggregate_report', args.output, flush=True)


if __name__ == '__main__':
    main()

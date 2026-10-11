#!/usr/bin/env python3
"""Compare cleanup prompts locally; reports contain only synthetic case IDs and metrics."""
import argparse
import json
import math
from pathlib import Path
import statistics
import time
from cleanup_bench import (ALIAS, LocalHTTP, SYNTHETIC_DICTIONARY, app_request,
                           load_fixtures, loopback_url, matches_synthetic, messages)

ROOT = Path(__file__).resolve().parent.parent


def summary(values):
    values = sorted(values)
    return dict(n=len(values), median=statistics.median(values),
                p90=values[math.ceil(len(values) * .90) - 1],
                p95=values[math.ceil(len(values) * .95) - 1])


def run(args, extra_context=''):
    http = LocalHTTP(loopback_url(args.endpoint))
    if not args.quality_only and args.repetitions < 30:
        raise ValueError('At least 30 observations per performance condition are required')
    fixtures = load_fixtures('prompt-fixtures.json')
    prompts = {'baseline': args.baseline_prompt.read_text().strip(),
               'default': args.candidate_prompt.read_text().strip()}
    context = extra_context or (args.candidate_context_file.read_text().strip() if args.candidate_context_file else '')
    if context: prompts['default_with_context'] = prompts['default'] + '\n\n' + context
    dictionary = args.dictionary_file.read_text() if args.dictionary_file else ''
    prefix = '\nCustom dictionary:\n'
    if args.import_file:
        prefix = json.loads(args.import_file.read_text()).get('cleanupDictionaryPrefix', prefix)
    dictionary = prefix + dictionary if dictionary else ''
    observations, quality, variants = [], [], {}
    def complete(chat_messages, raw, cached):
        body, count = app_request(http, ALIAS, chat_messages, raw, cache_prompt=cached)
        inference_start = time.monotonic()
        return http.post('/v1/chat/completions', body, timeout=20), count, inference_start

    def output(result):
        choice = result['choices'][0]
        if choice.get('finish_reason') != 'stop': raise ValueError('Synthetic output was truncated')
        return choice['message']['content'].strip()

    # Review with a public synthetic dictionary, independent of private vocabulary.
    for framing in ('plain', 'openWhispr'):
        for condition, prompt in prompts.items():
            passed, failed = [], []
            for fixture in fixtures:
                chat_messages = messages(prompt + SYNTHETIC_DICTIONARY, fixture['raw'], framing)
                text = output(complete(chat_messages, fixture['raw'], True)[0])
                (passed if matches_synthetic(fixture, text) else failed).append(fixture['id'])
            quality.append(dict(condition=condition, framing=framing, passed=len(passed), total=len(fixtures), failed=failed))
            print(json.dumps(quality[-1]), flush=True)

    if not args.quality_only:
        selected = [fixture for fixture in fixtures if fixture['id'] in ('question', 'correction', 'uncertainty', 'request')]
        for cache_mode in ('uncached', 'warm'):
            for round_index in range(args.repetitions):
                conditions = list(prompts) if round_index % 2 == 0 else list(reversed(prompts))
                cases = selected[round_index % len(selected):] + selected[:round_index % len(selected)]
                for condition in conditions:
                    prompt = prompts[condition]
                    if cache_mode == 'warm':
                        # Re-prime each interleaved block so prompt switching is not called warm use.
                        primer = 'the next dictation is ready'
                        output(complete(messages(prompt + dictionary, primer, args.framing), primer, True)[0])
                    for fixture in cases:
                        chat_messages = messages(prompt + dictionary, fixture['raw'], args.framing)
                        start = time.monotonic()
                        result, count, inference_start = complete(chat_messages, fixture['raw'], cache_mode == 'warm')
                        end = time.monotonic()
                        text = output(result)
                        timing = result['timings']
                        if cache_mode == 'uncached' and timing['cache_n'] != 0:
                            raise ValueError('Server reused tokens in the uncached condition')
                        variants.setdefault((condition, cache_mode, fixture['id']), set()).add(text)
                        observations.append(dict(condition=condition, cache_mode=cache_mode,
                            fixture=fixture['id'], round=round_index + 1, request_tokens=count,
                            cached_tokens=timing['cache_n'], processed_tokens=timing['prompt_n'],
                            generated_tokens=timing['predicted_n'], prompt_ms=timing['prompt_ms'],
                            generation_ms=timing['predicted_ms'], completion_ms=(end-inference_start)*1000,
                            app_cleanup_ms=(end-start)*1000))
                if (round_index + 1) % 5 == 0:
                    print(f'{cache_mode}: {round_index + 1}/{args.repetitions} rounds', flush=True)

    aggregates = []
    for condition in prompts:
        for cache_mode in ('uncached', 'warm'):
            rows = [row for row in observations if row['condition'] == condition and row['cache_mode'] == cache_mode]
            if not rows: continue
            value = dict(condition=condition, cache_mode=cache_mode,
                         output_repeat_consistent=all(len(outputs) == 1 for (label, mode, _), outputs in variants.items() if label == condition and mode == cache_mode))
            for field in ('request_tokens', 'cached_tokens', 'processed_tokens', 'generated_tokens', 'prompt_ms', 'generation_ms', 'completion_ms', 'app_cleanup_ms'):
                value[field] = summary([row[field] for row in rows])
            aggregates.append(value)
            print(json.dumps(value), flush=True)
    report = dict(schema=1, mode='synthetic-cleanup-prompt-comparison', quality=quality,
                  request_framing='app-proportional-exact-token-budget',
                  prompt_characters={name: len(prompt) for name, prompt in prompts.items()},
                  dictionary_in_performance=bool(dictionary), context_in_candidate=bool(context),
                  aggregates=aggregates, observations=observations,
                  repetitions=args.repetitions, private_contents_recorded=False,
                  physical_dictation_measured=False, long_idle_or_model_load_measured=False,
                  warm_blocks_primed=True, uncached_means_prompt_cache_disabled=True)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, indent=2) + '\n')
    return report


def parser():
    result = argparse.ArgumentParser(description=__doc__)
    result.add_argument('--baseline-prompt', type=Path, required=True)
    result.add_argument('--candidate-prompt', type=Path, default=ROOT / 'Resources/cleanup-prompt.txt')
    result.add_argument('--candidate-context-file', type=Path)
    result.add_argument('--dictionary-file', type=Path)
    result.add_argument('--import-file', type=Path)
    result.add_argument('--framing', choices=('plain', 'openWhispr'), default='openWhispr')
    result.add_argument('--endpoint', default='http://127.0.0.1:11436')
    result.add_argument('--repetitions', type=int, default=30)
    result.add_argument('--quality-only', action='store_true')
    result.add_argument('--output', type=Path, default=ROOT / 'bench/results/prompt-review.json')
    return result


if __name__ == '__main__':
    argument_parser = parser()
    try: run(argument_parser.parse_args())
    except (OSError, ValueError, KeyError, TypeError):
        argument_parser.exit(1, 'Prompt comparison failed; private request/response details suppressed.\n')

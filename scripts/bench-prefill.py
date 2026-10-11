#!/usr/bin/env python3
"""Disposable fixed-prefix experiment. Synthetic input; private text stays in RAM."""
import argparse
from datetime import datetime, timezone
import json
from pathlib import Path
import time

from importlib.util import spec_from_file_location, module_from_spec
from cleanup_bench import (ALIAS, DictionaryCorrections, LocalHTTP, isolated_server,
                           load_saved_cleanup, loopback_url)

ROOT = Path(__file__).resolve().parent.parent
spec = spec_from_file_location('prompt_bench', ROOT / 'scripts/bench-prompts.py')
helpers = module_from_spec(spec)
spec.loader.exec_module(helpers)


def run(args):
    endpoint = loopback_url(args.endpoint)
    if args.repetitions < 1 or not 0 <= args.hold_seconds <= 10:
        raise ValueError('Invalid benchmark bounds')
    saved = load_saved_cleanup(args.settings_dir)
    prefs = saved.preferences
    if not args.isolated_server and saved.endpoint.rstrip('/') != args.endpoint.rstrip('/'):
        raise ValueError('Endpoint differs from saved configuration')
    # Post-cleanup substitutions are outside this experiment.
    dictionary = DictionaryCorrections(saved.dictionary).vocabulary
    system = saved.prompt + (saved.dictionary_prefix + dictionary if dictionary else '')
    http = LocalHTTP(endpoint)

    def post(route, body):
        return http.post(route, body)

    def messages(raw):
        user = f'<transcript>\n{raw}\n</transcript>\n\nOutput only the cleaned transcript.' if prefs.get('cleanupInputFormat') == 'openWhispr' else raw
        if len(system.encode()) + len(user.encode()) > 16384:
            raise ValueError('Byte budget exceeded')
        return [dict(role='system', content=system), dict(role='user', content=user)]

    def tokenise_messages(raw):
        rendered = post('/apply-template', dict(messages=messages(raw), chat_template_kwargs=dict(enable_thinking=False)))['prompt']
        # Chat completion adds the model's BOS token. Include it in the explicit
        # native token array or the two routes share zero prefix tokens.
        tokens = post('/tokenize', dict(content=rendered, add_special=True, parse_special=True))['tokens']
        if len(tokens) + 512 > 4096:
            raise ValueError('Context budget exceeded')
        return tokens

    def complete(raw, cached):
        result = post('/v1/chat/completions', dict(model=ALIAS, messages=messages(raw),
                      temperature=0, max_tokens=512, stream=False, cache_prompt=cached, id_slot=0,
                      chat_template_kwargs=dict(enable_thinking=False)))
        if result['choices'][0]['finish_reason'] != 'stop':
            raise ValueError('Incomplete final output')
        return result, result['choices'][0]['message']['content'].strip()

    def prefill(tokens, cached):
        result = post('/completion', dict(prompt=tokens, n_predict=0, cache_prompt=cached,
                      temperature=0, stream=False, return_tokens=True, id_slot=0))
        # This pinned server can sample one token even with n_predict=0. Discard it
        # and report this explicitly; never call it verified zero-token prefill.
        if result.get('truncated') or not 0 <= result['tokens_predicted'] <= 1:
            raise ValueError('Unexpected prefill generation')
        return result

    # Derive a fixed token prefix using two unrelated synthetic continuations.
    # No final transcript is needed to prepare this prefix.
    a, b = tokenise_messages('ZZZ synthetic marker'), tokenise_messages('aaa different marker')
    prefix = []
    for left, right in zip(a, b):
        if left != right:
            break
        prefix.append(left)
    if not prefix:
        raise ValueError('No common prefix')
    fixtures = [f for f in json.loads((ROOT / 'bench/prompt-fixtures.json').read_text()) if f['id'] in ('question', 'correction')]
    fixtures.append(dict(id='long', raw=' '.join([
        'please send the updated report to the team on thursday no wait friday',
        'the first section should explain the microphone issue and the second should cover the clipboard',
        'we tested the short recordings yesterday and they looked good but the longer recordings still need another review',
        'keep the existing settings for now and make a note of any missing words',
        'i think we should compare the results before deciding whether to change the default',
    ])))
    for fixture in fixtures:
        if tokenise_messages(fixture['raw'])[:len(prefix)] != prefix:
            raise ValueError('Final prompt does not match prefix')

    # Controlled prior dictation for each warm condition. Use real generation,
    # matching the slot state that a previous successful cleanup leaves behind.
    primer = 'the next synthetic dictation is ready'
    variants, condition_variants, paired_outputs, observations = {}, {}, {}, []
    conditions = ['miss_baseline', 'miss_prefill', 'warm_baseline', 'warm_prefill']
    print(f'prefix_tokens={len(prefix)} fixtures={len(fixtures)} hold_seconds={args.hold_seconds}', flush=True)
    for repetition in range(args.repetitions):
        order = conditions[repetition % 4:] + conditions[:repetition % 4]
        for fixture in fixtures[repetition % 3:] + fixtures[:repetition % 3]:
            for condition in order:
                warm = condition.startswith('warm')
                candidate = condition.endswith('prefill')
                if warm:
                    complete(primer, True)
                press = time.monotonic()
                release = press + args.hold_seconds
                start = time.monotonic()
                prepared = prefill(prefix, warm) if candidate else None
                prefill_ms = (time.monotonic() - start) * 1000 if candidate else 0
                # Mock recording: no microphone or ASR. Work can run during this
                # hold, but a release before it completes must wait for settlement.
                time.sleep(max(0, release - time.monotonic()))
                final_start = time.monotonic()
                final_tokens = tokenise_messages(fixture['raw'])
                completion_start = time.monotonic()
                result, output = complete(fixture['raw'], warm or candidate)
                end = time.monotonic()
                timing = result['timings']
                if not warm and not candidate and timing['cache_n'] != 0:
                    raise ValueError('Forced miss reused cache')
                if prepared and not warm and prepared['timings']['cache_n'] != 0:
                    raise ValueError('Forced prefill miss reused cache')
                if (warm or candidate) and timing['cache_n'] < len(prefix) - 1:
                    print(json.dumps(dict(condition=condition, fixture=fixture['id'], prefix_tokens=len(prefix),
                        final_tokens=len(final_tokens), cached_tokens=timing['cache_n'], processed_tokens=timing['prompt_n'],
                        prefill_evaluated=prepared.get('tokens_evaluated') if prepared else None,
                        prefill_cached=prepared['timings']['cache_n'] if prepared else None)), flush=True)
                    raise ValueError('Expected prefix was not reused')
                if timing['cache_n'] > len(prefix) + 2:
                    raise ValueError('Prior final transcript contaminated prefix benchmark')
                previous = variants.setdefault(fixture['id'], output)
                previous_condition = condition_variants.setdefault((fixture['id'], condition), output)
                paired_outputs[fixture['id'], repetition+1, condition] = output
                item = dict(fixture=fixture['id'], condition=condition, round=repetition + 1,
                    exact_output_equal=output == previous, words_equal=helpers.words(output) == helpers.words(previous),
                    condition_repeat_equal=output == previous_condition,
                    prefill_ms=prefill_ms, release_to_clean_ms=(end-release)*1000,
                    release_wait_ms=(final_start-release)*1000, final_cleanup_ms=(end-final_start)*1000,
                    request_preparation_ms=(completion_start-final_start)*1000,
                    total_request_work_ms=prefill_ms+(end-final_start)*1000,
                    press_to_clean_ms=(end-press)*1000, request_tokens=len(final_tokens),
                    cached_tokens=timing['cache_n'], processed_tokens=timing['prompt_n'],
                    generated_tokens=timing['predicted_n'], prompt_ms=timing['prompt_ms'], generation_ms=timing['predicted_ms'],
                    prefill_predicted_tokens=prepared['tokens_predicted'] if prepared else 0,
                    prefill_emitted_text=bool(prepared.get('content')) if prepared else False,
                    prefill_prompt_ms=prepared['timings']['prompt_ms'] if prepared else 0,
                    prefill_cached_tokens=prepared['timings']['cache_n'] if prepared else 0)
                # A sensitivity estimate from the same measured request durations;
                # these are explicitly projections, not additional paced trials.
                item['projected_release_ms'] = {str(lead): max(0, prefill_ms-lead*1000)+(end-final_start)*1000
                                                for lead in (.25, 1, 3)}
                observations.append(item)
        print(f'round {repetition+1}/{args.repetitions}; parity={all(r["exact_output_equal"] for r in observations)}', flush=True)

    aggregates = []
    for fixture in fixtures:
        for condition in conditions:
            rows = [r for r in observations if r['fixture'] == fixture['id'] and r['condition'] == condition]
            aggregate = dict(fixture=fixture['id'], condition=condition,
                             exact_output_equal=all(r['exact_output_equal'] for r in rows),
                             words_equal=all(r['words_equal'] for r in rows),
                             condition_repeat_equal=all(r['condition_repeat_equal'] for r in rows))
            for field in ('prefill_ms', 'release_to_clean_ms', 'release_wait_ms', 'final_cleanup_ms', 'total_request_work_ms',
                          'cached_tokens', 'processed_tokens', 'generated_tokens', 'prompt_ms', 'generation_ms'):
                aggregate[field] = helpers.summary([r[field] for r in rows])
            aggregates.append(aggregate)
    paired = []
    for fixture in fixtures:
        for cache in ('miss', 'warm'):
            by_key = {(r['round'], r['condition']): r for r in observations if r['fixture'] == fixture['id']}
            gains = [by_key[i, cache+'_baseline']['release_to_clean_ms']-by_key[i, cache+'_prefill']['release_to_clean_ms']
                     for i in range(1, args.repetitions+1)]
            pairs = [(paired_outputs[fixture['id'], i, cache+'_baseline'], paired_outputs[fixture['id'], i, cache+'_prefill'])
                     for i in range(1, args.repetitions+1)]
            paired.append(dict(fixture=fixture['id'], cache=cache, saved_release_ms=helpers.summary(gains),
                               exact_equal_pairs=sum(a == b for a, b in pairs),
                               words_equal_pairs=sum(helpers.words(a) == helpers.words(b) for a, b in pairs)))
    report = dict(schema=1, experiment='fixed-prefix-prefill', created_utc=datetime.now(timezone.utc).isoformat(),
                  repetitions=args.repetitions, exploratory=args.repetitions < 30, hold_seconds=args.hold_seconds,
                  prefix_tokens=len(prefix), private_content_recorded=False, model_weights_warm=True,
                  miss_is_forced_cache_disabled=True, warm_primed_before_each_observation=True,
                  physical_capture_asr_insertion_measured=False, post_cleanup_dictionary_corrections_measured=False,
                  prefix_setup_outside_timing=True, projections_assume_unchanged_request_cost=True,
                  explicit_slot=0, rejects_prior_transcript_cache_hits=True,
                  isolated_server=args.isolated_server, ram_prompt_cache_disabled=args.isolated_server,
                  output_comparison='exact trimmed model output against first result per fixture; content kept only in RAM',
                  exact_output_parity=all(r['exact_output_equal'] for r in observations),
                  words_parity=all(r['words_equal'] for r in observations),
                  zero_generated_tokens_verified=all(r['prefill_predicted_tokens'] == 0 for r in observations),
                  prefill_emitted_text_observed=any(r['prefill_emitted_text'] for r in observations),
                  stack=json.loads((ROOT / 'Resources/cleanup-stack.json').read_text())['llama_server']['revision'],
                  aggregates=aggregates, paired=paired, observations=observations)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, indent=2)+'\n')
    for comparison in paired:
        print(json.dumps(comparison), flush=True)
    print(f'exact_parity={report["exact_output_parity"]} zero_generated_tokens={report["zero_generated_tokens_verified"]}', flush=True)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--settings-dir', type=Path, default=Path.home() / 'Library/Application Support/WhisprLite')
    parser.add_argument('--endpoint', default='http://127.0.0.1:11436')
    parser.add_argument('--repetitions', type=int, default=30)
    parser.add_argument('--hold-seconds', type=float, default=.5)
    parser.add_argument('--isolated-server', action='store_true', help='Own a temporary server on 11437 with --cache-ram 0; reuse verified model files read-only')
    parser.add_argument('--output', type=Path, default=ROOT / 'bench/results/prefill.json')
    try:
        args = parser.parse_args()
        if args.isolated_server:
            with isolated_server(extra=('--cache-ram', '0')) as server:
                args.endpoint = server.endpoint
                print('Temporary benchmark server ready; installed service unchanged.', flush=True)
                run(args)
        else:
            run(args)
    except KeyboardInterrupt:
        parser.exit(130, 'Prefill experiment interrupted; incomplete run discarded.\n')
    except Exception as error:
        safe_reasons = {'Temporary server exited', 'Temporary server not ready',
                        'Prior final transcript contaminated prefix benchmark', 'Expected prefix was not reused',
                        'Forced miss reused cache', 'Forced prefill miss reused cache', 'Unexpected prefill generation'}
        reason = str(error) if str(error) in safe_reasons else type(error).__name__
        parser.exit(1, f'Prefill experiment failed ({reason}); private request/response details suppressed.\n')

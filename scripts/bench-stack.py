#!/usr/bin/env python3
"""Optional cleanup baseline. No private dictionaries required."""
import argparse
import json
from pathlib import Path
import time
from cleanup_bench import ALIAS, SERVICE_PORT, LocalHTTP, load_fixtures, loopback_url, write_report
root = Path(__file__).resolve().parent.parent
parser = argparse.ArgumentParser()
parser.add_argument('--repetitions', type=int, default=30)
parser.add_argument('--idle-seconds', type=int, nargs='*', default=[])
parser.add_argument('--prompt-file', type=Path, required=True, help='Exported/reviewed prompt; not the development substitute')
parser.add_argument('--dictionary-file', type=Path)
parser.add_argument('--import-file', type=Path, help='Private cleanup-import.json from export-openwhispr.py')
parser.add_argument('--endpoint', default=f'http://127.0.0.1:{SERVICE_PORT}')
parser.add_argument('--compare-reference-budget', action='store_true', help='Compare 512-token output cap against OpenWhispr 1.8.3\'s 4096 minimum')
args = parser.parse_args()
if args.repetitions < 30: parser.error('At least 30 warm observations are required')
fixtures = load_fixtures('cleanup-fixtures.json')
prompt = args.prompt_file.read_text()
metadata = json.loads(args.import_file.read_text()) if args.import_file else {}
dictionary = args.dictionary_file.read_text() if args.dictionary_file else ''
if dictionary: prompt += metadata.get('cleanupDictionaryPrefix', '\nCustom dictionary:\n') + dictionary
args.endpoint = loopback_url(args.endpoint)
http = LocalHTTP(args.endpoint)
observations = []
outputs = {}
def request(fixture, condition, maximum=512):
    raw = fixture['raw']
    if metadata.get('cleanupInputFormat') == 'openWhispr': raw = f'<transcript>\n{raw}\n</transcript>\n\nOutput only the cleaned transcript.'
    body = dict(model=ALIAS, messages=[dict(role='system', content=prompt),dict(role='user', content=raw)],
                temperature=0, max_tokens=512, stream=False, chat_template_kwargs=dict(enable_thinking=False))
    body['max_tokens'] = maximum
    start = time.monotonic()
    result = http.post('/v1/chat/completions', body, timeout=10)
    text = result['choices'][0]['message']['content'].strip()
    if result['choices'][0].get('finish_reason') != 'stop': raise RuntimeError('Truncated cleanup result')
    previous = outputs.setdefault(fixture['id'], text)
    if previous != text: raise RuntimeError('Cleanup output changed between repetitions')
    observations.append(dict(fixture=fixture['id'], condition=condition, milliseconds=(time.monotonic()-start)*1000,
                             expected_matches=fixture['expected'] == text if fixture['expected'] is not None else None))
for fixture in fixtures:
    request(fixture, 'warmup')
    if args.compare_reference_budget: request(fixture, 'reference-4096-token-cap', maximum=4096)
for _ in range(args.repetitions):
    for fixture in fixtures: request(fixture, 'warm')
    print(f'Cleanup warm round {_+1}/{args.repetitions}', flush=True)
for idle in args.idle_seconds:
    time.sleep(idle)
    request(fixtures[0], f'idle-{idle}s')
report = dict(schema=1, mode='real-cleanup-only', observations=observations,
              request_framing='legacy-512',
              stack_inventory=json.loads((root/'stack.lock.json').read_text()),
              visible_text_measured=False, memory_pressure_measured=False,
              original_prompt_resolved=bool(metadata), reference_budget_parity=args.compare_reference_budget,
              endpoint=args.endpoint, private_contents_recorded=False)
write_report(root/'bench/results/cleanup.json', report, 'real-cleanup-only', forbidden=(prompt, dictionary))
print(f'{len(observations)} observations saved to bench/results/cleanup.json; expected outputs remain pending unless fixtures are frozen.')

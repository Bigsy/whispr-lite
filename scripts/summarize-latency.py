#!/usr/bin/env python3
"""Summarise explicit physical release-to-visible observations, with no dictated text."""
import argparse
from collections import defaultdict
import json
import math
from pathlib import Path
import statistics

METADATA = ('build', 'chip', 'macos', 'asr_model', 'asr_runtime',
            'cleanup_model', 'cleanup_runtime', 'capture_mode', 'observation_method')
TIMINGS = ('release_to_visible_ms', 'capture_ms', 'asr_ms', 'cleanup_ms', 'insertion_ms')


def percentiles(values):
    ordered = sorted(values)
    return {'n': len(values), 'p50_ms': statistics.median(values),
            'p95_ms': ordered[math.ceil(len(values) * .95) - 1]}


def summarize(source):
    if not isinstance(source, dict) or source.get('schema') != 1 or any(not isinstance(source.get(key), str)
                                      or not source[key].strip() for key in METADATA):
        raise ValueError('Schema 1 and complete machine, model, build and observation metadata are required')
    if source['capture_mode'] not in ('on-demand', 'warm'):
        raise ValueError('capture_mode must be on-demand or warm')
    if source['observation_method'] not in ('video', 'accessibility-observer'):
        raise ValueError('Use video or an accessibility observer; dispatch is not visible text')
    observations = source.get('observations', [])
    if not isinstance(observations, list) or len(observations) < 30:
        raise ValueError('At least 30 physical release-to-visible observations are required')
    groups = defaultdict(list)
    for observation in observations:
        if not isinstance(observation, dict):
            raise ValueError('Each observation must be an object')
        if observation.get('condition') not in ('cold', 'warm'):
            raise ValueError('Each observation needs a cold or warm condition')
        if not all(isinstance(observation.get(key), str) and observation[key].strip()
                   for key in ('destination', 'destination_version')):
            raise ValueError('Each observation needs a destination app and version')
        for key in TIMINGS:
            value = observation.get(key)
            if isinstance(value, bool) or not isinstance(value, (int, float)) or not math.isfinite(value) or value < 0:
                raise ValueError('Each observation needs finite, nonnegative visible-text and stage timings')
        groups[(observation['destination'], observation['destination_version'], observation['condition'])].append(observation)
    return dict(schema=1, **{key: source[key] for key in METADATA},
                percentile_method='nearest-rank', private_content_recorded=False,
                overall={key: percentiles([row[key] for row in observations]) for key in TIMINGS},
                groups=[dict(destination=app, destination_version=version, condition=condition,
                             timings={key: percentiles([row[key] for row in rows]) for key in TIMINGS})
                        for (app, version, condition), rows in sorted(groups.items())])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('observations', type=Path)
    parser.add_argument('--output', type=Path, default=Path('.build/physical-latency.json'))
    args = parser.parse_args()
    try:
        result = summarize(json.loads(args.observations.read_text()))
    except (ValueError, KeyError, TypeError, OSError):
        parser.error('Invalid observations. See the physical latency protocol in Resources/EVALUATION.md.')
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(result, indent=2) + '\n')
    timing = result['overall']['release_to_visible_ms']
    print(f"{timing['n']} physical observations: p50 {timing['p50_ms']:.1f} ms, p95 {timing['p95_ms']:.1f} ms")


if __name__ == '__main__':
    main()

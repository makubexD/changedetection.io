"""What a NEW watch would inherit from this instance, before you generate one.

RUNS INSIDE THE RUNNING CONTAINER, on purpose, for the same reason probe.py
does: reading the raw datastore file here is what proves the answer matches
what the app actually has, rather than a config template's idea of the
defaults.

WHY THIS EXISTS. None of this is reachable over the API. `GET /api/v1/tags`
returns only title/uuid/notification_muted for each tag -- not its
url_match_pattern or its filters. There is no `GET /api/v1/settings` at all.
A generator that skips this step cannot tell a global default from a value
worth setting explicitly, and cannot know a tag is about to attach itself to
the watch by URL pattern before the watch is even created.

READ-ONLY, DELIBERATELY. This does not instantiate the application's
datastore class -- that class can migrate the file's schema and write it back
on load, which is a side effect this tool has no business causing just to
answer a question. Plain `json.load` on the file the app itself reads.

Secrets are never printed: `password` and `api_access_token` are reported as
present/absent, never as values, so this script's output is safe to paste
into a chat or a generated plan.
"""

import argparse
import json
import os
import sys

DATASTORE_PATH = os.environ.get('DATASTORE_PATH', '/datastore')
_SECRET_KEYS = ('password', 'api_access_token')


def load_datastore(path):
    """The raw changedetection.json dict, or abort with the fix -- never a stack trace."""
    json_path = os.path.join(path, 'changedetection.json')
    if not os.path.isfile(json_path):
        raise SystemExit(
            f"No datastore found at {json_path}.\n"
            "This reads the running app's own file, so it has to run inside the\n"
            "changedetection container.\n"
            "  fix: .\\contrib\\maku.ps1 app defaults")
    with open(json_path, 'r', encoding='utf-8') as f:
        return json.load(f)


def redact(application):
    """A copy of settings.application with secret values replaced by a presence flag."""
    safe = dict(application)
    for key in _SECRET_KEYS:
        safe[key] = bool(safe.get(key))
    return safe


def collect_llm_status(application):
    """Whether an LLM model is configured -- env wins over the datastore, as get_llm_config does."""
    env_model = os.environ.get('LLM_MODEL')
    if env_model:
        return {'configured': True, 'source': 'env', 'model': env_model}
    llm = application.get('llm') or {}
    model = llm.get('model')
    enabled = llm.get('enabled', True)
    if model and enabled:
        return {'configured': True, 'source': 'settings', 'model': model}
    return {'configured': False, 'source': None, 'model': None}


def collect_tags(application):
    """Every tag with the fields a generator needs: url_match_pattern and filters.

    A watch can acquire a tag it never asked for -- store/__init__.py matches
    tags to a watch by url_match_pattern as well as by explicit assignment --
    so this is printed to be checked BEFORE a watch is created, not after.
    """
    tags = application.get('tags') or {}
    out = []
    for uuid, tag in tags.items():
        out.append({
            'uuid': uuid,
            'title': tag.get('title'),
            'url_match_pattern': tag.get('url_match_pattern') or None,
            'overrides_watch': tag.get('overrides_watch'),
            'include_filters': tag.get('include_filters') or [],
            'subtractive_selectors': tag.get('subtractive_selectors') or [],
            'ignore_text': tag.get('ignore_text') or [],
            'notification_urls': tag.get('notification_urls') or [],
        })
    return out


def build_report(data):
    settings = data.get('settings', {})
    requests_ = settings.get('requests', {})
    application = settings.get('application', {})
    return {
        'requests': {
            'time_between_check': requests_.get('time_between_check'),
            'time_schedule_limit': requests_.get('time_schedule_limit'),
            'proxy': requests_.get('proxy'),
        },
        'application': redact(application),
        'llm': collect_llm_status(application),
        'tags': collect_tags(application),
        'watch_count': len(data.get('watching', {})),
    }


def print_human(report):
    print('What a new watch inherits if you set nothing:')
    tbc = report['requests']['time_between_check']
    print(f"  fetch_backend            {report['application'].get('fetch_backend')}")
    print(f"  time_between_check       {tbc}")
    print(f"  scheduler_timezone       {report['application'].get('scheduler_timezone_default')}")
    print(f"  global_ignore_text       {report['application'].get('global_ignore_text')}")
    print(f"  global_subtractive_sel   {report['application'].get('global_subtractive_selectors')}")
    print(f"  notification_urls        {report['application'].get('notification_urls')}")
    print(f"  api_access_token_enabled {report['application'].get('api_access_token_enabled')}")
    llm = report['llm']
    print(f"  llm configured           {llm['configured']}" +
          (f" ({llm['model']}, from {llm['source']})" if llm['configured'] else ''))
    print()
    if report['tags']:
        print(f"Tags ({len(report['tags'])}) -- a matching url_match_pattern attaches without asking:")
        for tag in report['tags']:
            pattern = tag['url_match_pattern'] or '(none -- only attaches if assigned)'
            print(f"  {tag['title']!r:<24} pattern: {pattern}")
            if tag['include_filters'] or tag['subtractive_selectors']:
                print(f"      include_filters={tag['include_filters']} "
                      f"subtractive_selectors={tag['subtractive_selectors']}")
    else:
        print('No tags defined.')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--json', action='store_true', help='print one JSON report instead of prose')
    args = parser.parse_args()

    data = load_datastore(DATASTORE_PATH)
    report = build_report(data)

    if args.json:
        print(json.dumps(report, indent=2, default=str))
    else:
        print_human(report)
    return 0


if __name__ == '__main__':
    sys.exit(main())

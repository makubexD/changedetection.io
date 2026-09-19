"""instance.py's own logic, on this machine, with no container and no real datastore.

Same shape as test_probe.py: only what is genuinely ours is tested here. The
datastore FILE FORMAT is fixture data below, not re-derived from App.py, so a
change to the real defaults shows up here as a human decision to update the
fixture -- not as a silent pass either way.
"""

import contextlib
import io
import json
import os
import sys
import tempfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import instance  # noqa: E402

failures = []


def check(label, condition, detail=''):
    print(f"{'ok  ' if condition else 'FAIL'} {label}")
    if not condition:
        failures.append(label)
        if detail:
            print(f"     {detail}")


def captured(fn, *args, **kwargs):
    buffer = io.StringIO()
    with contextlib.redirect_stdout(buffer):
        fn(*args, **kwargs)
    return buffer.getvalue()


FIXTURE = {
    'watching': {'uuid-1': {}, 'uuid-2': {}},
    'settings': {
        'requests': {'time_between_check': {'weeks': None, 'days': None, 'hours': 3,
                                             'minutes': None, 'seconds': None},
                      'time_schedule_limit': {}, 'proxy': None},
        'application': {
            'fetch_backend': 'html_requests',
            'scheduler_timezone_default': None,
            'global_ignore_text': [],
            'global_subtractive_selectors': [],
            'notification_urls': ['tgram://TOKEN/CHATID'],
            'api_access_token_enabled': True,
            'api_access_token': 'super-secret-value',
            'password': 'also-secret',
            'llm': {'enabled': True, 'model': 'gpt-4o-mini'},
            'tags': {
                'tag-uuid-1': {
                    'title': 'exchange-rates',
                    'url_match_pattern': 'tucambista.pe*',
                    'overrides_watch': None,
                    'include_filters': ['.rate'],
                    'subtractive_selectors': [],
                    'ignore_text': [],
                    'notification_urls': [],
                },
                'tag-uuid-2': {
                    'title': 'manual-only',
                    'url_match_pattern': '',
                    'overrides_watch': None,
                    'include_filters': [],
                    'subtractive_selectors': [],
                    'ignore_text': [],
                    'notification_urls': [],
                },
            },
        },
    },
}

# --- secrets are never leaked -------------------------------------------------

safe = instance.redact(FIXTURE['settings']['application'])
check('password is reported as present, not as its value',
      safe['password'] is True, safe['password'])
check('api_access_token is reported as present, not as its value',
      safe['api_access_token'] is True, safe['api_access_token'])
check('a non-secret field passes through unchanged',
      safe['fetch_backend'] == 'html_requests', safe['fetch_backend'])

empty_app = {'password': None, 'api_access_token': ''}
safe_empty = instance.redact(empty_app)
check('an unset secret is reported as absent, not present',
      safe_empty['password'] is False and safe_empty['api_access_token'] is False, safe_empty)

report = instance.build_report(FIXTURE)
out = captured(instance.print_human, report)
check('the human report never prints the raw secret values',
      'super-secret-value' not in out and 'also-secret' not in out, out)

# --- LLM configuration resolution --------------------------------------------

app = FIXTURE['settings']['application']
status = instance.collect_llm_status(app)
check('a configured model with llm enabled reads as configured',
      status == {'configured': True, 'source': 'settings', 'model': 'gpt-4o-mini'}, status)

unconfigured = instance.collect_llm_status({'llm': {'enabled': True, 'model': ''}})
check('an empty model string reads as NOT configured (inert, not an error)',
      unconfigured['configured'] is False, unconfigured)

disabled = instance.collect_llm_status({'llm': {'enabled': False, 'model': 'gpt-4o-mini'}})
check('a model set but enabled=False reads as NOT configured',
      disabled['configured'] is False, disabled)

os.environ['LLM_MODEL'] = 'env-model'
try:
    env_status = instance.collect_llm_status({'llm': {'enabled': False, 'model': ''}})
    check('LLM_MODEL env var wins over the datastore, same as get_llm_config',
          env_status == {'configured': True, 'source': 'env', 'model': 'env-model'}, env_status)
finally:
    del os.environ['LLM_MODEL']

# --- tags: the fields a generator needs, and the ones it must not miss ------

tags = instance.collect_tags(app)
check('every tag in the datastore is reported', len(tags) == 2, tags)
by_title = {t['title']: t for t in tags}
check('a real url_match_pattern is reported, not swallowed',
      by_title['exchange-rates']['url_match_pattern'] == 'tucambista.pe*', tags)
check('an empty pattern is reported as None, not an empty string a caller might skip on',
      by_title['manual-only']['url_match_pattern'] is None, tags)
check("a tag's own filters are surfaced -- these are what silently union into a watch",
      by_title['exchange-rates']['include_filters'] == ['.rate'], tags)

out = captured(instance.print_human, report)
check('the human report calls out that a pattern attaches WITHOUT being asked',
      'attaches without asking' in out, out)
check('a tag with filters shows them in the report',
      '.rate' in out, out)

# --- the bootstrap: a missing datastore aborts with a fix, not a traceback --

empty_dir = tempfile.mkdtemp(prefix='instance-no-datastore-')
try:
    instance.load_datastore(empty_dir)
    check('a missing datastore aborts', False, 'it returned normally')
except SystemExit as e:
    message = str(e)
    check('a missing datastore raises SystemExit, not a bare FileNotFoundError', True)
    check('and the message carries a fix line', 'fix:' in message, message)
except FileNotFoundError:
    check('a missing datastore raises SystemExit, not a bare FileNotFoundError', False)
finally:
    os.rmdir(empty_dir)

real_dir = tempfile.mkdtemp(prefix='instance-real-datastore-')
try:
    with open(os.path.join(real_dir, 'changedetection.json'), 'w', encoding='utf-8') as f:
        json.dump(FIXTURE, f)
    loaded = instance.load_datastore(real_dir)
    check('a real datastore file loads back the same watch count',
          len(loaded['watching']) == 2, loaded)
finally:
    os.remove(os.path.join(real_dir, 'changedetection.json'))
    os.rmdir(real_dir)

print()
print(f"{'FAILED' if failures else 'PASSED'} -- {len(failures)} failure(s)")
sys.exit(1 if failures else 0)

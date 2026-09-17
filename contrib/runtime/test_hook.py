"""The post-import hook, driven against DUMMY changedetectionio modules.

The real ones cannot be imported here -- this machine has no Flask and no
changedetectionio dependencies -- and that is fine, because what needs proving
is the hook's behaviour, not Flask's. A stand-in carrying the one attribute each
patch touches exercises every path.

TWO TARGETS NOW, imported at different moments, which is the reason the finder
counts what is left instead of standing down on its first hit. A finder that
retired after flask_app would leave the second patch permanently uninstalled,
and nothing in the running application would look wrong.

The last case is the one that matters most. A patch runs AFTER its module has
already executed successfully. If it were allowed to raise there, a mistake in a
cosmetic filter would stop the application from starting at all.
"""

import os
import shutil
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import sitecustomize  # noqa: E402  -- importing it installs the finder, as in the container

FAKE_APP = '''
class _Env:
    def __init__(self):
        self.filters = {'format_number_locale': 'ORIGINAL'}

class _App:
    def __init__(self):
        self.jinja_env = _Env()

app = _App()
EXECUTED = True
'''

FAKE_FETCHER = '''
class fetcher:
    def _run_sync(self, url=None, timeout=None, request_headers=None,
                  request_body=None, request_method=None, **kwargs):
        return 'ORIGINAL'

EXECUTED = True
'''

failures = []


def check(label, condition, detail=''):
    print(f"{'ok  ' if condition else 'FAIL'} {label}")
    if not condition:
        failures.append(label)
        if detail:
            print(f"     {detail}")


root = tempfile.mkdtemp(prefix='gid-hook-test-')
try:
    pkg = os.path.join(root, 'changedetectionio')
    fetchers = os.path.join(pkg, 'content_fetchers')
    os.makedirs(fetchers)
    open(os.path.join(pkg, '__init__.py'), 'w').write('')
    open(os.path.join(pkg, 'flask_app.py'), 'w').write(FAKE_APP)
    open(os.path.join(fetchers, '__init__.py'), 'w').write('')
    open(os.path.join(fetchers, 'requests.py'), 'w').write(FAKE_FETCHER)
    open(os.path.join(root, 'unrelated_module.py'), 'w').write('VALUE = 42\n')
    sys.path.insert(0, root)

    # 1 + 2: the finder is armed, and the patch lands after the module executed.
    check('the finder installed itself on import',
          any(isinstance(f, sitecustomize._PatchAfterImport) for f in sys.meta_path))

    import unrelated_module
    check('an unrelated import still works', unrelated_module.VALUE == 42)

    from changedetectionio import flask_app
    check('the target module executed normally', getattr(flask_app, 'EXECUTED', False))
    check('the filter was replaced',
          flask_app.app.jinja_env.filters['format_number_locale'] is sitecustomize.format_number_locale,
          f"got {flask_app.app.jinja_env.filters['format_number_locale']!r}")
    installed = flask_app.app.jinja_env.filters['format_number_locale']
    check('the replacement works through the module',
          callable(installed) and installed(3.3715) in ('3.3715', '3,3715'),
          f'not callable: {installed!r}' if not callable(installed) else '')

    # 3: one target down, one to go -- so it must still be armed.
    armed = [f for f in sys.meta_path if isinstance(f, sitecustomize._PatchAfterImport)]
    check('it stays installed while a second target is still unimported',
          len(armed) == 1 and 'changedetectionio.flask_app' not in armed[0].remaining,
          f'{[f.remaining for f in armed]}')

    # 4: the second patch, and only then does the finder retire.
    from changedetectionio.content_fetchers import requests as fake_fetchers
    check('the fetcher module executed normally', getattr(fake_fetchers, 'EXECUTED', False))
    check('and its fetch method was wrapped',
          getattr(fake_fetchers.fetcher._run_sync, '_maku_conditional', False),
          'the conditional-fetch patch did not reach it')
    check('the finder removed itself once EVERY target had fired',
          not any(isinstance(f, sitecustomize._PatchAfterImport) for f in sys.meta_path))

    # 5: a patch that throws must not take the import down with it.
    #
    # Purge the PACKAGE too, not just the submodule. `from changedetectionio
    # import flask_app` resolves the package attribute first, so dropping only
    # sys.modules['changedetectionio.flask_app'] hands back the module object
    # already imported above -- no import runs, and this case passes without
    # ever exercising the thing it names.
    for name in ('changedetectionio.flask_app', 'changedetectionio'):
        sys.modules.pop(name, None)

    def boom(module):
        raise RuntimeError('boom')

    # Armed with an explicit table rather than by monkeypatching the module:
    # PATCHES holds the function OBJECT, so replacing the name in the module
    # would leave the finder calling the original and this case would pass
    # without ever running a failing patch.
    try:
        sitecustomize._PatchAfterImport({'changedetectionio.flask_app': boom}).install()
        import importlib
        reimported = importlib.import_module('changedetectionio.flask_app')
        check('a raising patch does NOT break the import',
              getattr(reimported, 'EXECUTED', False) and reimported is not flask_app,
              'the module must have been imported afresh, not served from the package attribute')
        check('and the module is left usable, just unpatched',
              reimported.app.jinja_env.filters['format_number_locale'] == 'ORIGINAL')
    except Exception as e:
        check('a raising patch does NOT break the import', False, f'{type(e).__name__}: {e}')
finally:
    shutil.rmtree(root, ignore_errors=True)

print()
print(f"{'FAILED' if failures else 'PASSED'} -- {len(failures)} failure(s)")
sys.exit(1 if failures else 0)

"""Fork-local runtime patches, installed without editing a single upstream file.

WHY THIS FILE EXISTS AT ALL. The watchlist rounds every price to two decimals --
`locale.format_string("%.2f", ...)` in changedetectionio/flask_app.py -- so a
currency rate of 3.3715 is displayed as 3.37. The stored value and the
notification tokens keep full precision; only that one column loses it.

The obvious fix is a one-line edit to flask_app.py. This fork does not do that.
It patches exactly ONE upstream-owned file (the fork guard in containers.yml),
which is why `git merge master` fast-forwards cleanly every time upstream ships.
A second patched file is a merge conflict waiting on someone else's schedule,
and this is a cosmetic change -- nowhere near worth that.

HOW IT LOADS. Python imports a module named `sitecustomize` automatically during
`site` processing, before the interpreter runs anything else. Nothing imports it
by name and nothing has to know it is here; putting its directory on PYTHONPATH
is the whole installation. contrib/ is absent from the image, so the directory
arrives as a read-only mount that `app start` adds -- see Start-AppContainer in
contrib/lib/Podman.psm1. Remove the mount and the app is stock again.

WHY A POST-IMPORT HOOK RATHER THAN A DIRECT PATCH. There is nothing to patch
yet. This runs before changedetectionio exists in sys.modules, and flask_app
registers its filters on the Flask `app` object at its own import time. So the
patch has to wait for that module to finish executing, which is what the
meta-path finder below arranges: it lets the normal machinery build the spec,
wraps the loader it produced, and applies the patch after exec_module returns.

THIS FILE RUNS IN EVERY PYTHON PROCESS IN THE CONTAINER -- pip during the
entrypoint included. So it imports almost nothing at module level, does its work
lazily, and swallows its own failures. A cosmetic filter must never be the
reason the application does not start.
"""

import sys

TARGET = 'changedetectionio.flask_app'

MIN_DECIMALS = 2
MAX_DECIMALS = 6


def decimals_for(value):
    """How many decimal places this value actually carries, floored and capped.

    Decimal(str(value)) rather than the float: repr-shortest parsing is what
    keeps 3.3715 from arriving as 3.3715000000000002 and asking for 16 places.
    normalize() strips trailing zeros, so 1099.0 reports 0 and falls to the
    floor of 2 -- money still reads as money.
    """
    import decimal
    try:
        exponent = decimal.Decimal(str(value)).normalize().as_tuple().exponent
    except (ArithmeticError, ValueError, TypeError):
        return MIN_DECIMALS
    # NaN and Infinity report 'n'/'N'/'F' here instead of an int.
    if not isinstance(exponent, int):
        return MIN_DECIMALS
    return max(MIN_DECIMALS, min(MAX_DECIMALS, -exponent))


def format_number_locale(value):
    """Upstream's filter, minus the hardcoded two decimal places.

    Same name, same contract, same locale grouping. The only difference is that
    a value carrying more precision than money keeps it: 3.3715 stays 3.3715
    instead of becoming 3.37.
    """
    import locale
    if not isinstance(value, (int, float)) or isinstance(value, bool):
        return str(value)
    return locale.format_string('%%.%df' % decimals_for(value), value, grouping=True)


def apply_to(module):
    """Swap the filter on the live Jinja environment."""
    module.app.jinja_env.filters['format_number_locale'] = format_number_locale


class _PatchingLoader:
    """Delegates everything, then runs the patch once the module is populated."""

    def __init__(self, inner):
        self._inner = inner

    def create_module(self, spec):
        return self._inner.create_module(spec)

    def exec_module(self, module):
        self._inner.exec_module(module)
        try:
            apply_to(module)
        except Exception:
            # Deliberately swallowed. The import has already SUCCEEDED by this
            # point; letting a cosmetic patch raise here would turn a working
            # application into one that does not boot, over decimal places.
            pass

    def __getattr__(self, name):
        return getattr(self._inner, name)


class _PatchAfterImport:
    """Claims exactly one module name, and only to wrap whoever really loads it."""

    def find_spec(self, fullname, path=None, target=None):
        if fullname != TARGET:
            return None
        try:
            start = sys.meta_path.index(self) + 1
        except ValueError:
            return None
        for finder in sys.meta_path[start:]:
            find_spec = getattr(finder, 'find_spec', None)
            if find_spec is None:
                continue
            spec = find_spec(fullname, path, target)
            if spec is None or spec.loader is None:
                continue
            # Found the real loader. Stand down so a re-import costs nothing,
            # and hand back the same spec with a wrapped loader.
            self.uninstall()
            spec.loader = _PatchingLoader(spec.loader)
            return spec
        return None

    def install(self):
        sys.meta_path.insert(0, self)

    def uninstall(self):
        try:
            sys.meta_path.remove(self)
        except ValueError:
            pass


def install():
    if TARGET in sys.modules:
        apply_to(sys.modules[TARGET])
        return
    _PatchAfterImport().install()


try:
    install()
except Exception:
    pass

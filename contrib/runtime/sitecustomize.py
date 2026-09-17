"""Fork-local runtime patches, installed without editing a single upstream file.

TWO PATCHES LIVE HERE, and they are unrelated to each other:

  1. the watchlist's price column, which rounds away real precision -- below;
  2. conditional requests on the plain HTTP fetcher, so an unchanged page is not
     downloaded again -- maku_conditional_fetch.py, which explains itself.

Both are installed the same way and for the same reason: see HOW IT LOADS.

WHY THE FIRST ONE EXISTS AT ALL. The watchlist rounds every price to two decimals --
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


def apply_conditional_fetch(module):
    """Teach the plain-HTTP fetcher to ask "has it changed?" before downloading.

    Imported HERE rather than at the top of this file, which runs in every Python
    process in the container. Nothing is loaded until the module it patches is
    actually being imported, so pip and the entrypoint never pay for it.
    """
    import maku_conditional_fetch
    maku_conditional_fetch.install(module)


# Every patch this fork installs, by the module that has to exist first. A second
# entry is why the finder below counts what is left rather than standing down on
# its first hit -- the two targets are imported at different moments, and
# flask_app is usually first.
PATCHES = {
    'changedetectionio.flask_app': apply_to,
    'changedetectionio.content_fetchers.requests': apply_conditional_fetch,
}


class _PatchingLoader:
    """Delegates everything, then runs the patch once the module is populated."""

    def __init__(self, inner, patch):
        self._inner = inner
        self._patch = patch

    def create_module(self, spec):
        return self._inner.create_module(spec)

    def exec_module(self, module):
        self._inner.exec_module(module)
        try:
            self._patch(module)
        except Exception:
            # Deliberately swallowed. The import has already SUCCEEDED by this
            # point; letting one of these raise here would turn a working
            # application into one that does not boot, over decimal places or a
            # saved round trip.
            pass

    def __getattr__(self, name):
        return getattr(self._inner, name)


class _PatchAfterImport:
    """Claims a few module names, and only to wrap whoever really loads them."""

    def __init__(self, patches=None):
        # A copy, so firing one target cannot mutate the table the next process
        # reads -- and so a test can arm this with a target of its own.
        self.remaining = dict(patches if patches is not None else PATCHES)

    def find_spec(self, fullname, path=None, target=None):
        patch = self.remaining.get(fullname)
        if patch is None:
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
            # Found the real loader. Drop this target before handing the spec
            # back, so a re-import costs nothing, and stand down entirely once
            # every target has been claimed.
            self.remaining.pop(fullname, None)
            if not self.remaining:
                self.uninstall()
            spec.loader = _PatchingLoader(spec.loader, patch)
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
    pending = {}
    for name, patch in PATCHES.items():
        # Already imported -- there is no import left to hook, so patch it where
        # it stands. Each one is guarded separately: one patch failing must not
        # cost the others their installation.
        if name in sys.modules:
            try:
                patch(sys.modules[name])
            except Exception:
                pass
        else:
            pending[name] = patch
    if pending:
        _PatchAfterImport(pending).install()


try:
    install()
except Exception:
    pass

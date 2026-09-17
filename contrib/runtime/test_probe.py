"""The probe's own logic, on this machine, with no container and no bs4.

Only the parts that are genuinely ours are testable here -- the ld+json walker
and the bootstrap. Everything else in probe.py deliberately delegates to the
application's code, and a stub of that would prove nothing except that the stub
matches the stub.

The bootstrap case is the important one. It exists because the first version
reported "a Restock watch on this page would error rather than report a price"
when the real problem was that the probe could not import the app. So the test
asserts the failure is a SystemExit carrying a fix line, not an ImportError
traceback and not something that reads like a verdict on the page.
"""

import contextlib
import io
import os
import sys
import tempfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import probe  # noqa: E402

failures = []


def check(label, condition, detail=''):
    print(f"{'ok  ' if condition else 'FAIL'} {label}")
    if not condition:
        failures.append(label)
        if detail:
            print(f"     {detail}")


def captured(fn, *args):
    buffer = io.StringIO()
    with contextlib.redirect_stdout(buffer):
        fn(*args)
    return buffer.getvalue()


TUCAMBISTA = '''<html><head>
<script type="application/ld+json">
{"@context":"https://schema.org","@type":"MobileApplication","name":"TuCambista App",
 "offers":{"@type":"Offer","price":"3.3715","priceCurrency":"PEN"}}
</script>
<script type="application/ld+json">
{"@context":"https://schema.org","@type":"SoftwareApplication","name":"TuCambista",
 "offers":{"@type":"Offer","price":"3.3715","priceCurrency":"PEN"}}
</script>
</head><body>Compra: 3.348 Venta: 3.3715</body></html>'''

TWO_PRICES = '''<html><head>
<script type="application/ld+json">
{"@type":"Product","name":"A","offers":{"@type":"Offer","price":"10.00","priceCurrency":"PEN"}}
</script>
<script type="application/ld+json">
{"@type":"Product","name":"B","offers":{"@type":"Offer","price":"20.00","priceCurrency":"PEN"}}
</script>
</head><body></body></html>'''

BROKEN_JSON = '<html><script type="application/ld+json">{not json at all</script></html>'

# --- the ld+json walker -----------------------------------------------------

out = captured(probe.report_ldjson_offers, TUCAMBISTA)
check('it names the ENCLOSING schema type, not the useless "Offer"',
      'MobileApplication' in out and 'SoftwareApplication' in out, out)
check('it reports the price and currency', '3.3715' in out and 'PEN' in out, out)
check('it says the page publishes ONE distinct price',
      'one distinct price' in out, out)

out = captured(probe.report_ldjson_offers, TWO_PRICES)
check('two different prices -> that line is NOT printed',
      'one distinct price' not in out and '10.00' in out and '20.00' in out, out)

out = captured(probe.report_ldjson_offers, '<html><body>nothing here</body></html>')
check('no ld+json at all -> prints nothing, raises nothing', out.strip() == '', repr(out))

out = captured(probe.report_ldjson_offers, BROKEN_JSON)
check('unparseable ld+json is skipped, not fatal', out.strip() == '', repr(out))

# --- the bootstrap ----------------------------------------------------------

empty = tempfile.mkdtemp(prefix='probe-no-app-')
real_root, probe.APP_ROOT = probe.APP_ROOT, empty
try:
    probe.ensure_app_importable()
    check('a missing application aborts', False, 'it returned normally')
except SystemExit as e:
    message = str(e)
    check('a missing application raises SystemExit, not an ImportError traceback', True)
    check('and the message carries a fix line', 'fix:' in message, message)
    check('and it does NOT read like a verdict on the page',
          'page' not in message.lower() and 'watch on this' not in message.lower(),
          message)
except ImportError as e:
    check('a missing application raises SystemExit, not an ImportError traceback',
          False, f'got ImportError: {e}')
finally:
    probe.APP_ROOT = real_root
    sys.path[:] = [p for p in sys.path if p != empty]
    os.rmdir(empty)

print()
print(f"{'FAILED' if failures else 'PASSED'} -- {len(failures)} failure(s)")
sys.exit(1 if failures else 0)

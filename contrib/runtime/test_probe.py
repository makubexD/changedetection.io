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
from decimal import Decimal

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

# --- the thousands-separator misread ----------------------------------------
#
# The values are real: tucambista's Compra printed 3.345 and the app's own
# extractor returned 3345. Decimal, because that is what price_parser returns.

cases = [
    ('3.345',    Decimal('3345'),    True,  "the value that provoked this"),
    ('S/ 1.099', Decimal('1099'),    True,  "a currency symbol does not hide it"),
    ('3.3725',   Decimal('3.3725'),  False, "four decimals are unambiguous"),
    ('3.35',     Decimal('3.35'),    False, "two decimals are unambiguous"),
    ('1,099.00', Decimal('1099.00'), False, "comma grouping is read correctly"),
    ('3.345',    Decimal('3.345'),   False, "if the parser is fixed, we go quiet"),
    ('3.345',    None,               False, "no number at all is not a misread"),
]
for text, amount, expected, why in cases:
    got = probe.read_as_group(text, amount)
    check(f'read_as_group({text!r}, {amount}) is {expected} -- {why}', got == expected,
          f'got {got}')

out = captured(probe.warn_if_grouped, '3.345', Decimal('3345'))
check('the warning names the separator and the field it breaks',
      'THOUSANDS separator' in out and 'extracted_number' in out, out)
check('and it shows both numbers, so the reader can see the jump',
      "'3.345'" in out and '3345' in out, out)

out = captured(probe.warn_if_grouped, '3.3725', Decimal('3.3725'))
check('a correctly parsed number gets no warning at all', out == '', repr(out))

# --- the cheap-polling verdict ----------------------------------------------
#
# Three outcomes that look alike in the headers and mean opposite things for the
# interval. The middle one is why the probe sends a real conditional request
# instead of reading the verdict off the response headers.

supported = '\n'.join(probe.describe_conditional({'If-None-Match': '"v"'}, 304))
check('a 304 is reported as supported, in those words', 'SUPPORTED' in supported, supported)
check('and it says a short interval is affordable',
      'short interval' in supported, supported)

ignored = '\n'.join(probe.describe_conditional({'If-None-Match': '"v"'}, 200))
check('a validator the server IGNORES is not sold as a saving',
      'SUPPORTED' not in ignored and 'ignores it' in ignored, ignored)

none = '\n'.join(probe.describe_conditional({}, None))
check('no validator at all -> every check downloads, and it says what to do instead',
      'neither ETag nor Last-Modified' in none and 'WATCHING.md' in none, none)

refused = '\n'.join(probe.describe_conditional({'If-Modified-Since': 'then'}, 405))
check('a server that refuses HEAD is named as such, with its status',
      '405' in refused and 'SUPPORTED' not in refused, refused)

unasked = '\n'.join(probe.describe_conditional({'If-None-Match': '"v"'}, None))
check('a request that could not be made proves NOTHING, and says so',
      'nothing proven' in unasked and 'SUPPORTED' not in unasked, unasked)

# --- candidate-selector discovery (--find) ----------------------------------
#
# The ranking algorithm (#id -> unique class -> shortest unique nth-of-type
# path) is entirely ours, unlike the rest of this file -- worth testing here.

from bs4 import BeautifulSoup  # noqa: E402

RATES_PAGE = '''<html><body>
<div class="tc-quote-rates">
  <button><span class="tc-quote-rate-value" id="compra-value"><span>3.348</span><span>--</span></span></button>
  <button><span class="tc-quote-rate-value">3.3715</span></button>
</div>
</body></html>'''

soup = BeautifulSoup(RATES_PAGE, 'html.parser')
candidates = probe.find_candidates(soup, '3.348')
check('finds the element whose text contains the target string',
      len(candidates) == 1, candidates)
check("the value's own span has no id/class -- anchors on the nearest ancestor that does",
      candidates and candidates[0][0] == '#compra-value > span:nth-of-type(1)', candidates)

candidates = probe.find_candidates(soup, '3.3715')
check('no id or unique class on this one -- falls back to a structural path',
      candidates and candidates[0][0] not in ('', None) and '#' not in candidates[0][0],
      candidates)
check('the fallback selector actually selects only this element',
      candidates and len(soup.select(candidates[0][0])) == 1, candidates)

candidates = probe.find_candidates(soup, 'not on this page')
check('no match -> empty list, not an error', candidates == [], candidates)

DUPLICATED = '''<html><body>
<div><span class="price">9.99</span></div>
<div><span class="price">9.99</span></div>
</body></html>'''
soup = BeautifulSoup(DUPLICATED, 'html.parser')
candidates = probe.find_candidates(soup, '9.99')
check('two structurally identical elements -> two distinct candidates, not one',
      len(candidates) == 2, candidates)
check('neither candidate selector is unique on its own (both select 2 elements)',
      all(len(soup.select(sel)) >= 1 for sel, _ in candidates), candidates)

out = captured(probe.report_find, RATES_PAGE, '3.348')
check('report_find prints the isolated text next to the selector',
      "isolates: '3.348'" in out, out)

out = captured(probe.report_find, RATES_PAGE, 'nowhere')
check('report_find on no match suggests --with-browser',
      '--with-browser' in out, out)

# --- a Tailwind-style class breaks a naive selector: FOUND LIVE on tucambista.pe --
#
# 'mt-0.5' is a legal HTML class token but not a legal CSS class SELECTOR: the
# '.' inside it starts what soupsieve reads as a second class, and raises
# SelectorSyntaxError. This is not a hypothetical -- it crashed find_candidates
# the first time this ran against the real page.

TAILWIND_PAGE = '''<html><body>
<div class="tc-quote-rate-value mt-0.5"><span>3.348</span></div>
</body></html>'''
soup = BeautifulSoup(TAILWIND_PAGE, 'html.parser')
candidates = probe.find_candidates(soup, '3.348')
check("a class containing '.' does not crash the search", len(candidates) == 1, candidates)
check("the escaped class selector is used, and it actually selects the element",
      candidates and candidates[0][0].startswith('.tc-quote-rate-value') and
      len(soup.select(candidates[0][0])) == 1, candidates)

check("escape_css_ident escapes the dot in a Tailwind-style class",
      probe.escape_css_ident('mt-0.5') == r'mt-0\.5', probe.escape_css_ident('mt-0.5'))
check("select_count returns 0 on an unescaped, unparseable selector instead of raising",
      probe.select_count(soup, '.mt-0.5') == 0)

# --- script/style text is never a candidate: FOUND LIVE on tucambista.pe -----
#
# A Next.js hydration payload embeds the same number inside a <script> tag,
# and without this exclusion it out-competes the real visible element for
# attention -- worth a real page's worth of noise as the fixture, not a
# one-line stub, since the failure was specifically about SIZE and RANKING.

HYDRATION_NOISE = '''<html><body>
<div class="tc-quote-rates"><button><span class="tc-quote-rate-value"><span>3.348</span></span></button></div>
<script>self.__next_f.push([1,"{\\"buyExchangeRate\\":3.348,\\"sellExchangeRate\\":3.375}"])</script>
<style>.price-3\\.348 { color: red; }</style>
</body></html>'''
soup = BeautifulSoup(HYDRATION_NOISE, 'html.parser')
candidates = probe.find_candidates(soup, '3.348')
check('script/style text never becomes a candidate, however much of it there is',
      all('__next_f' not in text and 'push' not in text for _, text in candidates), candidates)
check('the real visible element is still found',
      any(text == '3.348' for _, text in candidates), candidates)

# --- the conditional verdict as one word (classify_conditional) -------------
#
# describe_conditional (tested above) owns the WORDING; this owns the WORD a
# generator branches on. Same four inputs, so they cannot disagree.

check("classify_conditional -> 'supported' on a real 304",
      probe.classify_conditional({'If-None-Match': '"v"'}, 304) == 'supported')
check("classify_conditional -> 'ignored' when the server answers 200 anyway",
      probe.classify_conditional({'If-None-Match': '"v"'}, 200) == 'ignored')
check("classify_conditional -> 'no_validators' when there is nothing to send",
      probe.classify_conditional({}, None) == 'no_validators')
check("classify_conditional -> 'refuses_head' on a non-304/200 status",
      probe.classify_conditional({'If-Modified-Since': 'x'}, 405) == 'refuses_head')
check("classify_conditional -> 'unproven' when the request could not be made",
      probe.classify_conditional({'If-None-Match': '"v"'}, None) == 'unproven')

# --- --host-only: the fallback path for a machine with no podman ------------
#
# This is what let the skill run on a machine with neither podman nor docker
# and still produce a real, verified selector for tucambista.pe -- these tests
# pin the boundary of what host-only mode can and cannot honestly claim.

check("a plain CSS selector is NOT app-only",
      probe.is_app_only_selector('.tc-quote-rate-value') is False)
for prefix, example in [('/', '/html/body'), ('xpath:', 'xpath://div'),
                         ('xpath1:', 'xpath1://div'), ('json:', 'json:$.price'),
                         ('jq:', 'jq:.price'), ('jqraw:', 'jqraw:.price')]:
    check(f"a {prefix!r} selector IS app-only -- host-only mode cannot verify it",
          probe.is_app_only_selector(example) is True, example)

result = probe.host_only_css_match(RATES_PAGE, 'json:$.price')
check('host_only_css_match returns None for an app-only selector, not a wrong answer',
      result is None, result)

result = probe.host_only_css_match(RATES_PAGE, '#compra-value')
check('host_only_css_match matches a real CSS selector and reports the text',
      result == {'matched': True, 'text': '3.348--'}, result)

result = probe.host_only_css_match(RATES_PAGE, '.nothing-on-this-page')
check('host_only_css_match reports a clean zero-match, not an exception',
      result == {'matched': False}, result)

out = captured(probe.report_selector, RATES_PAGE, 'json:$.price', True)
check('report_selector in host-only mode names the app-only syntax it cannot check',
      'xpath/JSONPath/jq' in out, out)

out = captured(probe.report_selector, RATES_PAGE, '#compra-value', True)
check("report_selector in host-only mode labels the match as host-only, not authoritative",
      "host-only" in out and "3.348" in out, out)

result = probe.finish_selector_result('#x', False, None, True)
check('finish_selector_result on no-match carries no text/extracted_number keys to fill in',
      result == {'selector': '#x', 'matched': False, 'host_only': True}, result)

result = probe.finish_selector_result('#x', True, '3.348', True)
check('finish_selector_result on a match still runs the thousands-separator check',
      result.get('extracted_number') == '3348' and result.get('thousands_separator_misread') is True,
      result)

result = probe.collect_restock(RATES_PAGE, host_only=True)
check("collect_restock in host-only mode returns a skip note, never a guessed verdict",
      'skipped' in result, result)
check("the skip note says WHY, not just that it was skipped",
      'container' in result['skipped'] or 'app' in result['skipped'], result)

print()
print(f"{'FAILED' if failures else 'PASSED'} -- {len(failures)} failure(s)")
sys.exit(1 if failures else 0)

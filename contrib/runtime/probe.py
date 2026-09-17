"""Answer one question about a URL: what would a watch actually SEE here?

RUNS INSIDE THE RUNNING CONTAINER, on purpose. Every answer below comes from the
application's own code -- the same filter function, the same metadata extractor,
the same price parser the Conditions tab uses. A re-implementation on the host
would be a second opinion that can drift from the first, and the whole value of
this tool is that it cannot disagree with the app.

IT PRINTS FOUR THINGS, ALWAYS, even when they are empty. Each one is a distinct
way a watch goes wrong, and the empty case is the diagnosis far more often than
the populated one:

  1. which fetcher got the bytes, and what came back
  2. what 'Restock & Price' mode would find -- INDEPENDENTLY of any filter
  3. what the filter matched, and the number a Condition would extract from it
  4. whether this URL can be polled cheaply, which is what decides the interval

Point 2 is the one that is not obvious from the UI. The restock processor reads
the whole page's structured data and never looks at the watch's filter, so a page
publishing one price reports that price on every watch pointed at it, whatever
selector is set. Seeing that stated next to the filter's own result is what turns
a confusing afternoon into a one-line answer.

THE ONE RULE THIS FILE MUST NOT BREAK. An answer about OUR OWN ENVIRONMENT is
never printed in the shape of an answer about the page. The first version did
exactly that: a single `except Exception` wrapped both the import of the
extractor and the call to it, so when the import failed -- our bug, nothing to do
with the site -- it printed "a Restock watch on this page would error rather than
report a price". That was false, and it was the very failure this tool exists to
prevent. Environment problems now abort with a fix line; only genuine facts about
the fetched content are reported as such.
"""

import argparse
import json
import os
import re
import sys
import time

# Before any application import, which is what pulls in loguru. loguru fixes its
# default handler's level from this variable the moment it is imported, and the
# application's default is DEBUG -- three of its lines used to land in the middle
# of this report, including "Using Playwright library as fetcher" on a run that
# fetched over plain HTTP, which reads as a contradiction of our own first line.
# setdefault, so LOGURU_LEVEL=DEBUG still works when the probe is the thing being
# debugged.
os.environ.setdefault('LOGURU_LEVEL', 'WARNING')

# The application is importable inside the container only because its entry
# script lives here, which makes /app become sys.path[0]:
#   Dockerfile -> COPY changedetectionio /app/changedetectionio
#                 WORKDIR /app
#                 CMD ["python", "./changedetection.py", ...]
# ENV PYTHONPATH=/usr/local carries the DEPENDENCIES, not the app. This script
# runs from /maku-runtime, so sys.path[0] is that directory instead and the app
# is nowhere on the path. The cwd does not help: for a script Python uses the
# script's own directory, never the working directory.
APP_ROOT = '/app'


def ensure_app_importable():
    """Put the application on the path, or say plainly that we are in the wrong place.

    Self-contained on purpose. Making the caller pass the right -w or
    -e PYTHONPATH would push this knowledge into every invocation, and get it
    wrong the first time someone runs the script by hand.
    """
    if APP_ROOT not in sys.path:
        sys.path.insert(0, APP_ROOT)
    try:
        import changedetectionio  # noqa: F401
    except ImportError as e:
        raise SystemExit(
            "Cannot import the application from {}: {}\n"
            "This probe reuses the app's OWN extractor, so it has to run inside the\n"
            "changedetection container.\n"
            "  fix: .\\contrib\\maku.ps1 site probe -Url <url>".format(APP_ROOT, e))


USER_AGENT = ('Mozilla/5.0 (Windows NT 10.0; Win64; x64) '
              'AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Safari/537.36')


def fetch(url, timeout, with_browser):
    """Return (content, status, seconds, fetcher_label, response_headers).

    The headers come back because the cheap-polling question below is answered
    from them, and re-fetching the page to read them would be a second opinion on
    a page that may have changed in between. A browser fetch has none to give.
    """
    started = time.time()
    if with_browser:
        content, status = _fetch_with_browser(url, timeout)
        return content, status, time.time() - started, 'Chrome (Playwright)', None
    import requests
    response = requests.get(url, headers={'User-Agent': USER_AGENT}, timeout=timeout)
    return (response.text, response.status_code, time.time() - started,
            'plain HTTP (no browser)', response.headers)


def _fetch_with_browser(url, timeout):
    """Drive the app's own Playwright fetcher, so -WithBrowser means what the watch means."""
    import asyncio
    import os
    from changedetectionio.content_fetchers.playwright import fetcher as playwright_fetcher
    driver_url = os.getenv('PLAYWRIGHT_DRIVER_URL')
    if not driver_url:
        raise SystemExit('PLAYWRIGHT_DRIVER_URL is not set in this container -- '
                         'start the app with -WithBrowser, or drop -WithBrowser here.')
    f = playwright_fetcher(proxy_override=None, custom_browser_connection_url=driver_url)
    # fetch_favicon=False: the watch fetches one, this does not need to, and it is
    # a second network round trip on every probe.
    asyncio.run(f.run(url=url, timeout=timeout, request_headers={}, request_body=None,
                      request_method='GET', ignore_status_codes=True, fetch_favicon=False))
    return f.content, f.get_last_status_code()


def report_structured_prices(content):
    """What the Restock & Price processor would extract -- filter or no filter."""
    # Imported OUTSIDE the try below. ensure_app_importable() has already proved
    # the app is reachable, so a failure here is a real problem with the
    # application and must not be reported as a property of the page.
    from changedetectionio.processors.restock_diff.processor import get_itemprop_availability

    print('Restock & Price mode would find:')
    try:
        restock = get_itemprop_availability(content)
    except Exception as e:
        # Now this claim is true: the extractor ran against THIS content and
        # raised, which is exactly what a watch would do.
        print(f'  extraction raised {type(e).__name__}: {e}')
        print('  -> a Restock watch on this page would error rather than report a price.')
        return

    price = restock.get('price')
    if price is None:
        print('  nothing -- no price in any ld+json, microdata or OpenGraph block.')
        print('  -> a Restock watch here shows the red "No information" badge. Rechecking')
        print('     cannot change that. Use a text watch with a filter instead.')
        return

    print(f'  price {price} {restock.get("currency") or ""}'.rstrip())
    if restock.get('availability') is not None:
        print(f'  availability {restock.get("availability")}')
    print(f'  -> it would report {price} on ANY filter. The restock processor reads the')
    print('     whole page, never the watch\'s filter.')


def report_ldjson_offers(content):
    """Every published offer, so "there is only one price here" is visible, not asserted."""
    blocks = re.findall(r'<script[^>]*application/ld\+json[^>]*>(.*?)</script>', content, re.S)
    offers = []

    def walk(node, enclosing):
        if isinstance(node, dict):
            own = node.get('@type', enclosing)
            if 'price' in node:
                # Report the ENCLOSING type, not this node's own. Every one of
                # these is an "Offer", which tells you nothing; "a
                # MobileApplication's offer" tells you the page is advertising an
                # app and the price you are reading is not a product's.
                offers.append((enclosing, node.get('price'), node.get('priceCurrency', '')))
            for value in node.values():
                walk(value, own)
        elif isinstance(node, list):
            for item in node:
                walk(item, enclosing)

    for block in blocks:
        try:
            walk(json.loads(block), '?')
        except ValueError:
            continue
    if offers:
        print(f'  published offers in {len(blocks)} ld+json block(s):')
        for kind, price, currency in offers:
            print(f'    offer on {kind:<22} price {price} {currency}'.rstrip())
        if len({(p, c) for _, p, c in offers}) == 1 and len(offers) > 1:
            print('    (one distinct price -- every watch on this URL reports it)')


def read_as_group(text, amount):
    """Did the parser turn '3.345' into 3345 -- reading the dot as a thousands separator?

    A COMPARISON AGAINST WHAT THE PARSER ACTUALLY RETURNED, never a restatement
    of its rules. price_parser's handling of a dot before exactly three digits is
    its business and may change; this asks only whether the digits it produced
    are the page's digits with the separator dropped. If the library ever starts
    reading these as decimals, this stops firing instead of becoming wrong.
    """
    match = re.fullmatch(r'\D*(\d{1,3})\.(\d{3})\D*', (text or '').strip())
    if not match or amount is None:
        return False
    parsed = str(amount)
    if '.' in parsed:
        parsed = parsed.rstrip('0').rstrip('.')
    return parsed.lstrip('0') == ''.join(match.groups()).lstrip('0')


def warn_if_grouped(text, amount):
    """The number is right on screen and wrong in every Condition. Say so, here."""
    if not read_as_group(text, amount):
        return
    print("  WARNING: the '.' was read as a THOUSANDS separator, not a decimal point.")
    print(f"    {text.strip()!r} became {amount}. A Condition on \"extracted_number\" compares")
    print('    THAT, not the number on the page -- the app builds the field with this same')
    print('    parser (changedetectionio/conditions/default_plugin.py). So a rule like')
    print('    "extracted_number < 3.40" can never fire, and nothing in the UI looks wrong.')
    print('    It is not even stable: the same watch extracts 3.35 on a day the value')
    print('    prints with two decimals instead of three.')
    print('    -> here, alert on the change itself rather than on a numeric threshold.')
    print('       contrib/podman/SITE-NOTES.md#tucambistape')


def report_selector(content, selector):
    print()
    if not selector:
        print('No -Selector given, so nothing to test. Pass one to see exactly what a')
        print('watch\'s "CSS/JSONPath/JQ/XPath Filter" would keep.')
        return
    from changedetectionio import html_tools   # proved importable at start-up
    print(f'Your selector: {selector}')
    try:
        html_block = html_tools.include_filters(include_filters=selector, html_content=content)
    except Exception as e:
        print(f'  the selector is not valid: {type(e).__name__}: {e}')
        return
    if not html_block.strip():
        print('  matched 0 elements. The watch would have NOTHING to diff, and would report')
        print('  "Got HTML content but no text found" or an empty change.')
        print('  If the page builds this element in JavaScript, retry with -WithBrowser.')
        return

    text = html_tools.html_to_text(html_block).strip()
    print(f'  matched, text: {text!r}')
    report_extracted_number(text)


def report_extracted_number(text):
    """The number a Condition would compare -- and whether it is the one on screen."""
    try:
        from price_parser import Price
    except ImportError:
        return          # running outside the container; the matched text still stands
    amount = Price.fromstring(text).amount
    if amount is None:
        print('  extracted_number -> nothing (a Condition on this would never fire)')
        return
    print(f'  extracted_number -> {amount}')
    warn_if_grouped(text, amount)


def describe_conditional(validators, head_status):
    """The cheap-polling verdict, as lines, from facts already collected.

    Split out from the requests below because this is the part with an opinion in
    it, and an opinion is worth testing. The three outcomes are genuinely
    different advice, and only the first one makes a short interval affordable.
    """
    if not validators:
        return ['  the server sends neither ETag nor Last-Modified.',
                '  -> every check downloads the whole page. Keep the interval long, or',
                '     point the watch at something smaller -- see "A cheaper URL" in',
                '     contrib/podman/WATCHING.md.']
    named = ' and '.join(sorted(validators))
    if head_status == 304:
        return [f'  {named} -- and a conditional request came back 304 Not Modified.',
                '  -> SUPPORTED. This fork re-uses the page it already has instead of',
                '     downloading it again, so an unchanged page costs a reply with no',
                '     body. A short interval is affordable here.']
    if head_status == 200:
        return [f'  {named} -- but a conditional request came back 200, not 304.',
                '  -> the server advertises a validator and then ignores it. Every check',
                '     downloads the whole page; treat this as the no-validator case.']
    if head_status is None:
        return [f'  {named} -- but the conditional request could not be made at all.',
                '  -> nothing proven either way. Re-run; if it persists, assume every',
                '     check downloads the page.']
    return [f'  {named} -- but a conditional HEAD answered {head_status}.',
            '  -> this server does not answer HEAD requests, which is how the saving is',
            '     collected. Every check downloads the whole page.']


def report_conditional_support(url, timeout, response_headers):
    """Can this URL be polled cheaply, and therefore often?

    THE SAME RULE THE PATCH USES, imported from it rather than restated, so this
    cannot advertise a saving the runtime patch would not actually take.
    """
    print()
    print('Cheap polling (conditional requests):')
    try:
        from maku_conditional_fetch import pick_validators
    except ImportError:
        print('  cannot answer -- maku_conditional_fetch is not on the path, so this is')
        print('  running outside the container. Use: .\\contrib\\maku.ps1 site probe')
        return

    headers = response_headers
    if headers is None:
        # A browser fetch gave us no headers. The saving only ever applies to the
        # plain fetcher anyway, so ask plain HTTP directly and say so.
        print('  (asked over plain HTTP -- a browser fetch runs JavaScript and can never')
        print('   be answered from a cache, whatever the server sends)')
        headers = _plain_headers(url, timeout)

    validators = pick_validators(headers)
    for line in describe_conditional(validators, _conditional_head(url, timeout, validators)):
        print(line)


def _plain_headers(url, timeout):
    import requests
    try:
        return requests.get(url, headers={'User-Agent': USER_AGENT}, timeout=timeout).headers
    except Exception:
        return {}


def _conditional_head(url, timeout, validators):
    """The status a real conditional request gets, or None when it could not be sent.

    ASKED, NOT ASSUMED. Plenty of servers emit an ETag and then ignore it, and a
    verdict read off the response headers alone would call those sites cheap and
    be wrong on every check afterwards.
    """
    if not validators:
        return None
    import requests
    headers = {'User-Agent': USER_AGENT}
    headers.update(validators)
    try:
        return requests.head(url, headers=headers, timeout=timeout,
                             allow_redirects=False).status_code
    except Exception:
        return None


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--url', required=True)
    parser.add_argument('--selector', default='')
    parser.add_argument('--timeout', type=int, default=30)
    parser.add_argument('--with-browser', action='store_true')
    args = parser.parse_args()

    ensure_app_importable()

    try:
        content, status, seconds, fetcher, headers = fetch(args.url, args.timeout, args.with_browser)
    except Exception as e:
        print(f'Fetch failed: {type(e).__name__}: {e}')
        print('A watch on this URL would fail the same way.')
        return 1

    print(f'Status     {status} in {seconds:.1f}s, {len(content):,} bytes   ({fetcher})')
    print()
    report_structured_prices(content)
    report_ldjson_offers(content)
    report_selector(content, args.selector)
    report_conditional_support(args.url, args.timeout, headers)
    return 0


if __name__ == '__main__':
    sys.exit(main())

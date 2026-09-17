"""The conditional-fetch patch, with no network and no application.

Everything that decides anything here is a pure function over headers and
arguments, so the interesting cases are all reachable on this machine: which
validators go back to the server, which requests are eligible at all, what is
refused entry to the cache, and what the wrapper does with each of the three
answers a revalidation can give.

THE CASE THAT MATTERS MOST is the last group. A patch that made an unchanged page
cheap but a HEAD-hostile server EXPENSIVE would be a regression sold as an
optimisation, so "the server could not answer" must be remembered and never
retried. That is asserted by counting calls, not by reading the cache.
"""

import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import maku_conditional_fetch as cf  # noqa: E402

failures = []


def check(label, condition, detail=''):
    print(f"{'ok  ' if condition else 'FAIL'} {label}")
    if not condition:
        failures.append(label)
        if detail:
            print(f"     {detail}")


# --- what goes back to the server -------------------------------------------

check('an ETag becomes If-None-Match',
      cf.pick_validators({'etag': '"abc"'}) == {'If-None-Match': '"abc"'})
check('a weak ETag is still sent -- it promises semantic equivalence',
      cf.pick_validators({'etag': 'W/"abc"'}) == {'If-None-Match': 'W/"abc"'})
check('Last-Modified becomes If-Modified-Since',
      cf.pick_validators({'last-modified': 'Wed, 17 Sep 2026 10:00:00 GMT'})
      == {'If-Modified-Since': 'Wed, 17 Sep 2026 10:00:00 GMT'})
both = cf.pick_validators({'etag': '"abc"', 'last-modified': 'Wed, 17 Sep 2026 10:00:00 GMT'})
check('both are sent when both exist', len(both) == 2, f'{both}')
check('no validator -> nothing to send', cf.pick_validators({'server': 'nginx'}) == {})
check('an empty ETag is not a validator', cf.pick_validators({'etag': '   '}) == {})
check('headers of None do not raise', cf.pick_validators(None) == {})

# --- which requests are eligible --------------------------------------------

check('a plain GET is eligible', cf.can_revalidate('GET', None, {}))
check('so is a request that never named a method', cf.can_revalidate(None, None, None))
check('a POST is not', not cf.can_revalidate('POST', None, {}))
check('a GET carrying a body is not', not cf.can_revalidate('GET', 'a=1', {}))
check("a caller's own If-None-Match is not overruled",
      not cf.can_revalidate('GET', None, {'If-None-Match': '"theirs"'}))
check('...and that test is case-insensitive, as HTTP headers are',
      not cf.can_revalidate('GET', None, {'if-modified-since': 'whenever'}))

# --- what is allowed into the cache -----------------------------------------

check('no validator -> not cacheable, however small',
      cf.build_entry('hi', b'hi', {'server': 'nginx'}) is None)
big = b'x' * (cf.MAX_BODY_BYTES + 1)
check('a body over the ceiling -> not cacheable',
      cf.build_entry('x', big, {'etag': '"v"'}) is None)
entry = cf.build_entry('hi', b'hi', {'etag': '"v"'})
check('a small validated body -> cacheable, with the headers kept',
      entry and entry['validators'] == {'If-None-Match': '"v"'} and entry['raw_content'] == b'hi',
      f'{entry}')

# --- the cache itself --------------------------------------------------------

cf.reset()
key = cf.cache_key('uuid-1', 'https://example.com/')
check('the key separates watches on one URL',
      key != cf.cache_key('uuid-2', 'https://example.com/'))
check('and separates URLs within one watch',
      key != cf.cache_key('uuid-1', 'https://example.com/other'))
check('and separates one set of request headers from another -- a session cookie',
      cf.cache_key('', 'https://example.com/cart', {'Cookie': 'session=a'})
      != cf.cache_key('', 'https://example.com/cart', {'Cookie': 'session=b'}))
check('while the same headers in a different order are the same key',
      cf.cache_key('u', 'https://example.com/', {'A': '1', 'B': '2'})
      == cf.cache_key('u', 'https://example.com/', {'B': '2', 'A': '1'}))
cf.remember(key, entry)
check('what was remembered is recalled', cf.recall(key) is entry)
cf.forget(key)
check('and forgetting it leaves nothing', cf.recall(key) is None)

cf.reset()
for i in range(cf.MAX_ENTRIES + 5):
    cf.remember(cf.cache_key('u', f'https://example.com/{i}'), entry)
check('the cache cannot grow past its ceiling',
      len(cf._cache) == cf.MAX_ENTRIES, f'{len(cf._cache)} entries')
check('and it is the OLDEST that was dropped',
      cf.recall(cf.cache_key('u', 'https://example.com/0')) is None
      and cf.recall(cf.cache_key('u', f'https://example.com/{cf.MAX_ENTRIES + 4}')) is not None)

# --- the switch --------------------------------------------------------------

check('absent means on', cf.is_enabled({}))
check("'0' means off", not cf.is_enabled({cf.ENV_SWITCH: '0'}))
check("'false' means off", not cf.is_enabled({cf.ENV_SWITCH: 'False'}))
check("'1' means on", cf.is_enabled({cf.ENV_SWITCH: '1'}))

# --- the wrapper, driven through a fake fetcher ------------------------------


class FakeModule:
    pass


class FakeFetcher:
    """Only what the wrapper reads: the attributes the real one sets."""

    etag = '"v1"'

    def __init__(self):
        self.calls = 0

    def _run_sync(self, url=None, timeout=None, request_headers=None,
                  request_body=None, request_method=None, **kwargs):
        self.calls += 1
        self.content = f'BODY {self.calls}'
        self.raw_content = f'BODY {self.calls}'.encode()
        self.headers = {'etag': self.etag} if self.etag else {'server': 'nginx'}
        self.status_code = 200


module = FakeModule()
module.fetcher = FakeFetcher
cf.install(module)
check('installing twice does not double-wrap',
      (cf.install(module), getattr(FakeFetcher._run_sync, '_maku_conditional', False))[1])

answers = []
calls = []


def fake_revalidate(self, url, timeout, request_headers, validators):
    calls.append((url, dict(validators)))
    return answers.pop(0)


cf._revalidate = fake_revalidate

cf.reset()
f = FakeFetcher()
f._run_sync(url='https://example.com/a', timeout=5, request_method='GET')
check('the first check fetches for real', f.calls == 1)
check('and nothing was revalidated -- there was nothing to revalidate yet', calls == [])

answers[:] = [304]
f._run_sync(url='https://example.com/a', timeout=5, request_method='GET')
check('a 304 does NOT fetch again', f.calls == 1, f'{f.calls} fetches')
check('and the fetcher still holds the previous body', f.content == 'BODY 1', f.content)
check('offering the ETag we were given', calls[-1][1] == {'If-None-Match': '"v1"'}, f'{calls[-1]}')
check('and the status reads 200, as it would have on a real fetch', f.status_code == 200)

answers[:] = [200]
f._run_sync(url='https://example.com/a', timeout=5, request_method='GET')
check('a 200 means it changed -> fetch for real', f.calls == 2, f'{f.calls} fetches')
check('and the new body is the one in hand', f.content == 'BODY 2', f.content)

answers[:] = [None]
before = len(calls)
f._run_sync(url='https://example.com/a', timeout=5, request_method='GET')
check('a server that cannot answer still gets a real fetch', f.calls == 3)
f._run_sync(url='https://example.com/a', timeout=5, request_method='GET')
check('...and is never asked again -- otherwise this patch costs MORE than stock',
      len(calls) == before + 1, f'{len(calls) - before} revalidations after the failure')
check('every check still returns the page', f.calls == 4)

# A response with no validator can never be revalidated, so it must never be
# cached -- and the proof is that no revalidation is ever attempted for it.
cf.reset()
calls.clear()
plain = FakeFetcher()
plain.etag = None
plain._run_sync(url='https://example.com/b', timeout=5, request_method='GET')
plain._run_sync(url='https://example.com/b', timeout=5, request_method='GET')
check('a page with no ETag or Last-Modified is fetched every time',
      plain.calls == 2 and calls == [], f'{plain.calls} fetches, {len(calls)} revalidations')

# The switch, end to end.
cf.reset()
calls.clear()
os.environ[cf.ENV_SWITCH] = '0'
try:
    off = FakeFetcher()
    off._run_sync(url='https://example.com/c', timeout=5, request_method='GET')
    off._run_sync(url='https://example.com/c', timeout=5, request_method='GET')
    check('switched off, it is exactly stock: two checks, two fetches, no cache',
          off.calls == 2 and calls == [] and not cf._cache,
          f'{off.calls} fetches, {len(calls)} revalidations, {len(cf._cache)} cached')
finally:
    os.environ.pop(cf.ENV_SWITCH, None)

# A POST is never eligible, so it is never cached either.
cf.reset()
calls.clear()
post = FakeFetcher()
post._run_sync(url='https://example.com/d', timeout=5, request_method='POST', request_body='a=1')
post._run_sync(url='https://example.com/d', timeout=5, request_method='POST', request_body='a=1')
check('a POST is fetched every time and never cached',
      post.calls == 2 and calls == [] and not cf._cache)

print()
print(f"{'FAILED' if failures else 'PASSED'} -- {len(failures)} failure(s)")
sys.exit(1 if failures else 0)

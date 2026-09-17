"""Ask the server "has it changed?" before downloading the page again.

WHY. changedetection.io is a poller with no push side, and it never sends a
conditional request -- there is no If-None-Match or If-Modified-Since anywhere in
changedetectionio/content_fetchers/. So every check downloads the whole page,
whether or not it moved, and the check interval is therefore a straight trade
between freshness and how hard you hammer a site you do not own.

This removes that trade wherever the server supports it. A cached ETag or
Last-Modified is offered back on the next check; a 304 means the bytes we already
have are still current, and the app is handed those bytes instead of new ones. A
five-minute interval then costs a response with no body at all.

WHAT IT DOES NOT DO. It does not invent a "nothing changed" path through the
application. On a 304 the fetcher is left holding exactly the content, headers
and status it held after the last real 200, so filters, hashing, history and
notifications all run precisely as they do today and reach the same conclusion by
the same route. The only thing that did not happen is the download. That is the
entire behavioural claim, and it is why this cannot produce a change the app
would not otherwise have produced, or hide one it would.

ONLY THE PLAIN HTTP FETCHER. A browser fetch runs JavaScript and cannot be
answered from a cache, so Playwright and Selenium are untouched. This is a
further argument for the plain fetcher, or for watching a JSON endpoint rather
than a rendered page -- see contrib/podman/WATCHING.md.

SWITCH IT OFF with MAKU_CONDITIONAL_FETCH=0 in the container's environment. The
app is then exactly stock on this path, with no redeploy needed beyond a restart.
"""

import os
import threading

# In-process only, deliberately: a restart costs one full fetch per watch and
# nothing else, which is a much better failure mode than a cache on disk that can
# outlive the code that wrote it and be trusted by a version that should not.
MAX_ENTRIES = 20

# Per entry, on the raw body. A page over this is not what this is for -- the
# cheap path exists for small, stable documents, and the memory ceiling matters
# more than covering every page. Both the decoded text and the raw bytes are
# kept, so the real ceiling is about twice this per entry.
MAX_BODY_BYTES = 1024 * 1024

ENV_SWITCH = 'MAKU_CONDITIONAL_FETCH'

# A server that cannot answer a conditional HEAD is remembered as such, so the
# revalidation is attempted once and never again in this process. Without it, a
# site that answers HEAD with 405 would pay an extra request on EVERY check --
# this patch would make it slower than stock, which is worse than not helping.
BLOCKED = 'blocked'

_lock = threading.Lock()
_cache = {}


def is_enabled(env=None):
    """Off only when the switch says so. Absent means on."""
    raw = (env if env is not None else os.environ).get(ENV_SWITCH)
    if raw is None:
        return True
    return str(raw).strip().lower() not in ('0', 'false', 'no', 'off', '')


def pick_validators(headers):
    """The conditional headers to send next time, given a response's headers.

    ETag first, and BOTH when both are present -- RFC 9110 has the server
    evaluate If-None-Match and ignore If-Modified-Since when both arrive, so
    sending the pair costs nothing and helps the servers that only implement one.
    """
    if not headers:
        return {}
    get = getattr(headers, 'get', None)
    if get is None:
        return {}
    out = {}
    etag = get('etag')
    # A weak validator (W/"...") is still a validator: it promises semantic
    # equivalence, which is exactly the question a change detector is asking.
    if etag and str(etag).strip():
        out['If-None-Match'] = str(etag).strip()
    modified = get('last-modified')
    if modified and str(modified).strip():
        out['If-Modified-Since'] = str(modified).strip()
    return out


def can_revalidate(request_method, request_body, request_headers):
    """Whether this particular request is one we may answer from cache.

    Anything that is not a plain GET is left alone. A POST has a body that
    decides the response, a HEAD has no body to cache, and a caller that already
    set its own conditional header has made a decision this must not overrule.
    """
    if request_body:
        return False
    if request_method and str(request_method).upper() != 'GET':
        return False
    for name in (request_headers or {}):
        if str(name).lower() in ('if-none-match', 'if-modified-since'):
            return False
    return True


def cache_key(watch_uuid, url, request_headers=None):
    """Per watch, per URL, and per set of request headers.

    The first two are obvious. The third is the one that would bite: a cart page
    watched with a session cookie and the same URL watched without one are two
    different pages, and a watch that arrives here without a uuid -- the probe,
    browser steps -- would otherwise collide with whatever else asked for that
    URL. Hashing the headers makes the collision impossible instead of unlikely,
    and a header that rotates merely costs a cache miss, which is the safe
    direction to be wrong in.
    """
    import hashlib
    items = sorted((str(k).lower(), str(v)) for k, v in (request_headers or {}).items())
    fingerprint = hashlib.md5(repr(items).encode('utf-8', 'replace')).hexdigest()[:12]
    return (str(watch_uuid or ''), str(url or ''), fingerprint)


def remember(key, entry):
    with _lock:
        _cache.pop(key, None)
        _cache[key] = entry
        while len(_cache) > MAX_ENTRIES:
            # Oldest insertion first; dicts have kept insertion order since 3.7.
            _cache.pop(next(iter(_cache)))


def recall(key):
    with _lock:
        return _cache.get(key)


def forget(key):
    with _lock:
        _cache.pop(key, None)


def block(key):
    remember(key, BLOCKED)


def reset():
    """For tests, and for nothing else."""
    with _lock:
        _cache.clear()


def build_entry(content, raw_content, headers, screenshot=None):
    """A cache entry, or None when this response must not be cached.

    Returning None rather than raising is the point: every reason to decline --
    no validator, too big, nothing fetched -- is an ordinary outcome, and the
    caller's next move is the same in all of them.
    """
    validators = pick_validators(headers)
    if not validators:
        return None
    size = len(raw_content) if raw_content is not None else len(content or '')
    if size > MAX_BODY_BYTES:
        return None
    return {
        'validators': validators,
        'content': content,
        'raw_content': raw_content,
        'headers': headers,
        'screenshot': screenshot,
    }


def install(module):
    """Wrap the plain-HTTP fetcher's one fetching method.

    The wrapper reads only attributes the fetcher sets for the rest of the
    application to read -- content, raw_content, headers, status_code -- so it
    does not depend on anything private to upstream beyond the name of the method
    it replaces.
    """
    fetcher_class = module.fetcher
    original = fetcher_class._run_sync
    if getattr(original, '_maku_conditional', False):
        return

    def _run_sync(self, url=None, timeout=None, request_headers=None,
                  request_body=None, request_method=None, **kwargs):
        key = cache_key(kwargs.get('watch_uuid'), url, request_headers)
        usable = is_enabled() and can_revalidate(request_method, request_body, request_headers)
        entry = recall(key) if usable else None

        if entry and entry is not BLOCKED:
            outcome = _revalidate(self, url, timeout, request_headers, entry['validators'])
            if outcome == 304:
                _replay(self, entry)
                _log(f"maku: 304 for {url} -- reused {len(entry['raw_content'] or b'')} cached bytes")
                return
            if outcome is None:
                # The server could not answer the question at all. Stop asking it.
                block(key)
            else:
                forget(key)

        original(self, url=url, timeout=timeout, request_headers=request_headers,
                 request_body=request_body, request_method=request_method, **kwargs)

        if usable and recall(key) is not BLOCKED:
            _store(self, key)

    _run_sync._maku_conditional = True
    fetcher_class._run_sync = _run_sync


def _store(self, key):
    """Cache what the real fetch just produced, if it can be cached at all."""
    try:
        if getattr(self, 'status_code', None) != 200:
            forget(key)
            return
        entry = build_entry(content=getattr(self, 'content', None),
                            raw_content=getattr(self, 'raw_content', None),
                            headers=getattr(self, 'headers', None),
                            screenshot=getattr(self, 'screenshot', None))
        if entry is None:
            forget(key)
        else:
            remember(key, entry)
    except Exception:
        forget(key)


def _replay(self, entry):
    """Put the fetcher back exactly where the last real 200 left it."""
    self.content = entry['content']
    self.raw_content = entry['raw_content']
    self.headers = entry['headers']
    self.status_code = 200
    if entry['screenshot'] is not None:
        self.screenshot = entry['screenshot']


def _revalidate(self, url, timeout, request_headers, validators):
    """304, another status code, or None when the server could not be asked.

    A HEAD, not a GET: a conditional GET that misses returns the whole body,
    which would then be thrown away and downloaded a second time by the real
    fetch below. HEAD never carries a body, so a miss costs one small round trip
    and a hit costs the same. The distinction between "not 304" and "could not
    ask" is what decides whether this key is retried or written off, so the two
    must not collapse into one return value.
    """
    try:
        import requests
        headers = dict(request_headers or {})
        headers.update(validators)
        response = requests.head(url,
                                 headers=headers,
                                 timeout=timeout,
                                 proxies=_proxies(self),
                                 verify=False,
                                 allow_redirects=False)
        status = response.status_code
        if status == 304:
            return 304
        if status == 200:
            # An honest "it changed". The real fetch runs, and this key stays
            # eligible for the cheap path next time.
            return 200
        # 405, 403, a redirect, a 5xx: this server does not do conditional HEAD
        # requests, or does not do HEAD at all.
        return None
    except Exception:
        return None


def _proxies(self):
    """The same proxy map the fetcher itself builds, read off the same fields."""
    override = getattr(self, 'proxy_override', None)
    if override:
        return {'http': override, 'https': override, 'ftp': override}
    proxies = {}
    http_proxy = getattr(self, 'system_http_proxy', None)
    https_proxy = getattr(self, 'system_https_proxy', None)
    if http_proxy:
        proxies['http'] = http_proxy
    if https_proxy:
        proxies['https'] = https_proxy
    return proxies


def _log(message):
    try:
        from loguru import logger
        logger.debug(message)
    except Exception:
        pass

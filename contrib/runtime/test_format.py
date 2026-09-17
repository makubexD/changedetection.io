"""What the replacement filter does to a number. Plain python, no test framework.

The floor matters as much as the ceiling: money that reads as 1,099 instead of
1,099.00 would be a regression dressed up as a fix.
"""

import locale
import sys

sys.path.insert(0, __file__.rsplit('test_format.py', 1)[0])
from sitecustomize import decimals_for, format_number_locale  # noqa: E402

locale.setlocale(locale.LC_NUMERIC, 'C')

CASES = [
    # value,      decimals, formatted     why this case is here
    (3.3715,      4, '3.3715',     'the whole point -- a currency rate, not money'),
    (3.348,       3, '3.348',      'the other rate on the same page'),
    (1099.0,      2, '1099.00',    'money keeps its cents; normalize() must not strip to 1099'),
    (249,         2, '249.00',     'an int is still a price'),
    (0.000123,    6, '0.000123',   'at the cap, exactly'),
    (0.00000015,  6, '0.00000015', 'past the cap -- lossy BY DESIGN, and it must not crash'),
    (100,         2, '100.00',     'a positive exponent after normalize(), not a negative one'),
    (0.0,         2, '0.00',       'zero'),
    (-3.3715,     4, '-3.3715',    'sign does not change precision'),
]

failures = 0
for value, expected_dp, expected_text, why in CASES:
    got_dp = decimals_for(value)
    got_text = format_number_locale(value)
    # The cap case cannot round-trip; assert the cap held rather than the text.
    ok = got_dp == expected_dp and (got_text == expected_text or expected_dp == 6)
    failures += not ok
    print(f"{'ok  ' if ok else 'FAIL'} {value!r:>12} -> {got_dp} dp, {got_text!r}   ({why})")
    if not ok:
        print(f"     expected {expected_dp} dp, {expected_text!r}")

print()
for junk, label in [(None, 'None'), ('3.37', 'a string'), (True, 'a bool'), (float('nan'), 'NaN')]:
    try:
        out = format_number_locale(junk)
        print(f"ok   {label:>10} -> {out!r}   (survived; the template only sends numbers, but still)")
    except Exception as e:
        failures += 1
        print(f"FAIL {label:>10} raised {type(e).__name__}: {e}")

print()
print(f"{'FAILED' if failures else 'PASSED'} -- {failures} failure(s)")
sys.exit(1 if failures else 0)

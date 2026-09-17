# Every container image this project pins, in one place.
#
# THE BROWSER IS PINNED BY DIGEST, NOT :latest. That tag is rebuilt often and its
# Dockerfile installs whatever Chrome Stable is current on build day
# (ARG CHROME_VERSION=current), so :latest swaps Chrome underneath you with no
# change on your side. Upstream CI broke exactly this way on 2026-09-10.
#
# The same digest also appears in podman-compose.yml, changedetection-kube.yaml
# and sockpuppetbrowser.container, which cannot read PowerShell. Do not edit
# those by hand -- they drift. Instead:
#
#   .\contrib\maku.ps1 images show
#   .\contrib\maku.ps1 images pin browser sha256:<new digest>
#   .\contrib\maku.ps1 images verify
#
# To find a newer digest deliberately:
#   podman pull docker.io/dgtlmoon/sockpuppetbrowser:latest
#   podman image inspect docker.io/dgtlmoon/sockpuppetbrowser:latest --format '{{.Digest}}'

@{
    # Built locally by 'app build' from this repo's root Dockerfile.
    AppLocal     = 'changedetection.io:dev'

    # Published by .github/workflows/maku-container-build.yml on every push to
    # maku-release. GHCR lowercases the namespace, hence makubexd not makubexD.
    AppPublished = 'ghcr.io/makubexd/changedetection.io:stable'

    # Real Chrome, wrapped in an API. Optional; started by -WithBrowser.
    Browser      = 'docker.io/dgtlmoon/sockpuppetbrowser@sha256:a61e64a694fef3b6d375a3c7c7dd7d74b1166a48b231cd98870b78f244deef79'

    # Files carrying a literal copy of Browser, relative to the repo root.
    # 'images pin' rewrites these; 'images verify' fails when they disagree.
    BrowserMirrors = @(
        'contrib/podman/podman-compose.yml'
        'contrib/podman/changedetection-kube.yaml'
        'contrib/podman/sockpuppetbrowser.container'
    )
}

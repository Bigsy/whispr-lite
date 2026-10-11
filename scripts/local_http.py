"""HTTP opener for loopback model services that ignores inherited proxy settings."""

from urllib.request import ProxyHandler, build_opener

LOCAL = build_opener(ProxyHandler({}))

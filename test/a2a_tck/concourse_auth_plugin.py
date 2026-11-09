"""Attach a bearer token to every httpx client the A2A TCK creates.

Loaded with ``pytest -p concourse_auth_plugin`` (this directory on
PYTHONPATH). The pinned TCK (263b9cf) documents ``A2A_AUTH_*`` but its
JsonRpcClient only sets ``A2A-Version``, and the card fetch is a bare
``httpx.get``. Concourse requires a bearer token on JSON-RPC. Patching
the client classes leaves the TCK tree unmodified.

The public card ignores the header. That is fine: the card is public
(§7.3) and the TCK fetches it before it holds a credential.
"""

from __future__ import annotations

import os

import httpx


_TOKEN = os.environ.get("A2A_TCK_TOKEN", "")
_HEADER = f"Bearer {_TOKEN}" if _TOKEN else ""


def _with_authorization(headers: object) -> dict[str, str]:
    merged = dict(headers or {})
    merged.setdefault("Authorization", _HEADER)
    return merged


def _patch(client_cls: type) -> None:
    if getattr(client_cls, "_concourse_auth_patched", False):
        return

    original = client_cls.__init__

    def init(self, *args, **kwargs):  # type: ignore[no-untyped-def]
        if _HEADER:
            kwargs["headers"] = _with_authorization(kwargs.get("headers"))
        original(self, *args, **kwargs)

    client_cls.__init__ = init  # type: ignore[method-assign]
    client_cls._concourse_auth_patched = True  # type: ignore[attr-defined]


def pytest_configure() -> None:
    """Patch before fixtures build transport clients."""
    _patch(httpx.Client)
    _patch(httpx.AsyncClient)


# Import-time as well: a plugin loaded with -p is imported before
# pytest_configure of later plugins, but httpx.get in a session fixture
# must already see the patch if configure order slips.
_patch(httpx.Client)
_patch(httpx.AsyncClient)

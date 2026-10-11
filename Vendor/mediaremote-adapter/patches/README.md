# Whispr Lite broker addition

Upstream v0.7.6 files are unchanged. `broker.m` adds an exported `adapter_broker` entry;
`broker.pl` loads it through `/usr/bin/perl` with DynaLoader. The app build compiles only
upstream `globals.m`, `MediaRemote.m`, `helpers.m` and this addition into an arm64 framework.
The benchmark builds full upstream sources separately in `.build/media-upstream` for its
one-shot `get` comparison. The broker restores default SIGINT/SIGTERM handling at entry.

The protocol uses inherited pipes, UTF-8 newline-delimited JSON, version 1, a helper UUID,
request/session UUIDs and a bounded `deadlineMS`. Only `snapshot`, `begin`, `end` and
`shutdown` are accepted in production. Lines are bounded at 8 KiB, output at 64 KiB and
queued state queries at 16. State queries run sequentially with 500 ms deadlines; their
late callbacks cannot update state. End is registered immediately and cancels an unsent
pause. The issued ledger survives a client-side response timeout. Pause and Play are
explicit; Toggle is never called.

Identity requires PID, process launch time, bundle ID and an upstream item identifier.
Some players refresh the opaque item identifier after Pause. An identifier refresh keeps
ownership when the same player/process and bounded title, artist/album and positive finite
duration still match. Actual metadata changes invalidate ownership even if an opaque ID
is reused. Missing/invalid metadata retains the strict opaque-ID check. Comparison values
stay in helper RAM; title/artist/album are each bounded to 1024 characters and stripped
from every protocol reply. Debug mode records only `itemIdentifierRefreshed`, never values.
Missing/ambiguous identities skip control. Control also requires evidence that the notification
subscription has delivered an event in this helper generation; direct reads alone do not
prove that subscription. Subscription failures without an observable signal remain a
compatibility limitation to verify in the real-player gate. No titles, artwork or playback history are
emitted. Observed external changes invalidate ownership; confirmed paused state and
matching identity are required to submit one Play. `released` means submission; `resumed`
means a subsequent matching playing observation. EOF/shutdown attempts a bounded release.

The private command targets Now Playing globally. Identity checks are not atomic player
or browser-tab targeting. Pressing Pause on already-paused media may be unobservable.
Killed helpers cannot guarantee restoration and no lease is persisted/replayed. The
Swift transport retries transient failure at most twice per app run, after settling the
old process. Replacement generations discard old replies and leases; they never replay
an old resume. Fatal/incompatible protocol disables control for the run. Reads, pending
requests and queued writes are bounded, and pipe writes run off the main actor. This is
a compatibility prototype until the manual player/focus/power matrix passes.

`WHISPR_BROKER_TEST` replaces only the state/command provider, and adds a test-only
`testState` request. It is never defined in `scripts/build-media.sh`. The Python tests
exercise the production ordering, lease and pipe code with that provider, including
same-content identifier refresh, changed content and missing/invalid metadata. They cannot
prove MediaRemote entitlement, player identity or actual playback behavior.
The Swift client tests additionally launch synthetic Perl helpers to exercise crashes,
stale generations, fatal permission replies, malformed/oversized output and slow readers.

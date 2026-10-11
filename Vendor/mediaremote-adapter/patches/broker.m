// whispr-lite local addition. Upstream files remain unmodified (BSD-3-Clause).
#import <AppKit/AppKit.h>
#import "adapter/globals.h"
#import "private/MediaRemote.h"
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>
#include <math.h>
#include <signal.h>

static NSString *generation;
static NSMutableData *input, *output;
static dispatch_source_t reader, writer;
static NSMutableDictionary *lease;
static NSDictionary *state;
static NSUInteger observation;
static BOOL queryBusy, queryAgain, closing, subscriptionHealthy, diagnosticsEnabled;
static NSMutableArray *queryCallbacks;
static NSString *queryOwner;
static void querySnapshot(void (^done)(NSDictionary *));
static void pumpQueries(void);
static void brokerShutdown(void);
static void refresh(void (^done)(NSDictionary *));
static void releaseLease(void);
#ifdef WHISPR_BROKER_TEST
static NSMutableDictionary *fakeState;
#endif
static void emit(NSDictionary *event);
static BOOL issue(MRCommand command) {
#ifdef WHISPR_BROKER_TEST
    emit(@{@"type": @"testCommand", @"command": @(command)});
    if (!getenv("WHISPR_TEST_UNCONFIRMED")) fakeState[@"playing"] = @(command == kMRPlay);
    // Chrome-like players mint a new opaque item ID in the same update that reports the pause.
    if (command == kMRPause && getenv("WHISPR_TEST_PAUSE_ITEM")) fakeState[@"item"] = @(getenv("WHISPR_TEST_PAUSE_ITEM"));
    if (command == kMRPause && getenv("WHISPR_TEST_PAUSE_TITLE")) {
        NSMutableDictionary *metadata = [fakeState[@"metadata"] mutableCopy]; metadata[@"title"] = @(getenv("WHISPR_TEST_PAUSE_TITLE"));
        fakeState[@"metadata"] = metadata;
    }
    return YES;
#else
    return g_mediaRemote.sendCommand(command, nil);
#endif
}

static void emit(NSDictionary *event) {
    NSData *data = [NSJSONSerialization dataWithJSONObject:event options:0 error:nil];
    if (!data || data.length > 8192 || output.length + data.length > 65536) { exit(2); }
    [output appendData:data]; [output appendBytes:"\n" length:1];
    dispatch_source_merge_data(writer, 1);
}
static NSDictionary *envelope(NSString *type, NSString *request, NSString *session) {
    return @{ @"version": @1, @"type": type, @"generation": generation,
              @"request": request ?: @"", @"session": session ?: @"" };
}
static void replyReason(NSString *type, NSDictionary *request, NSDictionary *snapshot, NSString *reason) {
    NSMutableDictionary *event = [envelope(type, request[@"request"], request[@"session"]) mutableCopy];
    if (diagnosticsEnabled && reason) event[@"reason"] = reason;
    if (snapshot) {
        // Boxed C comparisons can become JSON 0/1. The Swift protocol expects
        // booleans; normalize at the common wire boundary for every provider.
        NSMutableDictionary *wire = [snapshot mutableCopy];
        // The bounded track comparison is helper-local RAM only, never protocol/log data.
        [wire removeObjectForKey:@"trackIdentity"];
        [wire removeObjectForKey:@"metadata"];
        for (NSString *key in @[@"known", @"playing", @"trustworthy", @"subscriptionHealthy"]) {
            if (snapshot[key]) wire[key] = [NSNumber numberWithBool:[snapshot[key] boolValue]];
        }
        event[@"state"] = wire;
    }
    emit(event);
}
static void reply(NSString *type, NSDictionary *request, NSDictionary *snapshot) { replyReason(type, request, snapshot, nil); }
static NSArray *trackIdentity(id title, id artist, id album, id duration) {
    if (![title isKindOfClass:NSString.class] || ![title length] || [title length] > 1024 ||
        (artist && (![artist isKindOfClass:NSString.class] || [artist length] > 1024)) ||
        (album && (![album isKindOfClass:NSString.class] || [album length] > 1024)) ||
        (![artist length] && ![album length]) || ![duration isKindOfClass:NSNumber.class]) return nil;
    double seconds = [duration doubleValue];
    if (!isfinite(seconds) || seconds <= 0) return nil;
    return @[[title copy], [artist copy] ?: @"", [album copy] ?: @"", @(seconds)];
}
#ifdef WHISPR_BROKER_TEST
static NSDictionary *fakeSnapshot(void) {
    NSMutableDictionary *snapshot = [fakeState mutableCopy];
    NSDictionary *metadata = [snapshot[@"metadata"] isKindOfClass:NSDictionary.class] ? snapshot[@"metadata"] : nil;
    NSArray *track = trackIdentity(metadata[@"title"], metadata[@"artist"], metadata[@"album"], metadata[@"duration"]);
    [snapshot removeObjectForKey:@"trackIdentity"];
    if (track) snapshot[@"trackIdentity"] = track;
    [snapshot removeObjectForKey:@"metadata"];
    return snapshot;
}
#endif
/// Same title, artist and album; players may report a slightly different duration once paused.
static BOOL sameTrack(NSArray *a, NSArray *b) {
    return [a[0] isEqual:b[0]] && [a[1] isEqual:b[1]] && [a[2] isEqual:b[2]] && fabs([a[3] doubleValue] - [b[3] doubleValue]) <= 1;
}
static NSString *identityFailure(NSDictionary *a, NSDictionary *b) {
    if (![b[@"known"] boolValue]) return @"unknownPlayer";
    if (![a[@"trustworthy"] boolValue] || ![b[@"trustworthy"] boolValue]) return @"unidentifiedPlayer";
    if (![a[@"pid"] isEqual:b[@"pid"]] || ![a[@"bundle"] isEqual:b[@"bundle"]]) return @"playerChanged";
    if (![a[@"lifetime"] isEqual:b[@"lifetime"]]) return @"playerRestarted";
    NSArray *before = a[@"trackIdentity"], *after = b[@"trackIdentity"];
    // Some players regenerate the opaque content ID after Pause. Matching bounded
    // content metadata distinguishes that refresh from a real track change.
    if (before && after && !sameTrack(before, after)) return @"itemChanged";
    if (![a[@"item"] isEqual:b[@"item"]] && !(before && after && sameTrack(before, after))) return @"itemChanged";
    return nil;
}
/// Chrome reports our Pause and a new opaque item ID in the same update, often with no
/// artist/album/duration to compare. Until the pause is confirmed, the same player process
/// with no contradicting track metadata is that refresh. Once confirmed, changes stay strict.
static BOOL pauseRefresh(NSDictionary *owned, NSDictionary *next) {
    NSDictionary *a = owned[@"identity"];
    NSArray *before = a[@"trackIdentity"], *after = next[@"trackIdentity"];
    return ![owned[@"confirmed"] boolValue] && [identityFailure(a, next) isEqual:@"itemChanged"] &&
        ![a[@"item"] isEqual:next[@"item"]] && !(before && after && !sameTrack(before, after));
}
static BOOL identityMatches(NSDictionary *a, NSDictionary *b) { return identityFailure(a, b) == nil; }
static void invalidateLease(NSString *reason) {
    NSDictionary *owned = lease; lease = nil;
    if (diagnosticsEnabled) replyReason(@"skipped", owned, state, reason);
}
static void acceptState(NSDictionary *next) {
    observation++;
    NSMutableDictionary *value = [next mutableCopy]; value[@"sequence"] = @(observation); value[@"subscriptionHealthy"] = @(subscriptionHealthy);
    state = value;
    if (lease && [lease[@"issued"] boolValue]) {
        NSString *reason = pauseRefresh(lease, state) ? nil : identityFailure(lease[@"identity"], state);
        if (reason) { invalidateLease(reason); }
        else {
            if (![lease[@"identity"][@"item"] isEqual:state[@"item"]]) {
                lease[@"identity"] = state;
                if (diagnosticsEnabled) replyReason(@"snapshot", lease, state, @"itemIdentifierRefreshed");
            }
            if (![state[@"playing"] boolValue]) {
                if (![lease[@"confirmed"] boolValue]) { lease[@"confirmed"] = @YES; reply(@"paused", lease, state); }
            }
            else if ([lease[@"confirmed"] boolValue]) { invalidateLease(@"externalPlayback"); }
        }
    }
    if (lease && [lease[@"ended"] boolValue] && [lease[@"confirmed"] boolValue]) releaseLease();
}
static void refresh(void (^done)(NSDictionary *)) {
    if (queryCallbacks.count >= 16) { brokerShutdown(); return; }
    [queryCallbacks addObject:done ? [done copy] : [NSNull null]];
    pumpQueries();
}
static void pumpQueries(void) {
    if (queryOwner || !queryCallbacks.count) return;
    id callback = queryCallbacks[0]; [queryCallbacks removeObjectAtIndex:0];
    NSString *owner = NSUUID.UUID.UUIDString; queryOwner = owner;
    void (^complete)(NSDictionary *) = ^(NSDictionary *next) {
        if (![queryOwner isEqual:owner]) return;
        queryOwner = nil;
        if (next) acceptState(next);
        if (callback != [NSNull null]) ((void (^)(NSDictionary *))callback)(next ? state : @{@"known": @NO, @"playing": @NO, @"trustworthy": @NO});
        pumpQueries();
    };
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 500 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{ complete(nil); });
    querySnapshot(complete);
}
static void querySnapshot(void (^done)(NSDictionary *)) {
#ifdef WHISPR_BROKER_TEST
    NSDictionary *snapshot = fakeSnapshot();
    int delay = getenv("WHISPR_TEST_QUERY_DELAY_MS") ? atoi(getenv("WHISPR_TEST_QUERY_DELAY_MS")) : 0;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, delay * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
        done(snapshot);
    });
#else
    // All decisions and command submissions run on the main queue. Never block that queue.
    g_mediaRemote.getNowPlayingApplicationPID(dispatch_get_main_queue(), ^(int pid) {
        if (pid <= 0) { NSDictionary *empty = @{@"known": @NO, @"playing": @NO, @"trustworthy": @NO}; done(empty); return; }
        NSRunningApplication *app = [NSRunningApplication runningApplicationWithProcessIdentifier:pid];
        NSString *bundle = app.bundleIdentifier;
        NSDate *launch = app.launchDate;
        g_mediaRemote.getNowPlayingInfo(dispatch_get_main_queue(), ^(NSDictionary *info) {
            g_mediaRemote.getNowPlayingApplicationIsPlaying(dispatch_get_main_queue(), ^(bool playing) {
                g_mediaRemote.getNowPlayingApplicationPID(dispatch_get_main_queue(), ^(int finalPID) {
                    id item = info[kMRMediaRemoteNowPlayingInfoContentItemIdentifier] ?: info[kMRMediaRemoteNowPlayingInfoUniqueIdentifier];
                    if ([item isKindOfClass:[NSNumber class]]) item = [item stringValue];
                    BOOL trusted = finalPID == pid && bundle && launch && [item isKindOfClass:[NSString class]] && [item length] > 0 && [item length] <= 1024;
                    NSDictionary *next = @{@"known": @(finalPID == pid), @"playing": @(playing), @"trustworthy": @(trusted),
                        @"pid": @(pid), @"bundle": bundle ?: @"", @"lifetime": launch ? @([launch timeIntervalSince1970]) : @0,
                        @"item": trusted ? item : @""};
                    NSArray *track = trackIdentity(info[kMRMediaRemoteNowPlayingInfoTitle], info[kMRMediaRemoteNowPlayingInfoArtist],
                        info[kMRMediaRemoteNowPlayingInfoAlbum], info[kMRMediaRemoteNowPlayingInfoDuration]);
                    if (track) {
                        NSMutableDictionary *identified = [next mutableCopy]; identified[@"trackIdentity"] = track;
                        done(identified);
                    } else done(next);
                });
            });
        });
    });
#endif
}
static void releaseLease(void) {
    if (!lease || [lease[@"releasing"] boolValue]) return;
    lease[@"releasing"] = @YES;
    NSMutableDictionary *owned = lease;
    refresh(^(NSDictionary *current) {
        if (lease != owned) return;
        NSString *reason = !subscriptionHealthy ? @"subscriptionUnavailable" :
            ![owned[@"confirmed"] boolValue] ? @"pauseUnconfirmed" :
            identityFailure(owned[@"identity"], current) ?: ([current[@"playing"] boolValue] ? @"externalPlayback" : nil);
        if (!reason) {
            // MediaRemote targets Now Playing globally: this identity check is not atomic targeting.
            // Remove ownership before submitting Play so duplicate end/notifications cannot replay it.
            lease = nil;
            if (!issue(kMRPlay)) { replyReason(@"skipped", owned, current, @"resumeRejected"); return; }
            reply(@"released", owned, current); // submission only
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 40 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
                refresh(^(NSDictionary *next) {
                    BOOL sameItem = identityMatches(owned[@"identity"], next) || pauseRefresh(@{@"identity": owned[@"identity"]}, next);
                    BOOL resumed = sameItem && [next[@"playing"] boolValue];
                    replyReason(resumed ? @"resumed" : @"unconfirmed", owned, next, resumed ? nil : @"resumeUnconfirmed");
                });
            });
        } else { lease = nil; replyReason(@"skipped", owned, current, reason); }
    });
}
static void begin(NSDictionary *request) {
    if (lease || closing) { replyReason(@"skipped", request, state, closing ? @"closing" : @"leaseBusy"); return; }
    lease = [request mutableCopy];
    NSMutableDictionary *owned = lease;
    refresh(^(NSDictionary *current) {
        if (lease != owned) return;
        NSString *reason = [owned[@"ended"] boolValue] ? @"endedBeforePause" :
            !subscriptionHealthy ? @"subscriptionUnavailable" :
            ![current[@"known"] boolValue] ? @"unknownPlayer" :
            ![current[@"trustworthy"] boolValue] ? @"unidentifiedPlayer" :
            ![current[@"playing"] boolValue] ? @"alreadyPaused" : nil;
        if (reason) {
            lease = nil; replyReason(@"skipped", request, current, reason); return;
        }
        owned[@"identity"] = current;
        owned[@"issued"] = @YES; // retain ledger even if command response/confirmation times out
        if (!issue(kMRPause)) { lease = nil; replyReason(@"skipped", request, current, @"pauseRejected"); return; }
        reply(@"issued", request, current);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 40 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
            if (lease == owned) refresh(nil);
        });
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 500 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
        if (lease != owned) return;
        if (![owned[@"issued"] boolValue]) { lease = nil; replyReason(@"skipped", request, state, @"queryTimeout"); }
        else if (![owned[@"confirmed"] boolValue]) replyReason(@"unconfirmed", request, state, @"pauseUnconfirmed");
    });
}
static void brokerShutdown(void) {
    if (closing) return;
    closing = YES;
    if (lease) { lease[@"ended"] = @YES; releaseLease(); }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 600 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{ exit(0); });
}
static void handle(NSDictionary *request) {
    if ([request isKindOfClass:[NSDictionary class]] && [request[@"generation"] isKindOfClass:[NSString class]] && ![request[@"generation"] isEqual:generation]) return;
#ifdef WHISPR_BROKER_TEST
    if ([request[@"operation"] isEqual:@"testState"]) {
        [fakeState addEntriesFromDictionary:request[@"state"]]; acceptState(fakeSnapshot()); return;
    }
#endif
    if (![request isKindOfClass:[NSDictionary class]] || ![request[@"version"] isEqual:@1] || ![request[@"generation"] isEqual:generation] ||
        ![request[@"request"] isKindOfClass:[NSString class]] || [request[@"request"] length] > 64 ||
        ![request[@"session"] isKindOfClass:[NSString class]] || [request[@"session"] length] > 64 ||
        ![request[@"deadlineMS"] isKindOfClass:[NSNumber class]] || [request[@"deadlineMS"] intValue] < 1 || [request[@"deadlineMS"] intValue] > 500) { brokerShutdown(); return; }
    NSString *op = request[@"operation"];
    if ([op isEqual:@"snapshot"]) refresh(^(NSDictionary *value) { reply(@"snapshot", request, value); });
    else if ([op isEqual:@"begin"]) begin(request);
    else if ([op isEqual:@"end"]) {
        if (lease && [lease[@"session"] isEqual:request[@"session"]]) {
            lease[@"ended"] = @YES;
            if ([lease[@"issued"] boolValue]) releaseLease();
            else { lease = nil; replyReason(@"skipped", request, state, @"endedBeforePause"); }
        } else replyReason(@"skipped", request, state, lease ? @"sessionMismatch" : @"noLease");
    } else if ([op isEqual:@"shutdown"]) brokerShutdown();
    else brokerShutdown();
}
void adapter_broker(void) {
    // An upstream adapter constructor only stops one run-loop iteration.
    signal(SIGTERM, SIG_DFL);
    signal(SIGINT, SIG_DFL);
    @autoreleasepool {
        generation = NSUUID.UUID.UUIDString;
        const char *debug = getenv("WHISPR_DEBUG_DIAGNOSTICS");
        diagnosticsEnabled = debug && strcmp(debug, "1") == 0;
        input = [NSMutableData data]; output = [NSMutableData data]; queryCallbacks = [NSMutableArray array];
        fcntl(STDIN_FILENO, F_SETFL, O_NONBLOCK); fcntl(STDOUT_FILENO, F_SETFL, O_NONBLOCK);
        signal(SIGPIPE, SIG_IGN);
        writer = dispatch_source_create(DISPATCH_SOURCE_TYPE_DATA_ADD, 0, 0, dispatch_get_main_queue());
        dispatch_source_set_event_handler(writer, ^{
            while (output.length) {
                ssize_t n = write(STDOUT_FILENO, output.bytes, output.length);
                if (n > 0) [output replaceBytesInRange:NSMakeRange(0, n) withBytes:NULL length:0];
                else if (errno == EAGAIN || errno == EINTR) { dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{ dispatch_source_merge_data(writer, 1); }); return; }
                else { brokerShutdown(); return; }
            }
        }); dispatch_resume(writer);
        reader = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, STDIN_FILENO, 0, dispatch_get_main_queue());
        dispatch_source_set_event_handler(reader, ^{
            uint8_t bytes[4096]; ssize_t count = read(STDIN_FILENO, bytes, sizeof(bytes));
            if (count == 0) { dispatch_source_cancel(reader); brokerShutdown(); return; }
            if (count < 0) { if (errno != EAGAIN && errno != EINTR) brokerShutdown(); return; }
            [input appendBytes:bytes length:count];
            while (input.length) {
                const uint8_t *start = input.bytes; const uint8_t *newline = memchr(start, '\n', input.length);
                if (!newline) { if (input.length > 8192) brokerShutdown(); break; }
                NSUInteger length = newline - start;
                if (length > 8192) { brokerShutdown(); return; }
                NSData *line = [input subdataWithRange:NSMakeRange(0, length)];
                [input replaceBytesInRange:NSMakeRange(0, length + 1) withBytes:NULL length:0];
                handle([NSJSONSerialization JSONObjectWithData:line options:0 error:nil]);
            }
        }); dispatch_resume(reader);
#ifdef WHISPR_BROKER_TEST
        subscriptionHealthy = YES;
        fakeState = [@{@"known": @YES, @"playing": @YES, @"trustworthy": @YES,
                     @"pid": @12, @"bundle": @"synthetic.player", @"lifetime": @1, @"item": @"synthetic.track"} mutableCopy];
#else
        if (!g_mediaRemote || !g_mediaRemote.getNowPlayingInfo || !g_mediaRemote.sendCommand) { exit(3); }
        g_mediaRemote.registerForNowPlayingNotifications(dispatch_get_main_queue());
        for (NSString *name in @[kMRMediaRemoteNowPlayingInfoDidChangeNotification, kMRMediaRemoteNowPlayingApplicationDidChangeNotification, kMRMediaRemoteNowPlayingApplicationIsPlayingDidChangeNotification]) {
            [NSNotificationCenter.defaultCenter addObserverForName:name object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *_) {
                subscriptionHealthy = YES;
                if (queryBusy) { queryAgain = YES; return; }
                queryBusy = YES;
                refresh(^(NSDictionary *value) {
                    queryBusy = NO;
                    if (queryAgain) { queryAgain = NO; refresh(nil); }
                });
            }];
        }
        #endif
        // Ready proves transport availability, not a supported player. Unknown state never controls media.
        emit(envelope(@"ready", nil, nil));
        refresh(^(NSDictionary *value) { reply(@"snapshot", @{}, value); });
        [[NSRunLoop currentRunLoop] run];
    }
}

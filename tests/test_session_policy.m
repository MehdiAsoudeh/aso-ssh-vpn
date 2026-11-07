#import <Foundation/Foundation.h>
#import "VPNSessionPolicy.h"

static int g_failures = 0;

static void expect_true(const char *name, BOOL cond) {
    if (!cond) {
        fprintf(stderr, "FAIL: %s\n", name);
        g_failures++;
    } else {
        printf("ok: %s\n", name);
    }
}

static void expect_eq(const char *name, NSInteger got, NSInteger want) {
    if (got != want) {
        fprintf(stderr, "FAIL: %s (got %ld want %ld)\n", name, (long)got, (long)want);
        g_failures++;
    } else {
        printf("ok: %s\n", name);
    }
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        // 1) Adding/selecting config must never arm reconnect.
        {
            VPNSessionPolicy *p = [VPNSessionPolicy new];
            expect_true("idle: no reconnect", ![p shouldAutoReconnectWhileTunnelUp:NO isBusy:NO]);
            expect_true("idle: config change ok", [p allowsConfigChangeWhileConnected:NO]);
            expect_true("connected UI alone: config locked", ![p allowsConfigChangeWhileConnected:YES]);
        }

        // 2) Failed first Connect → no auto retry.
        {
            VPNSessionPolicy *p = [VPNSessionPolicy new];
            [p userTappedConnect];
            expect_true("after tap: still no reconnect (never succeeded)", ![p shouldAutoReconnectWhileTunnelUp:NO isBusy:NO]);
            [p connectAttemptFailed];
            expect_true("failed first connect clears intent", !p.userWantsConnect);
            expect_true("failed first connect: no reconnect", ![p shouldAutoReconnectWhileTunnelUp:NO isBusy:NO]);
        }

        // 3) Success then drop → exactly 3 reconnect schedules, then stop.
        {
            VPNSessionPolicy *p = [[VPNSessionPolicy alloc] initWithMaxReconnectAttempts:3];
            [p userTappedConnect];
            [p connectSucceeded];
            expect_true("after success+drop: reconnect #1 allowed", [p shouldAutoReconnectWhileTunnelUp:NO isBusy:NO]);
            [p noteReconnectScheduled];
            expect_eq("attempts=1", p.reconnectAttempts, 1);
            expect_true("reconnect #2 allowed", [p shouldAutoReconnectWhileTunnelUp:NO isBusy:NO]);
            [p noteReconnectScheduled];
            expect_true("reconnect #3 allowed", [p shouldAutoReconnectWhileTunnelUp:NO isBusy:NO]);
            [p noteReconnectScheduled];
            expect_eq("attempts=3", p.reconnectAttempts, 3);
            expect_true("after 3: no more reconnect", ![p shouldAutoReconnectWhileTunnelUp:NO isBusy:NO]);
        }

        // 4) Leftover tunnel (status ON without user Connect) must not arm reconnect.
        {
            VPNSessionPolicy *p = [VPNSessionPolicy new];
            // Simulate observing tunnel up without calling userTappedConnect/connectSucceeded.
            expect_true("leftover tunnel down: no reconnect", ![p shouldAutoReconnectWhileTunnelUp:NO isBusy:NO]);
            expect_true("leftover tunnel up: no reconnect", ![p shouldAutoReconnectWhileTunnelUp:YES isBusy:NO]);
        }

        // 5) Busy blocks reconnect; Disconnect clears.
        {
            VPNSessionPolicy *p = [VPNSessionPolicy new];
            [p userTappedConnect];
            [p connectSucceeded];
            expect_true("busy blocks reconnect", ![p shouldAutoReconnectWhileTunnelUp:NO isBusy:YES]);
            [p userClearedIntent];
            expect_true("disconnect clears reconnect", ![p shouldAutoReconnectWhileTunnelUp:NO isBusy:NO]);
        }

        // 6) Reconnect failure after prior success still allows retry until max.
        {
            VPNSessionPolicy *p = [[VPNSessionPolicy alloc] initWithMaxReconnectAttempts:3];
            [p userTappedConnect];
            [p connectSucceeded];
            [p connectAttemptFailed]; // keep didConnectSuccessfully
            expect_true("still armed after reconnect fail", p.didConnectSuccessfully);
            expect_true("still may reconnect", [p shouldAutoReconnectWhileTunnelUp:NO isBusy:NO]);
        }

        // 7) Success resets attempt counter.
        {
            VPNSessionPolicy *p = [[VPNSessionPolicy alloc] initWithMaxReconnectAttempts:3];
            [p userTappedConnect];
            [p connectSucceeded];
            [p noteReconnectScheduled];
            [p noteReconnectScheduled];
            expect_eq("attempts before recover", p.reconnectAttempts, 2);
            [p connectSucceeded];
            expect_eq("attempts reset on success", p.reconnectAttempts, 0);
        }

        if (g_failures) {
            fprintf(stderr, "\n%d test(s) failed\n", g_failures);
            return 1;
        }
        printf("\nAll session policy tests passed.\n");
        return 0;
    }
}

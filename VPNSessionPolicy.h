#import <Foundation/Foundation.h>

/// Pure connect/reconnect rules — no UI, no vpn.sh.
/// Auto-reconnect ONLY after a user Connect that once succeeded, then dropped.
@interface VPNSessionPolicy : NSObject

@property (nonatomic, readonly) BOOL userWantsConnect;
@property (nonatomic, readonly) BOOL didConnectSuccessfully;
@property (nonatomic, readonly) NSInteger reconnectAttempts;
@property (nonatomic, readonly) NSInteger maxReconnectAttempts;

- (instancetype)initWithMaxReconnectAttempts:(NSInteger)maxAttempts;

/// User tapped Connect (not yet known if it will succeed).
- (void)userTappedConnect;

/// User tapped Disconnect / Cancel / Reset permission.
- (void)userClearedIntent;

/// Tunnel came up after a user-initiated connect/reconnect.
- (void)connectSucceeded;

/// A connect/reconnect attempt finished without tunnel up.
- (void)connectAttemptFailed;

/// Call from status poll. Never arms reconnect from leftover tunnels alone.
- (BOOL)shouldAutoReconnectWhileTunnelUp:(BOOL)tunnelUp isBusy:(BOOL)isBusy;

/// Call right before scheduling a reconnect attempt.
- (void)noteReconnectScheduled;

/// Whether UI may change the selected config / edit it.
- (BOOL)allowsConfigChangeWhileConnected:(BOOL)isConnected;

@end

#import "VPNSessionPolicy.h"

@interface VPNSessionPolicy ()
@property (nonatomic, readwrite) BOOL userWantsConnect;
@property (nonatomic, readwrite) BOOL didConnectSuccessfully;
@property (nonatomic, readwrite) NSInteger reconnectAttempts;
@property (nonatomic, readwrite) NSInteger maxReconnectAttempts;
@end

@implementation VPNSessionPolicy

- (instancetype)init {
    return [self initWithMaxReconnectAttempts:3];
}

- (instancetype)initWithMaxReconnectAttempts:(NSInteger)maxAttempts {
    self = [super init];
    if (self) {
        _maxReconnectAttempts = MAX(1, maxAttempts);
        _userWantsConnect = NO;
        _didConnectSuccessfully = NO;
        _reconnectAttempts = 0;
    }
    return self;
}

- (void)userTappedConnect {
    self.userWantsConnect = YES;
    self.didConnectSuccessfully = NO;
    self.reconnectAttempts = 0;
}

- (void)userClearedIntent {
    self.userWantsConnect = NO;
    self.didConnectSuccessfully = NO;
    self.reconnectAttempts = 0;
}

- (void)connectSucceeded {
    self.userWantsConnect = YES;
    self.didConnectSuccessfully = YES;
    self.reconnectAttempts = 0;
}

- (void)connectAttemptFailed {
    if (!self.didConnectSuccessfully) {
        // First Connect failed — do not keep retrying on its own.
        self.userWantsConnect = NO;
        self.reconnectAttempts = 0;
    }
    // If we had been connected before, keep flags so shouldAutoReconnect can fire.
}

- (BOOL)shouldAutoReconnectWhileTunnelUp:(BOOL)tunnelUp isBusy:(BOOL)isBusy {
    if (isBusy) return NO;
    if (tunnelUp) return NO;
    if (!self.userWantsConnect) return NO;
    if (!self.didConnectSuccessfully) return NO;
    if (self.reconnectAttempts >= self.maxReconnectAttempts) return NO;
    return YES;
}

- (void)noteReconnectScheduled {
    self.reconnectAttempts += 1;
}

- (BOOL)allowsConfigChangeWhileConnected:(BOOL)isConnected {
    return !isConnected;
}

@end

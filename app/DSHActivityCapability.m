//
//  DSHActivityCapability.m
//  DSH
//

#import "DSHActivityCapability.h"
#import "DSHHostBridge.h"
#import "DSHActivityLog.h"
#include <math.h>

/// A turn can report a burst; accept them in one request rather than one
/// connection each.
static const NSUInteger kMaxBatch = 50;

/// `duration` is the only guest-supplied field here that becomes a number rather
/// than a string, and it was the only one taken without a type check. `1e308` is
/// a legal JSON number; multiplied by 1000 when the record is built it becomes
/// infinity, and NSJSONSerialization refuses to write an infinity -- by raising,
/// not by returning an error -- on the activity log's own queue, where the
/// bridge's @try does not reach. Clamp instead: a call longer than a day is not
/// a real duration.
static NSTimeInterval DSHGuestDuration(id value) {
    if (![value isKindOfClass:NSNumber.class])
        return 0;
    double seconds = [value doubleValue];
    if (!isfinite(seconds) || seconds <= 0)
        return 0;
    return MIN(seconds, 86400);
}

@implementation DSHActivityCapability

+ (void)installOn:(DSHHostBridge *)bridge {
    [bridge registerRoute:@"POST" path:@"/v1/activity" capability:nil
                  handler:^DSHHostBridgeResponse *(DSHHostBridgeRequest *request) {
        NSArray *events = request.json[@"events"];
        if (![events isKindOfClass:NSArray.class])
            return [DSHHostBridgeResponse errorWithStatus:400 code:@"invalid_request"
                                                  message:@"send {\"events\": [...]}"
                                              recoverable:NO];
        NSUInteger accepted = 0;
        for (NSDictionary *event in events) {
            if (accepted >= kMaxBatch)
                break;
            if (![event isKindOfClass:NSDictionary.class])
                continue;
            NSString *name = event[@"name"];
            if (![name isKindOfClass:NSString.class] || name.length == 0)
                continue;
            NSString *status = event[@"outcome"];
            DSHActivityOutcome outcome = DSHActivityOutcomeOK;
            if ([status isEqualToString:@"error"]) outcome = DSHActivityOutcomeError;
            else if ([status isEqualToString:@"refused"]) outcome = DSHActivityOutcomeRefused;
            else if ([status isEqualToString:@"declined"]) outcome = DSHActivityOutcomeDeclined;
            else if ([status isEqualToString:@"started"]) outcome = DSHActivityOutcomeStarted;

            [DSHActivityLog.shared recordSource:DSHActivitySourceGuestTool
                                           name:name
                                         detail:[event[@"detail"] isKindOfClass:NSString.class] ? event[@"detail"] : nil
                                         result:[event[@"result"] isKindOfClass:NSString.class] ? event[@"result"] : nil
                                        outcome:outcome
                                       duration:DSHGuestDuration(event[@"duration"])
                                  correlationID:[event[@"id"] isKindOfClass:NSString.class] ? event[@"id"] : nil];
            accepted += 1;
        }
        return [DSHHostBridgeResponse ok:@{ @"accepted": @(accepted) }];
    }];
}

@end

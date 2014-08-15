//
//  SWUserAgent.m
//  swig
//
//  Created by Pierre-Marc Airoldi on 2014-08-15.
//  Copyright (c) 2014 PeteAppDesigns. All rights reserved.
//

#import "SWUserAgent.h"
#import "Swig.h"

@implementation SWUserAgent

static SWUserAgent *SINGLETON = nil;

static bool isFirstAccess = YES;

#pragma mark - Public Method

+ (id)sharedInstance
{
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        isFirstAccess = NO;
        SINGLETON = [[super allocWithZone:NULL] init];    
    });
    
    return SINGLETON;
}

#pragma mark - Life Cycle

+ (id) allocWithZone:(NSZone *)zone
{
    return [self sharedInstance];
}

+ (id)copyWithZone:(struct _NSZone *)zone
{
    return [self sharedInstance];
}

+ (id)mutableCopyWithZone:(struct _NSZone *)zone
{
    return [self sharedInstance];
}

- (id)copy
{
    return [[SWUserAgent alloc] init];
}

- (id)mutableCopy
{
    return [[SWUserAgent alloc] init];
}

- (id) init
{
    if(SINGLETON){
        return SINGLETON;
    }
    if (isFirstAccess) {
        [self doesNotRecognizeSelector:_cmd];
    }
    
    self = [super init];
    
    if (!self) {
        return nil;
    }
    
    SWTransportConfiguration *config1 = [[SWTransportConfiguration alloc] initWithTransportType:PJSIP_TRANSPORT_UDP];
    
    SWTransportConfiguration *config2 = [[SWTransportConfiguration alloc] initWithTransportType:PJSIP_TRANSPORT_TCP];
    
    SWEndpoint *endpoint = [[SWEndpoint alloc] init];
    endpoint.transportConfigurations = @[config1, config2];
    
    [endpoint begin];
    
    SWAccount *account = [SWAccount new];
    
    return self;
}

-(SWAccount *)accountFromIdentifier:(NSInteger)accountId {
    
    return [SWAccount new];
}


@end
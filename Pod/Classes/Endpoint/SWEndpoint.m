//
//  SWEndpoint.m
//  swig
//
//  Created by Pierre-Marc Airoldi on 2014-08-20.
//  Copyright (c) 2014 PeteAppDesigns. All rights reserved.
//

#import <UIKit/UIKit.h>

#import "SWEndpoint.h"
#import "SWTransportConfiguration.h"
#import "SWEndpointConfiguration.h"
#import "SWAccount.h"
#import "SWCall.h"
#import "pjsua.h"
#import "NSString+PJString.h"
#import <AFNetworkReachabilityManager.h>
#import <AVFoundation/AVFoundation.h>
#import <AudioToolbox/AudioToolbox.h>
#import <libextobjc/extobjc.h>
#import "Logger.h"

#define KEEP_ALIVE_INTERVAL 600

typedef void (^SWAccountStateChangeBlock)(SWAccount *account);
typedef void (^SWIncomingCallBlock)(SWAccount *account, SWCall *call);
typedef void (^SWOnReinviteBlock)(SWAccount *account, SWCall *call);
typedef void (^SWCallStateChangeBlock)(SWAccount *account, SWCall *call);
typedef void (^SWCallMediaStateChangeBlock)(SWAccount *account, SWCall *call);

//thread statics
static pj_thread_t *thread;

//callback functions

static void SWOnIncomingCall(pjsua_acc_id acc_id, pjsua_call_id call_id, pjsip_rx_data *rdata);
static void SWOnReinvite(pjsua_call_id call_id, pjsua_call_info *call_info);

static void SWOnCallMediaState(pjsua_call_id call_id);

static void SWOnCallState(pjsua_call_id call_id, pjsip_event *e);

static void SWOnCallTransferStatus(pjsua_call_id call_id, int st_code, const pj_str_t *st_text, pj_bool_t final, pj_bool_t *p_cont);

static void SWOnCallReplaced(pjsua_call_id old_call_id, pjsua_call_id new_call_id);

static void SWOnRegState(pjsua_acc_id acc_id);

static void SWOnNatDetect(const pj_stun_nat_detect_result *res);

@interface SWEndpoint ()

@property (nonatomic, copy) SWIncomingCallBlock incomingCallBlock;
@property (nonatomic, copy) SWOnReinviteBlock reinviteBlock;
@property (nonatomic, copy) SWAccountStateChangeBlock accountStateChangeBlock;
@property (nonatomic, copy) SWCallStateChangeBlock callStateChangeBlock;
@property (nonatomic, copy) SWCallMediaStateChangeBlock callMediaStateChangeBlock;
@property (nonatomic) pj_thread_t *thread;
@property (nonatomic) pjsua_transport_id transportId;
@end

@implementation SWEndpoint

static SWEndpoint *_sharedEndpoint = nil;

+(id)sharedEndpoint {
    
    static dispatch_once_t onceToken;
    
    dispatch_once(&onceToken, ^{
        _sharedEndpoint = [self new];
    });
    
    return _sharedEndpoint;
}

-(instancetype)init {
    
    if (_sharedEndpoint) {
        return _sharedEndpoint;
    }
    
    self = [super init];
    
    if (!self) {
        return nil;
    }
    
    [[UIApplication sharedApplication] beginReceivingRemoteControlEvents];
    
    [DDLog addLogger:[DDASLLogger sharedInstance]];
    [DDLog addLogger:[DDTTYLogger sharedInstance]];
    
    DDFileLogger *fileLogger = [[DDFileLogger alloc] init];
    fileLogger.rollingFrequency = 0;
    fileLogger.maximumFileSize = 0;
    
    [DDLog addLogger:fileLogger];
    
    _accounts = [[NSMutableArray alloc] init];
    
    [self registerThread];
    
    NSURL *fileURL = [[NSBundle mainBundle] URLForResource:@"Ringtone" withExtension:@"aif"];
    
    _ringtone = [[SWRingtone alloc] initWithFileAtPath:fileURL];
    
    //TODO check if the reachability happens in background
    //FIX make sure connect doesnt get called too often
    //IP Change logic
    
    [[AFNetworkReachabilityManager sharedManager] setReachabilityStatusChangeBlock:^(AFNetworkReachabilityStatus status) {
        
        if ([AFNetworkReachabilityManager sharedManager].reachableViaWiFi) {
            
            [self performSelectorOnMainThread:@selector(keepAlive) withObject:nil waitUntilDone:YES];
        }
        
        else if ([AFNetworkReachabilityManager sharedManager].reachableViaWWAN) {
            [self performSelectorOnMainThread:@selector(keepAlive) withObject:nil waitUntilDone:YES];
        }
        
        else {
            //offline
        }
    }];
    
    
    [[AFNetworkReachabilityManager sharedManager] startMonitoring];
    
    [[NSNotificationCenter defaultCenter] addObserver:self selector: @selector(handleEnteredBackground:) name: UIApplicationDidEnterBackgroundNotification object:nil];
    
    [[NSNotificationCenter defaultCenter] addObserver:self selector: @selector(handleApplicationWillTeminate:) name:UIApplicationWillTerminateNotification object:nil];
    
    return self;
}

-(void)dealloc {
    
    [[NSNotificationCenter defaultCenter] removeObserver:self name:UIApplicationDidEnterBackgroundNotification object:nil];
    
    [[NSNotificationCenter defaultCenter] removeObserver:self name:UIApplicationWillTerminateNotification object:nil];
    
    [self reset:^(NSError *error) {
        if (error) DDLogDebug(@"%@", [error description]);
    }];
}

#pragma Notification Methods

-(void)handleEnteredBackground:(NSNotification *)notification {
    
    UIApplication *application = (UIApplication *)notification.object;
    
    [[UIApplication sharedApplication] beginBackgroundTaskWithExpirationHandler:NULL];
    [[UIApplication sharedApplication] beginReceivingRemoteControlEvents];
    
    self.ringtone.volume = 0.0;
    
    [self performSelectorOnMainThread:@selector(keepAlive) withObject:nil waitUntilDone:YES];
    
    [application setKeepAliveTimeout:KEEP_ALIVE_INTERVAL handler: ^{
        [self performSelectorOnMainThread:@selector(keepAlive) withObject:nil waitUntilDone:YES];
    }];
}

-(void)handleApplicationWillTeminate:(NSNotification *)notification {
    
    UIApplication *application = (UIApplication *)notification.object;
    
    //TODO hangup all calls
    //TODO remove all accounts
    //TODO close all transports
    //TODO reset endpoint
    
    for (int i = 0; i < [self.accounts count]; ++i) {
        
        SWAccount *account = [self.accounts objectAtIndex:i];
        
        dispatch_semaphore_t semaphone = dispatch_semaphore_create(0);
        
        @weakify(account);
        [account disconnect:^(NSError *error) {
            
            @strongify(account);
            account = nil;
            
            dispatch_semaphore_signal(semaphone);
        }];
        
        dispatch_semaphore_wait(semaphone, DISPATCH_TIME_FOREVER);
    }
    
    NSMutableArray *mutableAccounts = [self.accounts mutableCopy];
    
    [mutableAccounts removeAllObjects];
    
    self.accounts = mutableAccounts;
    
    [self reset:^(NSError *error) {
        
        if (error) {
            DDLogDebug(@"%@", [error description]);
        }
    }];
    
    [application setApplicationIconBadgeNumber:0];
}

-(void)keepAlive {
    
    if (pjsua_get_state() != PJSUA_STATE_RUNNING) {
        return;
    }
    
    [self registerThread];
    
    for (SWAccount *account in self.accounts) {
        
        if (account.isValid) {
            
            dispatch_semaphore_t semaphone = dispatch_semaphore_create(0);
            
            [account connect:^(NSError *error) {
                
                dispatch_semaphore_signal(semaphone);
            }];
            
            dispatch_semaphore_wait(semaphone, DISPATCH_TIME_FOREVER);
        }
        
        else {
            
            dispatch_semaphore_t semaphone = dispatch_semaphore_create(0);
            
            [account disconnect:^(NSError *error) {
                
                dispatch_semaphore_signal(semaphone);
            }];
            
            dispatch_semaphore_wait(semaphone, DISPATCH_TIME_FOREVER);
        }
    }
}

#pragma Endpoint Methods

-(void)setEndpointConfiguration:(SWEndpointConfiguration *)endpointConfiguration {
    
    [self willChangeValueForKey:@"endpointConfiguration"];
    _endpointConfiguration = endpointConfiguration;
    [self didChangeValueForKey:@"endpointConfiguration"];
}

-(void)setRingtone:(SWRingtone *)ringtone {
    
    [self willChangeValueForKey:@"ringtone"];
    
    if (_ringtone.isPlaying) {
        [_ringtone stop];
        _ringtone = ringtone;
        [_ringtone start];
    }
    
    else {
        _ringtone = ringtone;
    }
    
    [self didChangeValueForKey:@"ringtone"];
}

-(void)configure:(SWEndpointConfiguration *)configuration completionHandler:(void(^)(NSError *error))handler {
    
    //TODO add lock to this method
    
    self.endpointConfiguration = configuration;
    
    pj_status_t status;
    
    status = pjsua_create();
    
    if (status != PJ_SUCCESS) {
        
        NSError *error = [NSError errorWithDomain:@"Error creating pjsua" code:status userInfo:nil];
        
        if (handler) {
            handler(error);
        }
        
        return;
    }
    
    pjsua_config ua_cfg;
    pjsua_logging_config log_cfg;
    pjsua_media_config media_cfg;
    
    pjsua_config_default(&ua_cfg);
    pjsua_logging_config_default(&log_cfg);
    pjsua_media_config_default(&media_cfg);
    
    ua_cfg.cb.on_call_rx_offer = &SWOnReinvite;
//    ua_cfg.cb.on_call_rx_reinvite = &SWOnReinvite;
    ua_cfg.cb.on_incoming_call = &SWOnIncomingCall;
    ua_cfg.cb.on_call_media_state = &SWOnCallMediaState;
    ua_cfg.cb.on_call_state = &SWOnCallState;
    ua_cfg.cb.on_call_transfer_status = &SWOnCallTransferStatus;
    ua_cfg.cb.on_call_replaced = &SWOnCallReplaced;
    ua_cfg.cb.on_reg_state = &SWOnRegState;
    ua_cfg.cb.on_nat_detect = &SWOnNatDetect;
    ua_cfg.max_calls = (unsigned int)self.endpointConfiguration.maxCalls;
    
    log_cfg.level = (unsigned int)self.endpointConfiguration.logLevel;
    log_cfg.console_level = (unsigned int)self.endpointConfiguration.logConsoleLevel;
    log_cfg.log_filename = [self.endpointConfiguration.logFilename pjString];
    log_cfg.log_file_flags = (unsigned int)self.endpointConfiguration.logFileFlags;
    
    media_cfg.clock_rate = (unsigned int)self.endpointConfiguration.clockRate;
    media_cfg.snd_clock_rate = (unsigned int)self.endpointConfiguration.sndClockRate;
    
    status = pjsua_init(&ua_cfg, &log_cfg, &media_cfg);
    
    if (status != PJ_SUCCESS) {
        
        NSError *error = [NSError errorWithDomain:@"Error initializing pjsua" code:status userInfo:nil];
        
        if (handler) {
            handler(error);
        }
        
        return;
    }
    
    //TODO autodetect port by checking transportId!!!!
    
    for (SWTransportConfiguration *transport in self.endpointConfiguration.transportConfigurations) {
        
        pjsua_transport_config transportConfig;
        pjsua_transport_id transportId;
        
        pjsua_transport_config_default(&transportConfig);
        
        pjsip_transport_type_e transportType = (pjsip_transport_type_e)transport.transportType;
        
        status = pjsua_transport_create(transportType, &transportConfig, &transportId);
        self.transportId = transportId;
        
        if (status != PJ_SUCCESS) {
            
            NSError *error = [NSError errorWithDomain:@"Error creating pjsua transport" code:status userInfo:nil];
            
            if (handler) {
                handler(error);
            }
            
            return;
        }
    }
    
    [self start:handler];
}

-(void)changeTransportConfiguration: (void(^)(NSError *error))handler {
    pjsua_transport_close(self.transportId, false);
    
    for (SWTransportConfiguration *transport in self.endpointConfiguration.transportConfigurations) {
        pj_status_t status;
        pjsua_transport_config transportConfig;
        pjsua_transport_id transportId;
        
        pjsua_transport_config_default(&transportConfig);
        
        pjsip_transport_type_e transportType = (pjsip_transport_type_e)transport.transportType;
        
        status = pjsua_transport_create(transportType, &transportConfig, &transportId);
        self.transportId = transportId;
        
        if (status != PJ_SUCCESS) {
            
            NSError *error = [NSError errorWithDomain:@"Error creating pjsua transport" code:status userInfo:nil];
            
            if (handler) {
                handler(error);
            }
        }
    }
}

-(BOOL)hasTCPConfiguration {
    
    NSUInteger index = [self.endpointConfiguration.transportConfigurations indexOfObjectPassingTest:^BOOL(SWTransportConfiguration *obj, NSUInteger idx, BOOL *stop) {
        
        if (obj.transportType == SWTransportTypeTCP || obj.transportType == SWTransportTypeTCP6) {
            return YES;
            *stop = YES;
        }
        
        else {
            return NO;
        }
    }];
    
    if (index == NSNotFound) {
        return NO;
    }
    
    else {
        return YES;
    }
}

-(void)registerThread {
    
    if (pjsua_get_state() != PJSUA_STATE_RUNNING) {
        return;
    }
    
    if (!pj_thread_is_registered()) {
        pj_thread_register("swig", NULL, &thread);
    }
    
    else {
        thread = pj_thread_this();
    }
    
    if (!_pjPool) {
        dispatch_async(dispatch_get_main_queue(), ^{
            _pjPool = pjsua_pool_create("swig-pjsua", 512, 512);
        });
    }
}

-(void)start:(void(^)(NSError *error))handler {
    
    pj_status_t status = pjsua_start();
    
    if (status != PJ_SUCCESS) {
        
        NSError *error = [NSError errorWithDomain:@"Error starting pjsua" code:status userInfo:nil];
        
        if (handler) {
            handler(error);
        }
        
        return;
    }
    
    if (handler) {
        handler(nil);
    }
}

-(void)reset:(void(^)(NSError *error))handler {
    
    //TODO shutdown agent correctly. stop all calls, destroy all accounts
    
    for (SWAccount *account in self.accounts) {
        
        [account endAllCalls];
        
        dispatch_semaphore_t sema = dispatch_semaphore_create(0);
        
        [account disconnect:^(NSError *error) {
            dispatch_semaphore_signal(sema);
        }];
        
        dispatch_semaphore_wait(sema, DISPATCH_TIME_FOREVER);
    }
    
//    NSMutableArray *mutableArray = [self.accounts mutableCopy];
//    
//    [mutableArray removeAllObjects];
//    
//    self.accounts = mutableArray;
    
//    pj_status_t status = pjsua_destroy();
//    
//    if (status != PJ_SUCCESS) {
//        
//        NSError *error = [NSError errorWithDomain:@"Error destroying pjsua" code:status userInfo:nil];
//        
//        if (handler) {
//            handler(error);
//        }
//        
//        return;
//    }
//    
//    if (handler) {
//        handler(nil);
//    }    
}

#pragma Account Management

-(void)addAccount:(SWAccount *)account {
    
    if (![self lookupAccount:account.accountId]) {
        
        NSMutableArray *mutableArray = [self.accounts mutableCopy];
        [mutableArray addObject:account];
        
        self.accounts = mutableArray;
    }
}

-(void)removeAccount:(SWAccount *)account completion:(void(^)(void))handler {
 
    if ([self lookupAccount:account.accountId]) {
    
        NSMutableArray *mutableArray = [self.accounts mutableCopy];
        [mutableArray removeObject:account];
        
        self.accounts = mutableArray;
        handler();
    }
}

-(SWAccount *)lookupAccount:(NSInteger)accountId {
    
    NSUInteger accountIndex = [self.accounts indexOfObjectPassingTest:^BOOL(id obj, NSUInteger idx, BOOL *stop) {
        
        SWAccount *account = (SWAccount *)obj;
        
        if (account.accountId == accountId && account.accountId != PJSUA_INVALID_ID) {
            return YES;
        }
        
        return NO;
    }];
    
    if (accountIndex != NSNotFound) {
        return [self.accounts objectAtIndex:accountIndex]; //TODO add more management
    }
    
    else {
        return nil;
    }
}
-(SWAccount *)firstAccount {
    
    if (self.accounts.count > 0) {
        return self.accounts[0];
    }
    
    else {
        return nil;
    }
}

#pragma Block Parameters

-(void)setAccountStateChangeBlock:(void(^)(SWAccount *account))accountStateChangeBlock {
    
    _accountStateChangeBlock = accountStateChangeBlock;
}

-(void)setIncomingCallBlock:(void(^)(SWAccount *account, SWCall *call))incomingCallBlock {
    
    _incomingCallBlock = incomingCallBlock;
}
-(void)setReinviteBlock:(void(^)(SWAccount *account, SWCall *call))reinviteBlock {
    
    _reinviteBlock = reinviteBlock;
}

-(void)setCallStateChangeBlock:(void(^)(SWAccount *account, SWCall *call))callStateChangeBlock {
    
    _callStateChangeBlock = callStateChangeBlock;
}

-(void)setCallMediaStateChangeBlock:(void(^)(SWAccount *account, SWCall *call))callMediaStateChangeBlock {
    
    _callMediaStateChangeBlock = callMediaStateChangeBlock;
}

#pragma PJSUA Callbacks

static void SWOnRegState(pjsua_acc_id acc_id) {
    
    SWAccount *account = [[SWEndpoint sharedEndpoint] lookupAccount:acc_id];
    
    if (account) {
        
        [account accountStateChanged];
        
        if ([SWEndpoint sharedEndpoint].accountStateChangeBlock) {
            [SWEndpoint sharedEndpoint].accountStateChangeBlock(account);
        }
        
        if (account.accountState == SWAccountStateDisconnected) {
            [[SWEndpoint sharedEndpoint] removeAccount:account completion:^{
                
            }];
        }
    }
}

static void SWOnIncomingCall(pjsua_acc_id acc_id, pjsua_call_id call_id, pjsip_rx_data *rdata) {
    
    SWAccount *account = [[SWEndpoint sharedEndpoint] lookupAccount:acc_id];
    
    if (account) {
        
        SWCall *call = [SWCall callWithId:call_id accountId:acc_id inBound:YES];
        
        if (call) {
            
            [account addCall:call];
            
            [call callStateChanged];
            
            if ([SWEndpoint sharedEndpoint].incomingCallBlock) {
                [SWEndpoint sharedEndpoint].incomingCallBlock(account, call);
            }
        }
    }
}

static void SWOnReinvite(pjsua_call_id call_id, pjsua_call_info *call_info) {
    pjsua_call_info callInfo;
    pjsua_call_get_info(call_id, &callInfo);
    
    SWAccount *account = [[SWEndpoint sharedEndpoint] lookupAccount:callInfo.acc_id];
    
    if (account) {
        
        SWCall *call = [account lookupCall:call_id];
        
        if (call) {
            
            if ([SWEndpoint sharedEndpoint].reinviteBlock) {
                [SWEndpoint sharedEndpoint].reinviteBlock(account, call);
//                pjmedia_sdp_session sdp;
//                pjsua_call_answer_with_sdp(call_id, &sdp, NULL, 400, NULL, NULL);
            }
        }
    }
}

static void SWOnCallState(pjsua_call_id call_id, pjsip_event *e) {
    
    pjsua_call_info callInfo;
    pjsua_call_get_info(call_id, &callInfo);
    
    SWAccount *account = [[SWEndpoint sharedEndpoint] lookupAccount:callInfo.acc_id];
    
    if (account) {
        
        SWCall *call = [account lookupCall:call_id];
        
        if (call) {
            
            [call callStateChanged];
            
            if ([SWEndpoint sharedEndpoint].callStateChangeBlock) {
                [SWEndpoint sharedEndpoint].callStateChangeBlock(account, call);
            }
            
            if (call.callState == SWCallStateDisconnected) {
                [account removeCall:call.callId];
            }
        }
    }
}

static void SWOnCallMediaState(pjsua_call_id call_id) {
    
    pjsua_call_info callInfo;
    pjsua_call_get_info(call_id, &callInfo);
    
    SWAccount *account = [[SWEndpoint sharedEndpoint] lookupAccount:callInfo.acc_id];
    
    if (account) {
        
        SWCall *call = [account lookupCall:call_id];
        
        if (call) {
            
            [call mediaStateChanged];
            
            if ([SWEndpoint sharedEndpoint].callMediaStateChangeBlock) {
                [SWEndpoint sharedEndpoint].callMediaStateChangeBlock(account, call);
            }
        }
    }
}

//TODO: implement these
static void SWOnCallTransferStatus(pjsua_call_id call_id, int st_code, const pj_str_t *st_text, pj_bool_t final, pj_bool_t *p_cont) {
    
}

static void SWOnCallReplaced(pjsua_call_id old_call_id, pjsua_call_id new_call_id) {
    
}

static void SWOnNatDetect(const pj_stun_nat_detect_result *res){
    
}

#pragma Setters/Getters

-(void)setPjPool:(pj_pool_t *)pjPool {
    
    _pjPool = pjPool;
}

-(void)setAccounts:(NSArray *)accounts {
    
    [self willChangeValueForKey:@"accounts"];
    _accounts = accounts;
    [self didChangeValueForKey:@"accounts"];
}

@end

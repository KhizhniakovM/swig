//
//  SWAccount.m
//  swig
//
//  Created by Pierre-Marc Airoldi on 2014-08-21.
//  Copyright (c) 2014 PeteAppDesigns. All rights reserved.
//

#import "SWAccount.h"
#import "SWAccountConfiguration.h"
#import "SWEndpoint.h"
#import "SWCall.h"
#import "SWUriFormatter.h"
#import "NSString+PJString.h"

#import "pjsua.h"

#define kRegTimeout 800

@interface SWAccount ()

@property (nonatomic, strong) SWAccountConfiguration *configuration;
@property (nonatomic, strong) NSMutableArray *calls;
@property (nonatomic) pjsua_call_id *callID;

@end

@implementation SWAccount

-(instancetype)init {
    
    self = [super init];
    
    if (!self) {
        return nil;
    }
    
    _calls = [NSMutableArray new];
    
    return self;
}

-(void)dealloc {
    
}

-(void)setAccountId:(NSInteger)accountId {
    
    _accountId = accountId;
}

-(void)setAccountState:(SWAccountState)accountState {
    
    [self willChangeValueForKey:@"accountState"];
    _accountState = accountState;
    [self didChangeValueForKey:@"accountState"];
}

-(void)setAccountConfiguration:(SWAccountConfiguration *)accountConfiguration {
    
    [self willChangeValueForKey:@"accountConfiguration"];
    _accountConfiguration = accountConfiguration;
    [self didChangeValueForKey:@"accountConfiguration"];
}

- (void)configureAudio {
    const pj_str_t codec_id = {"opus", 4};
    pjmedia_codec_param param;
    pjmedia_codec_opus_config opus_cfg;
    
    pjsua_codec_get_param(&codec_id, &param);
    pjmedia_codec_opus_get_config(&opus_cfg);
    
    pjmedia_codec_opus_set_default_param(&opus_cfg, &param);
}

-(void)configure:(SWAccountConfiguration *)configuration completionHandler:(void(^)(NSError *error))handler {
    
    self.accountConfiguration = configuration;
    
    if (!self.accountConfiguration.address) {
        self.accountConfiguration.address = [SWAccountConfiguration addressFromUsername:self.accountConfiguration.username domain:self.accountConfiguration.domain];
    }
    
    NSString *tcpSuffix = @"";
    
    if ([[SWEndpoint sharedEndpoint] hasTCPConfiguration]) {
        tcpSuffix = @";transport=TCP";
    }
    
    pjsua_acc_config acc_cfg;
    pjsua_acc_config_default(&acc_cfg);
    
    acc_cfg.id = [[SWUriFormatter sipUri:[self.accountConfiguration.address stringByAppendingString:tcpSuffix] withDisplayName:self.accountConfiguration.displayName] pjString];
    acc_cfg.reg_uri = [[SWUriFormatter sipUri:[self.accountConfiguration.domain stringByAppendingString:tcpSuffix]] pjString];
    acc_cfg.register_on_acc_add = self.accountConfiguration.registerOnAdd ? PJ_TRUE : PJ_FALSE;
    acc_cfg.publish_enabled = self.accountConfiguration.publishEnabled ? PJ_TRUE : PJ_FALSE;
    acc_cfg.reg_timeout = kRegTimeout;
    
    acc_cfg.cred_count = 1;
    acc_cfg.cred_info[0].scheme = [self.accountConfiguration.authScheme pjString];
    acc_cfg.cred_info[0].realm = [self.accountConfiguration.authRealm pjString];
    acc_cfg.cred_info[0].username = [self.accountConfiguration.username pjString];
    acc_cfg.cred_info[0].data_type = PJSIP_CRED_DATA_PLAIN_PASSWD;
    acc_cfg.cred_info[0].data = [self.accountConfiguration.password pjString];
    
    //==========
    acc_cfg.vid_in_auto_show = PJ_TRUE;
    acc_cfg.vid_out_auto_transmit = PJ_TRUE;
    //==================================================
    
    [self configureVideo];
    
    // OPUS
    //==================================================
    [self configureAudio];
    //==================================================
    
    if (!self.accountConfiguration.proxy) {
        acc_cfg.proxy_cnt = 0;
    } else {
        acc_cfg.proxy_cnt = 1;
        acc_cfg.proxy[0] = [[SWUriFormatter sipUri:[self.accountConfiguration.proxy stringByAppendingString:tcpSuffix]] pjString];
    }
    
    pj_status_t status;
    
    int accountId = (int)self.accountId;
    
    status = pjsua_acc_add(&acc_cfg, PJ_TRUE, &accountId);
    
    if (status != PJ_SUCCESS) {
        
        NSError *error = [NSError errorWithDomain:@"Error adding account" code:status userInfo:nil];
        
        if (handler) {
            handler(error);
        }
        
        return;
    }
    
    else {
        [[SWEndpoint sharedEndpoint] addAccount:self];
    }
    
    if (!self.accountConfiguration.registerOnAdd) {
        [self connect:handler];
    }
    
    else {
        
        if (handler) {
            handler(nil);
        }
    }
}

-(void)modify:(SWAccountConfiguration *)configuration completionHandler:(void(^)(NSError *error))handler {
    self.accountConfiguration = configuration;
    
    NSString *tcpSuffix = @"";
    
    if ([[SWEndpoint sharedEndpoint] hasTCPConfiguration]) {
        tcpSuffix = @";transport=TCP";
    }
    
    pjsua_acc_config acc_cfg;
    pjsua_acc_config_default(&acc_cfg);
    
    acc_cfg.id = [[SWUriFormatter sipUri:[self.accountConfiguration.address stringByAppendingString:tcpSuffix] withDisplayName:self.accountConfiguration.displayName] pjString];
    acc_cfg.reg_uri = [[SWUriFormatter sipUri:[self.accountConfiguration.domain stringByAppendingString:tcpSuffix]] pjString];
    acc_cfg.register_on_acc_add = self.accountConfiguration.registerOnAdd ? PJ_TRUE : PJ_FALSE;;
    acc_cfg.publish_enabled = self.accountConfiguration.publishEnabled ? PJ_TRUE : PJ_FALSE;
    acc_cfg.reg_timeout = kRegTimeout;
    
    acc_cfg.cred_count = 1;
    acc_cfg.cred_info[0].scheme = [self.accountConfiguration.authScheme pjString];
    acc_cfg.cred_info[0].realm = [self.accountConfiguration.authRealm pjString];
    acc_cfg.cred_info[0].username = [self.accountConfiguration.username pjString];
    acc_cfg.cred_info[0].data_type = PJSIP_CRED_DATA_PLAIN_PASSWD;
    acc_cfg.cred_info[0].data = [self.accountConfiguration.password pjString];
    
    pj_status_t status;
    status = pjsua_acc_modify(_accountId, &acc_cfg);
    
    if (status != PJ_SUCCESS) {
        
        NSError *error = [NSError errorWithDomain:@"Error adding account" code:status userInfo:nil];
        
        if (handler) {
            handler(error);
        }
        
        return;
    }
}
-(void)connect:(void(^)(NSError *error))handler {
    
    //FIX: registering too often will cause the server to possibly return error
        
    pj_status_t status;
    
    status = pjsua_acc_set_registration((int)self.accountId, PJ_TRUE);
    
    if (status != PJ_SUCCESS) {
        
        NSError *error = [NSError errorWithDomain:@"Error setting registration" code:status userInfo:nil];
        
        if (handler) {
            handler(error);
        }
        
        return;
    }
    
    status = pjsua_acc_set_online_status((int)self.accountId, PJ_TRUE);
    
    if (status != PJ_SUCCESS) {
        
        NSError *error = [NSError errorWithDomain:@"Error setting online status" code:status userInfo:nil];
        
        if (handler) {
            handler(error);
        }
        
        return;
    }
    
    if (handler) {
        handler(nil);
    }
}

-(void)disconnect:(void(^)(NSError *error))handler {
    
    pj_status_t status;
    
    status = pjsua_acc_set_online_status((int)self.accountId, PJ_FALSE);
    
    if (status != PJ_SUCCESS) {
        
        NSError *error = [NSError errorWithDomain:@"Error setting online status" code:status userInfo:nil];
        
        if (handler) {
            handler(error);
        }
        
        return;
    }
    
    status = pjsua_acc_set_registration((int)self.accountId, PJ_FALSE);
    
    if (status != PJ_SUCCESS) {
        
        NSError *error = [NSError errorWithDomain:@"Error setting registration" code:status userInfo:nil];
        
        if (handler) {
            handler(error);
        }
        
        return;
    }
    
    if (handler) {
        handler(nil);
    }
    
    
    pjsua_acc_del((int)self.accountId);
}

-(void)accountStateChanged {
    
    pjsua_acc_info accountInfo;
    pjsua_acc_get_info((int)self.accountId, &accountInfo);
    
    pjsip_status_code code = accountInfo.status;
    
    //TODO make status offline/online instead of offline/connect
    //status would be disconnected, online, and offline, isConnected could return true if online/offline
    
    if (code == 0 || accountInfo.expires == -1) {
        self.accountState = SWAccountStateDisconnected;
    }
    
    else if (PJSIP_IS_STATUS_IN_CLASS(code, 100) || PJSIP_IS_STATUS_IN_CLASS(code, 300)) {
        self.accountState = SWAccountStateConnecting;
    }
    
    else if (PJSIP_IS_STATUS_IN_CLASS(code, 200)) {
        self.accountState = SWAccountStateConnected;
    }
    
    else {
        self.accountState = SWAccountStateDisconnected;
    }
}

-(BOOL)isValid {
    
    return pjsua_acc_is_valid((int)self.accountId);
}

#pragma Call Management

-(void)addCall:(SWCall *)call {
    
    [self.calls addObject:call];
    
    //TODO:: setup blocks
}

-(void)removeCall:(NSUInteger)callId {
    
    SWCall *call = [self lookupCall:callId];
    
    if (call) {
        [self.calls removeObject:call];
    }
    
    call = nil;
}

-(SWCall *)lookupCall:(NSInteger)callId {
    
    NSUInteger callIndex = [self.calls indexOfObjectPassingTest:^BOOL(id obj, NSUInteger idx, BOOL *stop) {
        
        SWCall *call = (SWCall *)obj;
        
        if (call.callId == callId && call.callId != PJSUA_INVALID_ID) {
            return YES;
        }
        
        return NO;
    }];
    
    if (callIndex != NSNotFound) {
        return [self.calls objectAtIndex:callIndex]; //TODO add more management
    }
    
    else {
        return nil;
    }
}

-(SWCall *)firstCall {
    
    if (self.calls.count > 0) {
        return self.calls[0];
    }
    
    else {
        return nil;
    }
}

-(void)endAllCalls {
    
    for (SWCall *call in self.calls) {
        [call hangup:nil];
    }
}

-(void)makeCall:(NSString *)URI completionHandler:(void(^)(NSError *error))handler {
    
    pj_status_t status;
    NSError *error;
    
    pjsua_call_id callIdentifier;
    _callID = callIdentifier;
    pj_str_t uri = [[SWUriFormatter sipUri:URI fromAccount:self] pjString];
    
    pjsua_call_setting callSettings;
    pjsua_call_setting_default(&callSettings);
    callSettings.aud_cnt = 1;
    callSettings.vid_cnt = 0;
    
    status = pjsua_call_make_call((int)self.accountId, &uri, &callSettings, NULL, NULL, &callIdentifier);
    
    if (status != PJ_SUCCESS) {
        
        error = [NSError errorWithDomain:@"Error hanging up call" code:0 userInfo:nil];
    }
    
    else {
        
        SWCall *call = [SWCall callWithId:callIdentifier accountId:self.accountId inBound:NO];
        
        [self addCall:call];
    }
    
    if (handler) {
        handler(error);
    }
}

-(void)makeVideoCall:(NSString *)URI completionHandler:(void(^)(NSError *error))handler {
    pj_status_t status;
    NSError *error;
    
    pjsua_call_id callIdentifier;
    pj_str_t uri = [[SWUriFormatter sipUri:URI fromAccount:self] pjString];
    
    pjsua_call_setting callSettings;
    pjsua_call_setting_default(&callSettings);
    callSettings.aud_cnt = 1;
    callSettings.vid_cnt = 1;
    
    status = pjsua_call_make_call((int)self.accountId, &uri, &callSettings, NULL, NULL, &callIdentifier);
    
    if (status != PJ_SUCCESS) {
        error = [NSError errorWithDomain:@"Error hanging up call" code:0 userInfo:nil];
    } else {
        SWCall *call = [SWCall callWithId:callIdentifier accountId:self.accountId inBound:NO];
        call.isVideo = true;
        call.outgoingVideo = YES;
        [self addCall:call];
        self.callID = callIdentifier;
    }
    
    if (handler) {
        handler(error);
    }
}

- (void)configureVideo {

    pj_pool_factory pf;
    pjmedia_codec_openh264_vid_init(NULL, &pf);
    
    const pj_str_t codec_id = {"H264", 4};
    int bitrate;
    pjmedia_vid_codec_param param;
    pjsua_vid_codec_get_param(&codec_id, &param);
    param.enc_fmt.det.vid.size.w = 640; //656x656
    param.enc_fmt.det.vid.size.h = 480;
    param.enc_fmt.det.vid.fps.num = 25;
    param.enc_fmt.det.vid.fps.denum = 1;

    bitrate = 1000 * atoi("512");
    param.enc_fmt.det.vid.avg_bps = bitrate;
    param.enc_fmt.det.vid.max_bps = bitrate;

    param.dec_fmt.det.vid.size.w = 640;
    param.dec_fmt.det.vid.size.h = 480;
    param.dec_fmt.det.vid.fps.num = 25;
    param.dec_fmt.det.vid.fps.denum = 1;

    param.dec_fmtp.cnt = 2;
    param.dec_fmtp.param[0].name = pj_str("profile-level-id");
    param.dec_fmtp.param[0].val = pj_str("42e01e");
    param.dec_fmtp.param[1].name = pj_str("packetization-mode");
    param.dec_fmtp.param[1].val = pj_str("1");

//    param.dec_fmtp.param[2].name = pj_str("mode-set");
//    param.dec_fmtp.param[2].val  = pj_str("6,7");
//    param.dec_fmtp.param[2].name = pj_str("octet-align");
//    param.dec_fmtp.param[2].val  = pj_str("0");
//    param.dec_fmtp.param[2].name = pj_str("mode");
//    param.dec_fmtp.param[2].val  = pj_str("20");
//    param.dec_fmtp.param[2].name = pj_str("annexb");
//    param.dec_fmtp.param[2].val  = pj_str("no");
    
    pjsua_vid_codec_set_param(&codec_id, &param);
    
    pjmedia_orient currentOrientation = PJMEDIA_ORIENT_ROTATE_90DEG;
    for (int i = 0; i < pjsua_vid_dev_count(); i++) {
        pjsua_vid_dev_set_setting(i, PJMEDIA_VID_DEV_CAP_ORIENTATION, &currentOrientation, PJ_TRUE);
    }
}

-(void)receiveVideoWindow:(void(^)(NSError *error, UIView* window))handler {
    int vid_idx;
    pjsua_vid_win_id wid;
    pjsua_vid_win_info winInfo;
    
    pjsua_call_info ci;
    pjsua_call_get_info(self.callID, &ci);
    
    vid_idx = pjsua_call_get_vid_stream_idx(self.callID);
    if (vid_idx >= 0) {
        wid = ci.media[vid_idx].stream.vid.win_in;
        if (wid >= 0 && wid < 16) {
            pjsua_vid_win_get_info(wid, &winInfo);
            if (handler != nil) {
                handler(nil, (__bridge UIView *) winInfo.hwnd.info.ios.window);
            }
        }
    }
}

-(void)startPreview:(void(^)(NSError *error, UIView* window))handler {
    pj_status_t status;
    NSError *error;
    pjsua_vid_preview_param previewParam;
    pjsua_vid_preview_param_default(&previewParam);
    previewParam.wnd_flags = PJMEDIA_VID_DEV_WND_BORDER | PJMEDIA_VID_DEV_WND_RESIZABLE;
    
    status = pjsua_vid_preview_start(PJMEDIA_VID_DEFAULT_CAPTURE_DEV, &previewParam);
    
    if (status != PJ_SUCCESS) {
        error = [NSError errorWithDomain:@"Error hanging up call" code:0 userInfo:nil];
    } else {
        pjsua_vid_win_info winInfo;
        pjsua_vid_win_id winId = pjsua_vid_preview_get_win(PJMEDIA_VID_DEFAULT_CAPTURE_DEV);
        
        pjmedia_coord rect;
        rect.x = 0;
        rect.y = 0;
        pjmedia_rect_size rect_size;
        rect_size.h = 170;
        rect_size.w = 100;
        pjsua_vid_win_set_size(winId,&rect_size);
        pjsua_vid_win_set_pos(winId,&rect);
        status = pjsua_vid_win_get_info(winId, &winInfo);
        
        if (handler != nil) {
            UIView *view = (__bridge UIView *)winInfo.hwnd.info.ios.window;
            winInfo.is_native = PJ_TRUE;
            winInfo.show = YES;
            
            handler(error, view);
        }
    }
}


@end

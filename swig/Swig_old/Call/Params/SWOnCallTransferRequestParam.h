//
//  SWOnCallTransferRequestParam.h
//  swig
//
//  Created by Pierre-Marc Airoldi on 2014-08-19.
//  Copyright (c) 2014 PeteAppDesigns. All rights reserved.
//

#import <Foundation/Foundation.h>

#ifdef __cplusplus
#include "pjsua2.hpp"
#endif

@interface SWOnCallTransferRequestParam : NSObject

#ifdef __cplusplus
+(instancetype)onParamFromParam:(pj::OnCallTransferRequestParam)param;
#endif

@end
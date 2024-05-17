//
//  Hummer.m
//  Hummer
//
//  Copyright © 2019年 didi. All rights reserved.
//

#import "HMJSGlobal.h"
#import "HMConfig.h"
#import "HMReporter.h"
#import <Hummer/HMPluginManager.h>

@implementation Hummer



+ (void)startEngine:(void (^)(HMConfigEntry *))builder {
    //这行代码声明了一个名为beforeTimespec的struct timespec类型的变量。你可以使用这个变量来存储某个时间点或时间间隔
    struct timespec beforeTimespec;
    //给beforeTimespe储存
    HMClockGetTime(&beforeTimespec);

    // 兼容代码
    [HMInterceptor loadExportInterceptor];
    
#warning 没有看懂的，先加标识
    HMConfigEntry *entry = nil;
    if (builder) {
        entry = [HMConfigEntry new];
        builder(entry);
        [[HMConfigEntryManager manager] addConfig:entry];
    }
    //这段代码是用于性能报告和指标报告的
    [HMReporter reportPerformanceWithBlock:^(dispatch_block_t  _Nonnull finishBlock) {
        //取出所有的组件
        [HMExportManager.sharedInstance loadAllExportedComponent];
        finishBlock ? finishBlock() : nil;
        //组件个数
        NSUInteger jsClassCount = HMExportManager.sharedInstance.jsClasses.count;
        [HMReporter reportValue:@(jsClassCount) forKey:HMExportClassesCount namespace:entry.namespace];
    } forKey:HMExportClasses namespace:entry.namespace];
    
    struct timespec afterTimespec;
    //给afterTimespec储存时间
    HMClockGetTime(&afterTimespec);
    struct timespec resultTimespec;
    //用于计算两个时间结构体之间的差值，付值给resultTimespec
    HMDiffTime(&beforeTimespec, &afterTimespec, &resultTimespec);
    //算出多少毫秒的耗时
    [entry.trackEventPlugin trackEngineInitializationWithDuration:@(resultTimespec.tv_sec * 1000 + resultTimespec.tv_nsec / 1000000)];
}

+ (void)addGlobalEnvironment:(NSDictionary *)params {
    [[HMJSGlobal globalObject] addGlobalEnviroment:params];
}

+ (void)evaluateScript:(NSString *)jsScript
              fileName:(NSString *)fileName
            inRootView:(UIView *)rootView {
    HMJSContext *context = [HMJSContext contextInRootView:rootView];
    [context evaluateScript:jsScript fileName:fileName];
}

@end

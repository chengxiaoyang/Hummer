//
//  HMReporter.m
//  Hummer
//
//  Copyright © 2019年 didi. All rights reserved.
//

#import "HMReporter.h"

#import <QuartzCore/QuartzCore.h>
#import <Hummer/HMConfigEntryManager.h>
@interface HMReporter ()

@property (nonatomic, assign) CFTimeInterval beginTime;
@property (nonatomic, assign) CFTimeInterval endTime;

@end

@implementation HMReporter

//这段代码是用于性能报告和指标报告的，通过 HMReporter 类的方法来收集和传递数据，然后通过 HMReporterInterceptor 处理并报告给其他地方使用。
+ (void)reportPerformanceWithBlock:(void (^)(dispatch_block_t _Nonnull))excuteBlock
                            forKey:(NSString *)reportKey namespace:(nonnull NSString *)namespace{
    if (!excuteBlock || reportKey.length == 0) { return; }
    CFTimeInterval beginTime = CACurrentMediaTime() * 1000;
    
    if (excuteBlock) {
        excuteBlock(^{
            CFTimeInterval endTime = CACurrentMediaTime() * 1000;
            
            CFTimeInterval diff = endTime - beginTime;
            if (diff > 0.f) {
                [HMReporterInterceptor handleJSPerformanceWithKey:reportKey info:@{reportKey : @(diff)} namespace:namespace];
            }
        });
    }
}

+ (void)reportValue:(id)value forKey:(NSString *)reportKey namespace:(nonnull NSString *)namespace{
    [HMReporterInterceptor handleJSPerformanceWithKey:reportKey info:@{reportKey : value} namespace:namespace];

}

@end

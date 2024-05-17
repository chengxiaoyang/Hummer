//
//  HMInterceptor.m
//  Hummer
//
//  Copyright © 2019年 didi. All rights reserved.
//

#import "HMInterceptor.h"
#import <dlfcn.h>
#import <mach-o/getsect.h>

@interface HMInterceptor()

@property (nonatomic, strong) NSMutableDictionary *interceptorMap;
@property (nonatomic, copy) NSDictionary *protocolMap;

@end

@implementation HMInterceptor

- (instancetype)init {
    self = [super init];
    if (self) {
        //协议对象
        self.protocolMap = @{
            //@()转换成NSNumber对象
            @(HMInterceptorTypeLog)           : @protocol(HMLoggerProtocol),
            @(HMInterceptorTypeNetwork)       : @protocol(HMRequestProtocol),
            @(HMInterceptorTypeWebImage)      : @protocol(HMWebImageProtocol),
            @(HMInterceptorTypeReporter)      : @protocol(HMReporterProtocol),
            @(HMInterceptorTypeRouter)        : @protocol(HMRouterProtocol),
            @(HMInterceptorTypeImage)         : @protocol(HMImageProtocol),
            @(HMInterceptorTypeEventTrack)    : @protocol(HMEventTrackProtocol),
            @(HMInterceptorTypeJSCaller)      : @protocol(HMJSCallerProtocol),
        };
        //给@()转换成NSNumber对象后作为key，value为一个初始化的数组
        self.interceptorMap = [self _initializeInterceptorMapWithType:_protocolMap.allKeys];
    }
    return self;
}

- (NSMutableDictionary *)_initializeInterceptorMapWithType:(NSArray *)types {
    NSMutableDictionary *__all = NSMutableDictionary.new;
    for (NSNumber *typeNumber in types) {
        HMInterceptorType type = [typeNumber integerValue];
        __all[@(type)] = NSMutableArray.new;
    }
    return __all;
}

static HMInterceptor *__interceptors;

+ (instancetype)sharedInstance {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        __interceptors = [[HMInterceptor alloc] init];
    });
    return __interceptors;
}

+ (void)loadExportInterceptor {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        Dl_info info;
        //获取 __interceptors 这个静态变量对应的符号信息，
        dladdr(&__interceptors, &info);
        
#ifndef __LP64__
        const struct mach_header *mhp = (struct mach_header*)info.dli_fbase;
        unsigned long size = 0;
        uint32_t *memory = (uint32_t*)getsectiondata(mhp, "__DATA", "hm_interceptor", & size);
#else /* defined(__LP64__) */
        //指向当前模块的 Mach-O 头（64 位版本）。Mach-O 头是描述二进制文件结构的数据结构，其中包含了各种信息，包括各个段的位置和大小等。
        const struct mach_header_64 *mhp = (struct mach_header_64*)info.dli_fbase;
        //声明一个变量 size，用于存储段中数据的大小
        unsigned long size = 0;
        //调用 getsectiondata 函数来获取名为 "hm_interceptor" 的段在 __DATA 段中存储的数据，并将数据的大小存储在 size 变量中。这个数据将被解释为 uint64_t 类型的指针数组，因此 memory 指向了该段中存储的数据。
        uint64_t *memory = (uint64_t*)getsectiondata(mhp, "__DATA", "hm_interceptor", & size);
#endif /* defined(__LP64__) */
        //sizeof(void*) 返回指针类型 void* 的大小，而 size 表示存储空间的总大小。通过将存储空间的总大小除以一个指针类型的大小，可以得到存储空间中能够容纳的指针元素的数量。
        for(int idx = 0; idx < size/sizeof(void*); ++idx){
            char *string = (char*)memory[idx];
            NSString *str = [NSString stringWithUTF8String:string];
            [[HMInterceptor sharedInstance] _addLogInterceptorWithClass:NSClassFromString(str)];
        }
    });
}

- (void)_addLogInterceptorWithClass:(Class)cls {
    if (!cls) { return; }
    NSArray *protocolKeys = self.protocolMap.allKeys;
    for (NSNumber *typeNumber in protocolKeys) {
        Protocol *protocol = [self.protocolMap objectForKey:typeNumber];
        if ([cls conformsToProtocol:protocol]) {
            NSMutableArray *logInterceptors = self.interceptorMap[typeNumber];
            id instance = [[cls alloc] init];
            [logInterceptors addObject:instance];
        }
    }
}

+ (NSArray *)interceptors {
    NSArray *allKeys = [HMInterceptor sharedInstance].interceptorMap.allKeys;
    NSMutableArray *interceptorMap = NSMutableArray.new;
    for (NSString *key in allKeys) {
        NSArray *interceptors = [HMInterceptor sharedInstance].interceptorMap[key];
        [interceptorMap addObjectsFromArray:interceptors];
    }
    
    return interceptorMap.copy;
}

+ (nullable NSArray <id <NSObject>> *)interceptor:(HMInterceptorType)type {
    return [HMInterceptor sharedInstance].interceptorMap[@(type)];
}

+ (BOOL)hasInterceptor:(HMInterceptorType)type {
    NSArray *interceptors = [HMInterceptor interceptor:type];
    return (interceptors.count > 0);
}

+ (void)enumerateInterceptor:(HMInterceptorType)type
                   withBlock:(void(^)(id interceptor,
                                      NSUInteger idx,
                                      BOOL * _Nonnull stop))block {
    NSArray *interceptors = [HMInterceptor interceptor:type];
    if (interceptors.count > 0) {
        [interceptors enumerateObjectsUsingBlock:block];
    }
}

@end

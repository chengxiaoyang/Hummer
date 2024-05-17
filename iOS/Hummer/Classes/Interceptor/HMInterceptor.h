//
//  HMInterceptor.h
//  Hummer
//
//  Copyright © 2019年 didi. All rights reserved.
//

#import <Foundation/Foundation.h>
#import "HMLogger.h"
#import "HMLoggerProtocol.h"
#import "HMNetworkProtocol.h"
#import "HMWebImageProtocol.h"
#import "HMReporterProtocol.h"
#import "HMRouterProtocol.h"
#import "HMImageProtocol.h"
#import "HMJSCallerProtocol.h"

#import "HMEventTrackProtocol.h"

NS_ASSUME_NONNULL_BEGIN
//定义了一个名为 HM_EXPORT_INTERCEPTOR 的宏，它接受一个参数 name。
//__attribute__((used, section("__DATA , hm_interceptor")))：这是一个 GCC 特定的属性（attribute），用于告诉编译器和链接器如何处理这个变量。
//used：告诉编译器这个变量（尽管是静态的）应该被包含在最终的链接中，即使它看起来没有被直接引用。这通常用于确保某个变量或函数存在于最终的可执行文件中。
//section("__DATA , hm_interceptor")：将变量放在名为 __DATA, hm_interceptor 的段（section）中。在链接或运行时，其他工具可能会查找这个特定的段以执行某些操作，例如拦截函数调用或加载配置数据。
//static char *：定义一个静态字符指针。
//__hm_export_interceptor_##name##__：这是一个由宏生成的变量名。## 是宏的字符串化操作符，它用于连接宏参数和其他字符串。因此，如果 name 是 foo，那么生成的变量名将是 __hm_export_interceptor_foo__。
//=""#name"";：这里用到了两个 GCC 特定的宏操作符：# 和 =。
//#name：将宏参数 name 转换为其字符串形式。如果 name 是 foo，则 #name 会被替换为 "foo"。
//=：这里实际上没有特殊的宏含义，它只是一个普通的赋值操作符。但是，因为前面有一个双引号 "，所以这个表达式实际上是在创建一个字符串字面量，其内容为 name 的字符串形式。所以，如果 name 是 foo，那么这部分会被替换为 ="foo";。
//整个宏定义的作用是将拦截器的名称作为字符串存储在特定的段中，以便在运行时可以获取这些拦截器的名称。
#define HM_EXPORT_INTERCEPTOR(name) \
__attribute__((used, section("__DATA , hm_interceptor"))) \
static char *__hm_export_interceptor_##name##__ = ""#name"";

typedef NS_ENUM(NSUInteger, HMInterceptorType) {
    HMInterceptorTypeLog,
    HMInterceptorTypeNetwork,
    HMInterceptorTypeWebImage,
    HMInterceptorTypeReporter,
    HMInterceptorTypeRouter,
    HMInterceptorTypeImage,
    HMInterceptorTypeEventTrack,
    HMInterceptorTypeJSLoad,
    HMInterceptorTypeJSCaller
};

DEPRECATED_MSG_ATTRIBUTE("HMInterceptor is deprecated. Use HMConfigEntryManager instead")
@interface HMInterceptor : NSObject

+ (void)loadExportInterceptor;

+ (nullable NSArray *)interceptors;

+ (nullable NSArray <__kindof id <NSObject>> *)interceptor:(HMInterceptorType)type;

+ (BOOL)hasInterceptor:(HMInterceptorType)type;

+ (void)enumerateInterceptor:(HMInterceptorType)type
                   withBlock:(void(^)(id interceptor,
                                      NSUInteger idx,
                                      BOOL * _Nonnull stop))block;

@end

NS_ASSUME_NONNULL_END

//
//  HMJSCStrongValue.m
//  Hummer
//
//  Created by 唐佳诚 on 2021/1/13.
//

#import "HMJSCStrongValue.h"
#import "HMJSCExecutor+Private.h"

NS_ASSUME_NONNULL_BEGIN

@interface HMJSCStrongValue ()

@property (nonatomic, assign) JSValueRef valueRef;

@end

NS_ASSUME_NONNULL_END

@implementation HMJSCStrongValue

// 使用给定的执行器（可能用于执行 JavaScript 代码）初始化实例。
- (instancetype)initWithExecutor:(id <HMBaseExecutorProtocol>)executor {
    return [self initWithValueRef:NULL executor:executor];
}

//使用给定的 JavaScript 值引用和执行器初始化实例。
- (instancetype)initWithValueRef:(JSValueRef)valueRef executor:(id <HMBaseExecutorProtocol>)executor {
    HMAssertMainQueue();
    //它检查执行器是否是预期的类
    if (![executor isKindOfClass:HMJSCExecutor.class]) {
        return nil;
    }
    HMJSCExecutor *jscExecutor = executor;
    //它检查提供的 valueRef 是否不是 NULL，并且在 JavaScript 上下文中，执行器和值是否未定义或为空。
    if (!valueRef || !executor || JSValueIsUndefined(jscExecutor.contextRef, valueRef) || JSValueIsNull(jscExecutor.contextRef, valueRef)) {
        return nil;
    }
    self = [super initWithExecutor:executor];
    if (!self) {
        return nil;
    }
    // 如果为字符串或者对象必须要放到强引用池，并使用 JSValueProtect 保护 JavaScript 值，防止其被垃圾回收。
    if (JSValueIsString(jscExecutor.contextRef, valueRef) || JSValueIsObject(jscExecutor.contextRef, valueRef)) {
        if (!jscExecutor.strongValueReleasePool) {
            //创建一个弱引用对象的池子，用于存储 HMJSCStrongValue 对象。这样，在 JavaScript 值不再被强引用时，HMJSCStrongValue 对象也会被自动释放，从而避免内存泄漏问题。
            jscExecutor.strongValueReleasePool = NSHashTable.weakObjectsHashTable;
        }
        [jscExecutor.strongValueReleasePool addObject:self];
        //用于保护 JavaScript 值，以防止其被垃圾回收器回收。
        JSValueProtect(jscExecutor.contextRef, valueRef);
    }
    _valueRef = valueRef;

    return self;
}

- (void)dealloc {
    if (!self.context) {
        return;
    }
    JSValueRef valueRef = _valueRef;
    __weak HMJSCExecutor *jscExecutor = self.context;
    HMSafeMainThread(^{
        if (!jscExecutor) {
            return;
        }
        //JSValueUnprotect 函数来取消保护，以避免内存泄漏。
        JSValueUnprotect(jscExecutor.contextRef, valueRef);
    });
}

- (void)forceUnprotectWithGlobalContextRef:(JSGlobalContextRef)globalContextRef {
    HMAssertMainQueue();
    //JSValueUnprotect 函数来取消保护，以避免内存泄漏。
    JSValueUnprotect(globalContextRef, _valueRef);
}

+ (instancetype)valueWithJSValueRef:(JSValueRef)value inContext:(id <HMBaseExecutorProtocol>)context {
    return [[self alloc] initWithValueRef:value executor:context];
}

@end

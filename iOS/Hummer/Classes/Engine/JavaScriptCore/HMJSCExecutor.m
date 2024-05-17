//
//  HMJSCExecutor.m
//  Hummer
//
//  Created by 唐佳诚 on 2021/1/13.
//

#import <objc/runtime.h>
#import "HMJSCExecutor+Private.h"
#import "HMLogger.h"
#import "HMExceptionModel.h"
#import "HMJSCStrongValue.h"
#import "NSObject+Hummer.h"
#import "HMExportClass.h"
#import "HMJSCWeakValue.h"
#import "HMEncoding.h"
#import "NSInvocation+Hummer.h"
#import "HMUtility.h"
#import "HMInterceptor.h"
#import "HMConfigEntryManager.h"
#import "NSObject+HMDescription.h"
#import <Hummer/HMJSGlobal.h>
#import <Hummer/HMDebug.h>

NS_ASSUME_NONNULL_BEGIN

static NSString *const EXCEPTION_HANDLER_ERROR = @"异常处理函数发生错误";

static NSString *const JSArrayConstructorNotFound = @"JavaScript Array 构造函数不存在";

static NSString *const IsArrayNotFound = @"isArray 方法未找到";

static void hummerFinalize(JSObjectRef object);

static JSValueRef _Nullable hummerCall(JSContextRef ctx, JSObjectRef function, JSObjectRef thisObject, size_t argumentCount, const JSValueRef _Nonnull arguments[], JSValueRef *exception);

static JSValueRef _Nullable hummerCreate(JSContextRef ctx, JSObjectRef function, JSObjectRef thisObject, size_t argumentCount, const JSValueRef _Nonnull arguments[], JSValueRef *exception);

static JSValueRef _Nullable hummerCallFunction(JSContextRef ctx, JSObjectRef function, JSObjectRef thisObject, size_t argumentCount, const JSValueRef _Nonnull arguments[], JSValueRef *exception);

static JSValueRef _Nullable hummerGetProperty(JSContextRef ctx, JSObjectRef function, JSObjectRef thisObject, size_t argumentCount, const JSValueRef _Nonnull arguments[], JSValueRef *exception);

static JSValueRef _Nullable hummerSetProperty(JSContextRef ctx, JSObjectRef function, JSObjectRef thisObject, size_t argumentCount, const JSValueRef _Nonnull arguments[], JSValueRef *exception);

static JSValueRef _Nullable nativeLoggingHook(JSContextRef ctx, JSObjectRef function, JSObjectRef thisObject, size_t argumentCount, const JSValueRef _Nonnull arguments[], JSValueRef *exception);

static JSContextGroupRef _Nullable virtualMachineRef = NULL;

@interface HMJSCExecutor ()

@property (nonatomic, assign) JSGlobalContextRef contextRef;

@property (nonatomic, strong) NSMapTable<id, HMExceptionHandler> *exceptionHandlerMap;
@property (nonatomic, strong) NSMapTable<id, HMConsoleHandler> *consoleHandlerMap;

@property (nonatomic, nullable, copy) NSHashTable<HMJSCStrongValue *> *strongValueReleasePool;

- (void)hummerExtractExportWithFunctionPropertyName:(nullable NSString *)functionPropertyName objectRef:(nullable JSObjectRef)objectRef target:(id _Nullable *)target selector:(SEL _Nullable *)selector methodSignature:(NSMethodSignature *_Nullable *)methodSignature isSetter:(BOOL)isSetter jsClassName:(nullable NSString *)jsClassName;

// const JSValueRef[] 是 JavaScriptCore 函数签名要求
- (nullable JSValueRef)hummerCallNativeWithArgumentCount:(size_t)argumentCount arguments:(const JSValueRef _Nonnull[])arguments target:(nullable id)target selector:(nullable SEL)selector methodSignature:(nullable NSMethodSignature *)methodSignature;

- (nullable JSValueRef)hummerGetSetPropertyWithArgumentCount:(size_t)argumentCount arguments:(const JSValueRef _Nonnull[])arguments isSetter:(BOOL)isSetter;

- (BOOL)valueRefIsArray:(nullable JSValueRef)valueRef;

- (BOOL)valueRefIsNativeObject:(nullable JSValueRef)valueRef;

- (BOOL)valueRefIsFunction:(nullable JSValueRef)valueRef;

- (BOOL)valueRefIsDictionary:(nullable JSValueRef)valueRef;

- (nullable NSObject *)convertValueRefToNativeObject:(nullable JSValueRef)valueRef;

- (nullable NSString *)convertValueRefToString:(nullable JSValueRef)valueRef isForce:(BOOL)isForce;

- (nullable NSNumber *)convertValueRefToNumber:(nullable JSValueRef)valueRef isForce:(BOOL)isForce;

/// 业务代码打 exception，Hummer 内部代码异常情况打日志
- (BOOL)popExceptionWithErrorObject:(JSValueRef _Nullable *_Nullable)errorObject;

- (nullable JSValueRef)convertNumberToValueRef:(nullable NSNumber *)number;

- (nullable JSValueRef)convertStringToValueRef:(nullable NSString *)stringValue;

- (nullable JSValueRef)convertNativeObjectToValueRef:(nullable NSObject *)object;

- (nullable JSValueRef)convertFunctionToValueRef:(nullable id)function;

- (nullable JSValueRef)convertArrayToValueRef:(nullable NSArray *)array;

- (nullable JSValueRef)convertDictionaryToValueRef:(nullable NSDictionary<NSString *, id> *)dictionary;

- (nullable JSValueRef)convertObjectToValueRef:(nullable id)object;

- (nullable HMFunctionType)convertValueRefToFunction:(nullable JSValueRef)valueRef;

- (nullable JSValueRef)callWithFunctionObject:(nullable JSObjectRef)functionObjectRef thisObject:(nullable JSObjectRef)thisObjectRef argumentArray:(nullable NSArray *)argumentArray;

- (nullable NSArray *)convertValueRefToArray:(nullable JSValueRef)valueRef isPortableConvert:(BOOL)isPortableConvert;

- (nullable NSDictionary<NSString *, id> *)convertValueRefToDictionary:(nullable JSValueRef)valueRef isPortableConvert:(BOOL)isPortableConvert;

- (nullable id)convertValueRefToObject:(nullable JSValueRef)valueRef isPortableConvert:(BOOL)isPortableConvert;

- (void)triggerExceptionHandler:(HMExceptionModel *)model;
- (void)triggerConsoleHandler:(NSString *)logString level:(HMLogLevel)logLevel;
@end

NS_ASSUME_NONNULL_END

/**
 ctx：JavaScript 上下文对象。
 function：表示 JavaScript 函数对象的引用。
 thisObject：表示调用 JavaScript 函数的对象的引用。
 argumentCount：表示传递给 JavaScript 函数的参数数量。
 arguments：表示传递给 JavaScript 函数的参数数组。
 exception：如果在执行函数时发生错误，可以设置此参数以传递异常信息。
 */
JSValueRef _Nullable nativeLoggingHook(JSContextRef ctx, JSObjectRef function, JSObjectRef thisObject, size_t argumentCount, const JSValueRef _Nonnull arguments[], JSValueRef *exception) {
    HMAssertMainQueue();
    if (argumentCount != 2) {
        return NULL;
    }
    HMJSCExecutor *executor = (HMJSCExecutor *) [HMExecutorMap objectForKey:[NSValue valueWithPointer:JSContextGetGlobalContext(ctx)]];
    NSString *logString = [executor convertValueRefToString:arguments[0] isForce:NO];
    HMLogLevel logLevel = [executor convertValueRefToNumber:arguments[1] isForce:NO].unsignedIntegerValue;
    // 日志中间件
    HMJSContext *context = [[HMJSGlobal globalObject] currentContext:executor];
    [executor triggerConsoleHandler:logString level:logLevel];
    
    return NULL;
}

JSValueRef _Nullable hummerCall(JSContextRef ctx, JSObjectRef function, JSObjectRef thisObject, size_t argumentCount, const JSValueRef _Nonnull arguments[], JSValueRef *exception) {
    HMAssertMainQueue();
    // 可以使用 callback 代替同步
    // 类方法参数必须大于等于三个
    if (argumentCount < 2) {
        HMLogError(HUMMER_CALL_PARAMETER_ERROR);

        return NULL;
    }
    // 判断第一个参数是否为 Object 来确定调用的是类方法还是实例方法
    JSObjectRef objectRef = NULL;
    if (JSValueIsObject(ctx, arguments[0])) {
        objectRef = JSValueToObject(ctx, arguments[0], exception);
        // 发生 exception 可以降级到类方法来调用
        // JSValueRef *exception 必定存在
        if (*exception) {
            HMLogWarning(HUMMER_DOWNGRADE_TO_CLASS_CALL);
            *exception = NULL;
        }
    }
    // 成员方法参数必须大于等于三个
    if (objectRef && argumentCount < 3) {
        HMLogError(HUMMER_CALL_PARAMETER_ERROR);

        return NULL;
    }
    HMJSCExecutor *executor = (HMJSCExecutor *) [HMExecutorMap objectForKey:[NSValue valueWithPointer:JSContextGetGlobalContext(ctx)]];
    NSString *className = [executor convertValueRefToString:arguments[objectRef ? 1 : 0] isForce:NO];
    NSString *functionName = [executor convertValueRefToString:arguments[objectRef ? 2 : 1] isForce:NO];
    // this 指针
    // 是否为函数类型
    // NSValue - valueWithPointer: nullable
    id target = nil;
    SEL selector = nil;
    NSMethodSignature *methodSignature = nil;
    
    // jscall回调
    HMJSContext *context = [[HMJSGlobal globalObject] currentContext:executor];

    // 最后一个参数无效
    [executor hummerExtractExportWithFunctionPropertyName:functionName objectRef:objectRef target:&target selector:&selector methodSignature:&methodSignature isSetter:YES jsClassName:className];
    
#ifdef HMDEBUG
    {
        NSString *objRefStr = objectRef ? [NSString stringWithFormat:@"%p", target] : nil;
        NSMutableArray *argList = @[].mutableCopy;
        int argStartIndex = objectRef ? 1:0;
        for (NSUInteger i = 2; i < MIN(methodSignature.numberOfArguments + argStartIndex, argumentCount) - argStartIndex; ++i) {
            HMJSCStrongValue *jsValue = [[HMJSCStrongValue alloc] initWithValueRef:arguments[i + argStartIndex] executor:executor];
            [argList addObject:jsValue ? : @"NullOrUndefined"];
        }
        [HMJSCallerInterceptor callNativeWithClassName:className functionName:functionName objectRef:objRefStr args:argList context:context];
    }
#endif

    return [executor hummerCallNativeWithArgumentCount:argumentCount arguments:arguments target:target selector:selector methodSignature:methodSignature];
}

//这个函数似乎是为了便捷地创建与 Objective-C 类对应的 JavaScript 对象，包括处理构造函数参数和在 JavaScript 和 Objective-C 类型之间进行桥接。
JSValueRef _Nullable hummerCreate(JSContextRef ctx, JSObjectRef function, JSObjectRef thisObject, size_t argumentCount, const JSValueRef _Nonnull arguments[], JSValueRef *exception) {
    HMAssertMainQueue();
    if (argumentCount < 2) {
        HMLogError(HUMMER_CREATE_ERROR);

        return NULL;
    }
    HMJSCExecutor *executor = (HMJSCExecutor *) [HMExecutorMap objectForKey:[NSValue valueWithPointer:JSContextGetGlobalContext(ctx)]];
    NSString *className = [executor convertValueRefToString:arguments[0] isForce:NO];
    // 隐含 executor 不为空
    if (className.length == 0) {
        HMLogError(HUMMER_CREATE_ERROR);

        return NULL;
    }

    HMExportClass *exportClass = HMExportManager.sharedInstance.jsClasses[className];
    NSString *objcClassName = exportClass.className;
    if (objcClassName.length == 0) {
        HMLogError(HUMMER_CREATE_CLASS_NOT_FOUND, className);

        return NULL;
    }
    Class clazz = NSClassFromString(objcClassName);
    if (!clazz) {
        HMLogError(HUMMER_CREATE_CLASS_NOT_FOUND, className);

        return NULL;
    }

    // jscall回调
    HMJSContext *context = [[HMJSGlobal globalObject] currentContext:executor];
    
    // 创建对象
    NSObject *opaquePointer = NULL;
    NSMutableArray<HMBaseValue *> *argumentArray = nil;
    for (int i = 2; i < argumentCount; ++i) {
        HMBaseValue *value = [[HMJSCStrongValue alloc] initWithValueRef:arguments[i] executor:executor];
        if (!argumentArray) {
            argumentArray = [NSMutableArray arrayWithCapacity:argumentCount - 2];
        }
        if (value) {
            [argumentArray addObject:value];
        }
    }
#ifdef HMDEBUG
    [HMJSCallerInterceptor callNativeWithClassName:className functionName:@"constructor" objectRef:nil args:argumentArray context:context];
#endif
    HMCurrentExecutor = executor;
    // 支持 HMJSObject，如果不支持则回退 init
    // 不判断 argumentCount > 2，因为 UIView 必须调用 HMJSObject 初始化方法
    if ([clazz conformsToProtocol:@protocol(HMJSObject)]) {
        opaquePointer = (id) [(id) [clazz alloc] initWithHMValues:argumentArray];
    } else {
        HMOtherArguments = argumentArray.copy;
        opaquePointer = [[clazz alloc] init];
    }
    HMCurrentExecutor = nil;
    HMOtherArguments = nil;
    if (!opaquePointer) {
        HMLogError(HUMMER_CAN_NOT_CREATE_NATIVE_OBJECT, className);

        return NULL;
    }
    // 关联 hm_value
    opaquePointer.hmValue = [[HMJSCStrongValue alloc] initWithValueRef:arguments[1] executor:executor];
    // 引用计数 +1
    HMLogDebug(HUMMER_CREATE_TEMPLATE, className);
    JSClassDefinition hostObjectClassDef = kJSClassDefinitionEmpty;
    hostObjectClassDef.version = 0;
    hostObjectClassDef.attributes = kJSClassAttributeNoAutomaticPrototype;
    hostObjectClassDef.finalize = hummerFinalize;
    JSClassRef hostObjectClass = JSClassCreate(&hostObjectClassDef);

    // 填充不透明指针
    JSObjectRef objectRef = JSObjectMake(ctx, hostObjectClass, (__bridge void *) opaquePointer);
    if (objectRef) {
        CFRetain((__bridge CFTypeRef) opaquePointer);
    }
    JSClassRelease(hostObjectClass);

    return objectRef;
}

JSValueRef _Nullable hummerCallFunction(JSContextRef ctx, JSObjectRef function, JSObjectRef thisObject, size_t argumentCount, const JSValueRef _Nonnull arguments[], JSValueRef *exception) {
    HMAssertMainQueue();
    if (argumentCount == 0) {
        HMLogError(HUMMER_CALL_CLOSURE_MUST_HAVE_PARAMETER);

        return NULL;
    }
    if (!JSValueIsObject(ctx, arguments[0])) {
        HMLogError(HUMMER_FIRST_PARAMETER_NOT_NATIVE_CLOSURE);

        return NULL;
    }
    JSObjectRef objectRef = JSValueToObject(ctx, arguments[0], exception);
    if (!objectRef) {
        HMLogError(HUMMER_FIRST_PARAMETER_NOT_NATIVE_CLOSURE);

        return NULL;
    }
    if (![(__bridge id) JSObjectGetPrivate(objectRef) isKindOfClass:NSClassFromString(@"NSBlock")]) {
        HMLogError(HUMMER_FIRST_PARAMETER_NOT_NATIVE_CLOSURE);

        return NULL;
    }
    // 转参数
    HMJSCExecutor *executor = (HMJSCExecutor *) [HMExecutorMap objectForKey:[NSValue valueWithPointer:JSContextGetGlobalContext(ctx)]];
    NSMutableArray<HMBaseValue *> *mutableArgumentArray = nil;
    for (int i = 1; i < argumentCount; ++i) {
        HMBaseValue *jsValue = [[HMJSCStrongValue alloc] initWithValueRef:arguments[i] executor:executor];
        if (!mutableArgumentArray) {
            mutableArgumentArray = [NSMutableArray arrayWithCapacity:argumentCount - 1];
        }
        if (jsValue) {
            [mutableArgumentArray addObject:jsValue];
        }
    }
    HMCurrentExecutor = executor;
    HMFunctionType closure = (__bridge HMFunctionType) JSObjectGetPrivate(objectRef);
    // TODO(ChasonTang): 探测执行，特殊处理第一个参数为 NSArray 的情况（兼容，可能需要开启开关）
    NSMethodSignature *methodSignature = HMExtractMethodSignatureFromBlock(closure);
    if (!methodSignature || methodSignature.numberOfArguments == 0 || methodSignature.numberOfArguments > 2) {
        return NULL;
    }
    NSInvocation *invocation = [NSInvocation invocationWithMethodSignature:methodSignature];
    invocation.target = closure;
    NSArray<HMBaseValue *> *argumentArray = mutableArgumentArray.copy;
    if (methodSignature.numberOfArguments == 2) {
        [invocation hm_setArgument:argumentArray atIndex:1 encodingType:HMEncodingGetType([methodSignature getArgumentTypeAtIndex:1])];
    }
    [invocation invoke];
    id returnObject = [invocation hm_getReturnValueObject];
    HMCurrentExecutor = nil;
    if (!returnObject) {
        return NULL;
    }

    return [executor convertObjectToValueRef:returnObject];
}

JSValueRef _Nullable hummerGetProperty(JSContextRef ctx, JSObjectRef function, JSObjectRef thisObject, size_t argumentCount, const JSValueRef _Nonnull arguments[], JSValueRef *exception) {
    HMAssertMainQueue();
    HMJSCExecutor *executor = (HMJSCExecutor *) [HMExecutorMap objectForKey:[NSValue valueWithPointer:JSContextGetGlobalContext(ctx)]];

    return [executor hummerGetSetPropertyWithArgumentCount:argumentCount arguments:arguments isSetter:NO];
}

JSValueRef hummerSetProperty(JSContextRef ctx, JSObjectRef function, JSObjectRef thisObject, size_t argumentCount, const JSValueRef arguments[], JSValueRef *exception) {
    HMAssertMainQueue();
    HMJSCExecutor *executor = (HMJSCExecutor *) [HMExecutorMap objectForKey:[NSValue valueWithPointer:JSContextGetGlobalContext(ctx)]];

    return [executor hummerGetSetPropertyWithArgumentCount:argumentCount arguments:arguments isSetter:YES];
}

void hummerFinalize(JSObjectRef object) {
    HMAssertMainQueue();
    void *opaquePointer = JSObjectGetPrivate(object);
    assert(opaquePointer != NULL);
    if (opaquePointer) {
        // 不透明指针可能为原生对象，也可能为闭包
        // 清空 hm_value
        [((__bridge id) opaquePointer) setHmValue:nil];
        HMLogDebug(HUMMER_DESTROY_TEMPLATE, [((__bridge id) opaquePointer) class]);
        CFRelease(opaquePointer);
    } else {
        HMLogError(HUMMER_OPAQUE_POINTER_IS_NULL);
    }
}

@implementation HMJSCExecutor

- (instancetype)init {
    HMAssertMainQueue();
    self = [super init];
    if (!HMExecutorMap) {
        HMExecutorMap = NSMapTable.strongToWeakObjectsMapTable;
    }
    if (!virtualMachineRef) {
        virtualMachineRef = JSContextGroupCreate();
    }
    //创建了一个 JavaScript 执行上下文（_contextRef）。
    _contextRef = JSGlobalContextCreateInGroup(virtualMachineRef, NULL);
    //初始化了两个 NSMapTable（_exceptionHandlerMap 和 _consoleHandlerMap）。
    _exceptionHandlerMap = [NSMapTable mapTableWithKeyOptions:NSPointerFunctionsWeakMemory valueOptions:NSPointerFunctionsStrongMemory];
    _consoleHandlerMap = [NSMapTable mapTableWithKeyOptions:NSPointerFunctionsWeakMemory valueOptions:NSPointerFunctionsStrongMemory];

//    _contextRef = JSGlobalContextCreate(NULL);
    //将当前实例（self）使用 JavaScript 上下文引用作为键存储在一个 Map Table（HMExecutorMap）中。
    [HMExecutorMap setObject:self forKey:[NSValue valueWithPointer:_contextRef]];

    // 注入对象
    // JSStringCreateWithUTF8CString 传入 NULL 会创建空字符串
    //使用 JSStringCreateWithUTF8CString 函数创建了几个 JavaScript 字符串，用于命名各种功能和回调函数。
    JSStringRef hummerCallString = JSStringCreateWithUTF8CString("hummerCall");
    JSStringRef hummerCreateString = JSStringCreateWithUTF8CString("hummerCreate");
    JSStringRef hummerGetPropertyString = JSStringCreateWithUTF8CString("hummerGetProperty");
    JSStringRef hummerSetPropertyString = JSStringCreateWithUTF8CString("hummerSetProperty");
    JSStringRef hummerCallFunctionString = JSStringCreateWithUTF8CString("hummerCallFunction");
    JSStringRef nativeLoggingHookStringRef = JSStringCreateWithUTF8CString("nativeLoggingHook");
    //使用 JSContextGetGlobalObject 函数获取了 JavaScript 上下文中的全局对象。
    JSObjectRef globalThis = JSContextGetGlobalObject(_contextRef);

    //将这些 JavaScript 函数设置为 JavaScript 上下文中全局对象的属性。
    //使用 JSObjectMakeFunctionWithCallback 函数，为每个功能或回调函数创建了相应的 JavaScript 函数对象。这些函数对象是通过 C 回调函数实现的。
    /**
     ctx：JavaScript 上下文对象，表示要创建函数的上下文。
     name：JavaScript 字符串对象，表示要创建的函数的名称。如果为 NULL，则表示创建一个匿名函数。
     callAsFunction：C 回调函数指针，表示 JavaScript 函数被调用时要执行的函数。
     */
    JSObjectRef nativeLoggingHookFunction = JSObjectMakeFunctionWithCallback(_contextRef, NULL, &nativeLoggingHook);
    JSObjectRef inlineHummerCallFunction = JSObjectMakeFunctionWithCallback(_contextRef, NULL, &hummerCall);
    JSObjectRef hummerCreateFunction = JSObjectMakeFunctionWithCallback(_contextRef, NULL, &hummerCreate);
    JSObjectRef hummerGetPropertyFunction = JSObjectMakeFunctionWithCallback(_contextRef, NULL, &hummerGetProperty);
    JSObjectRef hummerSetPropertyFunction = JSObjectMakeFunctionWithCallback(_contextRef, NULL, &hummerSetProperty);
    JSObjectRef hummerCallFunctionFunction = JSObjectMakeFunctionWithCallback(_contextRef, NULL, &hummerCallFunction);
    JSValueRef exception = NULL;
    JSObjectSetProperty(_contextRef, globalThis, nativeLoggingHookStringRef, nativeLoggingHookFunction, kJSPropertyAttributeReadOnly | kJSPropertyAttributeDontDelete, &exception);
    [self popExceptionWithErrorObject:&exception];
    //使用 JSObjectSetProperty 函数将创建的 JavaScript 函数设置为全局对象的属性。
    //每个 JavaScript 函数都被设置为全局对象的一个属性，以便在 JavaScript 代码中调用这些功能。
    /**
     ctx：JavaScript 上下文对象，表示要设置属性的上下文。
     object：JavaScript 对象，表示要设置属性的对象。
     propertyName：JavaScript 字符串对象，表示要设置的属性的名称。
     value：JavaScript 值对象，表示要设置的属性值。
     attributes：属性的特性，可以是以下值的组合：
     kJSPropertyAttributeNone：无特性。
     kJSPropertyAttributeReadOnly：只读属性。
     kJSPropertyAttributeDontEnum：不可枚举属性。
     kJSPropertyAttributeDontDelete：不可删除属性。
     exception：如果设置属性时发生错误，会将异常信息存储在这个指针指向的位置。如果不想处理异常，可以传入 NULL。
     */
    JSObjectSetProperty(_contextRef, globalThis, hummerCallString, inlineHummerCallFunction, kJSPropertyAttributeReadOnly | kJSPropertyAttributeDontDelete, &exception);
    // 初始化过程 exceptionHandler 一定不存在，因此可以会打到日志里
    [self popExceptionWithErrorObject:&exception];
    JSObjectSetProperty(_contextRef, globalThis, hummerCreateString, hummerCreateFunction, kJSPropertyAttributeReadOnly | kJSPropertyAttributeDontDelete, &exception);
    [self popExceptionWithErrorObject:&exception];
    JSObjectSetProperty(_contextRef, globalThis, hummerGetPropertyString, hummerGetPropertyFunction, kJSPropertyAttributeReadOnly | kJSPropertyAttributeDontDelete, &exception);
    [self popExceptionWithErrorObject:&exception];
    JSObjectSetProperty(_contextRef, globalThis, hummerSetPropertyString, hummerSetPropertyFunction, kJSPropertyAttributeReadOnly | kJSPropertyAttributeDontDelete, &exception);
    [self popExceptionWithErrorObject:&exception];
    JSObjectSetProperty(_contextRef, globalThis, hummerCallFunctionString, hummerCallFunctionFunction, kJSPropertyAttributeReadOnly | kJSPropertyAttributeDontDelete, &exception);
    [self popExceptionWithErrorObject:&exception];
    //使用 JSStringRelease 函数释放了创建的 JavaScript 字符串的内存。
    JSStringRelease(nativeLoggingHookStringRef);
    JSStringRelease(hummerCallString);
    JSStringRelease(hummerCreateString);
    JSStringRelease(hummerGetPropertyString);
    JSStringRelease(hummerSetPropertyString);
    JSStringRelease(hummerCallFunctionString);

    return self;
}

- (id)globalObject {
    HMAssertMainQueue();
    return [HMJSCStrongValue valueWithJSValueRef:JSContextGetGlobalObject(self.contextRef) inContext:self];
}

- (nullable HMBaseValue *)evaluateScript:(NSString *)script withSourceURL:(NSURL *)sourceUrl {
    HMAssertMainQueue();
    if (script.length == 0) {
        return nil;
    }
    //创建一个 JSStringRef 类型的 JavaScript 字符串引用
    JSStringRef scriptRef = JSStringCreateWithUTF8CString(script.UTF8String);
    //这个源 URL 可能会被某些调试工具或错误报告机制用来标识脚本的来源。
    JSStringRef sourceRef = NULL;
    if (sourceUrl.absoluteString.length > 0) {
        sourceRef = JSStringCreateWithUTF8CString(sourceUrl.absoluteString.UTF8String);
    }
    JSValueRef exception = NULL;
    // 第一行开始，this 指针为 NULL，则使用 globalThis
    // 对于 JavaScriptCore，没提供 sourceURL，则不会在 Safari 中显示文件，如果是 Hermes，则会告知 Chrome 有 '' 文件
    // 对于低版本 JavaScriptCore，同名文件会被覆盖，高版本则不会覆盖，会显示两个文件
    //使用 JSEvaluateScript 函数来执行脚本。该函数的第一个参数是上下文引用，第二个参数是脚本引用，第三个参数是 this 对象的引用（在这里为 NULL），第四个参数是源 URL 引用（如果存在），第五个参数是一个布尔值（在这里为 1，但在其他情况下可能是一个表示是否报告异常的 BOOL 值），最后一个参数是一个指向 JSValueRef 的指针，用于接收可能发生的异常。
    JSValueRef result = JSEvaluateScript(self.contextRef, scriptRef, NULL, sourceRef, 1, &exception);
    JSStringRelease(scriptRef);
    if (sourceRef) {
        JSStringRelease(sourceRef);
    }
    //从 JavaScript 环境中获取异常信息，并将其转换为 Objective-C 对象，以便在 Objective-C 代码中进行进一步处理和记录。
    if ([self popExceptionWithErrorObject:&exception]) {
        return nil;
    }
    // null undefined ==> nil
    if (!JSValueIsUndefined(self.contextRef, result) && !JSValueIsNull(self.contextRef, result)) {
        return [[HMJSCStrongValue alloc] initWithValueRef:result executor:self];
    } else {
        return nil;
    }
}

//这段代码定义了一个 Objective-C 方法，用于从 JavaScript 对象中提取导出的方法或属性，并将其映射到 Objective-C 对象的目标方法或属性上。
- (void)hummerExtractExportWithFunctionPropertyName:(nullable NSString *)functionPropertyName objectRef:(nullable JSObjectRef)objectRef target:(id _Nullable *)target selector:(SEL _Nullable *)selector methodSignature:(NSMethodSignature *_Nullable *)methodSignature isSetter:(BOOL)isSetter jsClassName:(nullable NSString *)jsClassName {
    //函数开头调用了 HMAssertMainQueue()，用于确保该方法在主线程中执行。
    HMAssertMainQueue();
    //检查传入的目标对象 (target)、选择器 (selector)、方法签名 (methodSignature)、函数属性名称 (functionPropertyName) 和 JavaScript 类名 (jsClassName) 是否都有效。如果有任何一个参数为 nil 或者字符串长度为零，则直接返回，不进行后续操作。
    if (!target || !selector || !methodSignature || functionPropertyName.length == 0 || jsClassName.length == 0) {
        return;
    }
    //从全局的导出类管理器 (HMExportManager) 中获取指定 JavaScript 类名 (jsClassName) 对应的导出类信息 (HMExportClass)。
    HMExportClass *exportClass = HMExportManager.sharedInstance.jsClasses[jsClassName];
    HMExportBaseClass *exportBaseClass = nil;
    //根据传入的对象引用 (objectRef) 是否为空来确定目标对象
    if (!objectRef) {
        //如果为空，则表示操作的是类级别的方法或属性，此时根据导出类信息中的类名创建对应的类对象并赋值给 target；
        // class
        if (exportClass.className.length == 0) {
            HMLogError(HUMMER_CREATE_CLASS_NOT_FOUND, jsClassName);

            return;
        }
        (*target) = NSClassFromString(exportClass.className);
        exportBaseClass = [exportClass methodOrPropertyWithName:functionPropertyName isClass:YES];
    } else {
        //如果不为空，则表示操作的是实例级别的方法或属性，此时从 JavaScript 对象的不透明指针中获取原生对象，并赋值给 target。
        // instance
        // 获取不透明指针
        void *opaquePointer = JSObjectGetPrivate(objectRef);
        if (!opaquePointer || ![((__bridge id) opaquePointer) isKindOfClass:NSObject.class]) {
            return;
        }
        NSObject *nativeObject = (__bridge NSObject *) opaquePointer;
        (*target) = nativeObject;
        exportBaseClass = [exportClass methodOrPropertyWithName:functionPropertyName isClass:NO];
    }
    if ([exportBaseClass isKindOfClass:HMExportMethod.class]) {
        // 方法
        //如果是方法，则根据是否为类方法来获取选择器和方法签名。
        HMExportMethod *exportMethod = (HMExportMethod *) exportBaseClass;
        (*selector) = exportMethod.selector;
        (*methodSignature) = !objectRef ? [*target methodSignatureForSelector:exportMethod.selector] : [[(*target) class] instanceMethodSignatureForSelector:exportMethod.selector];
    } else {
        // 属性
        // isSetter 只有属性才生效
        //如果是属性，则根据是否为设置方法 (isSetter) 来获取选择器和方法签名。
        HMExportProperty *exportProperty = (HMExportProperty *) exportBaseClass;
        (*selector) = isSetter ? exportProperty.propertySetterSelector : exportProperty.propertyGetterSelector;
        (*methodSignature) = !objectRef ? [*target methodSignatureForSelector:(*selector)] : [[(*target) class] instanceMethodSignatureForSelector:(*selector)];
    }
}

- (JSValueRef)hummerGetSetPropertyWithArgumentCount:(size_t)argumentCount arguments:(const JSValueRef _Nonnull[])arguments isSetter:(BOOL)isSetter {
    HMAssertMainQueue();
    if (isSetter) {
        if (argumentCount < 3) {
            HMLogError(HUMMER_GET_SET_ERROR);

            return NULL;
        }
    } else {
        if (argumentCount < 2) {
            HMLogError(HUMMER_GET_SET_ERROR);

            return NULL;
        }
    }
    JSObjectRef objectRef = NULL;
    if (JSValueIsObject(self.contextRef, arguments[0])) {
        JSValueRef exception = NULL;
        objectRef = JSValueToObject(self.contextRef, arguments[0], &exception);
        [self popExceptionWithErrorObject:&exception];
    }
    if (objectRef) {
        if (isSetter) {
            if (argumentCount < 4) {
                HMLogError(HUMMER_GET_SET_ERROR);

                return NULL;
            }
        } else {
            if (argumentCount < 3) {
                HMLogError(HUMMER_GET_SET_ERROR);

                return NULL;
            }
        }
    }

    NSString *className = [self convertValueRefToString:arguments[objectRef ? 1 : 0] isForce:NO];
    if (className.length == 0) {
        return NULL;
    }
    NSString *propertyName = [self convertValueRefToString:arguments[objectRef ? 2 : 1] isForce:NO];
    if (propertyName.length == 0) {
        return NULL;
    }

    id target = nil;
    SEL selector = nil;
    NSMethodSignature *methodSignature = nil;

    [self hummerExtractExportWithFunctionPropertyName:propertyName objectRef:objectRef target:&target selector:&selector methodSignature:&methodSignature isSetter:isSetter jsClassName:className];


    
#ifdef HMDEBUG
    {
        HMJSContext *context = [[HMJSGlobal globalObject] currentContext:self];
        NSString *functionName = propertyName;
        if (isSetter) {
            functionName = [@"set" stringByAppendingString:functionName.capitalizedString];
        }
        NSString *objRefStr = objectRef ? [NSString stringWithFormat:@"%p", target] : nil;
        NSMutableArray *argList = @[].mutableCopy;
        int argStartIndex = objectRef ? 1:0;
        for (NSUInteger i = 2; i < MIN(methodSignature.numberOfArguments + argStartIndex, argumentCount) - argStartIndex; ++i) {
            HMJSCStrongValue *jsValue = [[HMJSCStrongValue alloc] initWithValueRef:arguments[i + argStartIndex] executor:self];
            [argList addObject:jsValue ? : @"NullOrUndefined"];
        }
        [HMJSCallerInterceptor callNativeWithClassName:className functionName:functionName objectRef:objRefStr args:argList context:context];
    }
#endif
    
    return [self hummerCallNativeWithArgumentCount:argumentCount arguments:arguments target:target selector:selector methodSignature:methodSignature];
}

- (BOOL)valueIsNull:(HMBaseValue *)value {
    if (value.context != self || ![value isKindOfClass:HMJSCStrongValue.class]) {
        return NO;
    }
    HMJSCStrongValue *strongValue = (HMJSCStrongValue *) value;
    HMAssertMainQueue();
    
    return JSValueIsNull(self.contextRef, strongValue.valueRef);
}

- (BOOL)valueIsUndefined:(HMBaseValue *)value {
    if (value.context != self || ![value isKindOfClass:HMJSCStrongValue.class]) {
        return NO;
    }
    HMJSCStrongValue *strongValue = (HMJSCStrongValue *) value;
    HMAssertMainQueue();
    
    return JSValueIsUndefined(self.contextRef, strongValue.valueRef);
}

- (BOOL)valueIsBoolean:(HMBaseValue *)value {
    if (value.context != self || ![value isKindOfClass:HMJSCStrongValue.class]) {
        return NO;
    }
    HMJSCStrongValue *strongValue = (HMJSCStrongValue *) value;
    HMAssertMainQueue();

    // valueRef == NULL 的情况下，实际上就是 JS null，所以 JSValueIsBoolean 能正确判断
    return JSValueIsBoolean(self.contextRef, strongValue.valueRef);
}

- (BOOL)valueIsNumber:(HMBaseValue *)value {
    if (value.context != self || ![value isKindOfClass:HMJSCStrongValue.class]) {
        return NO;
    }
    HMJSCStrongValue *strongValue = (HMJSCStrongValue *) value;
    HMAssertMainQueue();

    return JSValueIsNumber(self.contextRef, strongValue.valueRef);
}

- (BOOL)valueIsString:(HMBaseValue *)value {
    if (value.context != self || ![value isKindOfClass:HMJSCStrongValue.class]) {
        return NO;
    }
    HMJSCStrongValue *strongValue = (HMJSCStrongValue *) value;
    HMAssertMainQueue();

    return JSValueIsString(self.contextRef, strongValue.valueRef);
}

- (BOOL)valueIsObject:(HMBaseValue *)value {
    if (value.context != self || ![value isKindOfClass:HMJSCStrongValue.class]) {
        return NO;
    }
    HMJSCStrongValue *strongValue = (HMJSCStrongValue *) value;
    HMAssertMainQueue();

    return JSValueIsObject(self.contextRef, strongValue.valueRef);
}

- (BOOL)valueIsArray:(HMBaseValue *)value {
    if (value.context != self || ![value isKindOfClass:HMJSCStrongValue.class]) {
        return NO;
    }
    HMJSCStrongValue *strongValue = (HMJSCStrongValue *) value;
    HMAssertMainQueue();

    return [self valueRefIsArray:strongValue.valueRef];
}

- (JSValueRef)hummerCallNativeWithArgumentCount:(size_t)argumentCount arguments:(JSValueRef const[])arguments target:(id)target selector:(SEL)selector methodSignature:(NSMethodSignature *)methodSignature {
    HMAssertMainQueue();
    if (!target) {
        HMLogError(HUMMER_CALL_NATIVE_TARGET_ERROR);

        return NULL;
    }
    if (!selector) {
        HMLogError(HUMMER_CALL_NATIVE_SELECTOR_ERROR);

        return NULL;
    }
    if (!methodSignature) {
        HMLogError(HUMMER_CALL_NATIVE_METHOD_SIGNATURE_ERROR);

        return NULL;
    }
    BOOL isClass = object_isClass(target);
    NSMutableArray<HMBaseValue *> *otherArguments = nil;
    HMCurrentExecutor = self;
    // 隐含着 numerOfArguments + 0/1 <= argumentCount
    for (NSUInteger i = methodSignature.numberOfArguments + (isClass ? 0 : 1); i < argumentCount; ++i) {
        // 多余的转数组
        HMBaseValue *hummerValue = [[HMJSCStrongValue alloc] initWithValueRef:arguments[i] executor:HMCurrentExecutor];
        if (!otherArguments) {
            otherArguments = [NSMutableArray arrayWithCapacity:argumentCount - methodSignature.numberOfArguments];
        }
        if (hummerValue) {
            [otherArguments addObject:hummerValue];
        }
    }
    // 存储额外参数
    HMOtherArguments = otherArguments.copy;
    NSInvocation *invocation = [NSInvocation invocationWithMethodSignature:methodSignature];
    invocation.target = target;
    invocation.selector = selector;
    // 后续做循环，都是临时变量，如果不做 retain，会导致野指针
    [invocation retainArguments];

    // 参数
    // 本质为 MIN(methodSignature.numberOfArguments, argumentCount - (isClass : 0 : 1))，主要为了防止无符号数字溢出
    for (NSUInteger i = 2; i < MIN(methodSignature.numberOfArguments + (isClass ? 0 : 1), argumentCount) - (isClass ? 0 : 1); ++i) {
        const char *objCType = [methodSignature getArgumentTypeAtIndex:i];
        HMEncodingType type = HMEncodingGetType(objCType);
        id param = nil;
        if (type == HMEncodingTypeBlock) {
            // Block
            param = [(HMJSCExecutor *) HMCurrentExecutor convertValueRefToFunction:arguments[i + (isClass ? 0 : 1)]];
        } else if (type == HMEncodingTypeObject) {
            // HMJSCValue
            param = [[HMJSCStrongValue alloc] initWithValueRef:arguments[i + (isClass ? 0 : 1)] executor:HMCurrentExecutor];
        } else if (HMEncodingTypeIsCNumber(type)) {
            // js 只存在 double 和 bool 类型，但原生需要区分具体类型。
            param = [(HMJSCExecutor *) HMCurrentExecutor convertValueRefToNumber:arguments[i + (isClass ? 0 : 1)] isForce:NO];
        } else {
            HMLogError(HUMMER_UN_SUPPORT_TYPE_TEMPLATE, objCType);
        }
        [invocation hm_setArgument:param atIndex:i encodingType:type];
    }
    [invocation invoke];
    HMOtherArguments = nil;
    // 返回值
    JSValueRef returnValueRef = NULL;
    const char *objCReturnType = methodSignature.methodReturnType;
    HMEncodingType returnType = HMEncodingGetType(objCReturnType);
    if (returnType != HMEncodingTypeVoid && returnType != HMEncodingTypeUnknown) {
        id returnObject = [invocation hm_getReturnValueObject];
        if (returnObject) {
            returnValueRef = [(HMJSCExecutor *) HMCurrentExecutor convertObjectToValueRef:returnObject];
        }
    }
    HMCurrentExecutor = nil;

    return returnValueRef;
}

- (BOOL)valueRefIsArray:(nullable JSValueRef)valueRef {
    JSObjectRef globalObjectRef = JSContextGetGlobalObject(self.contextRef);
    JSStringRef arrayString = JSStringCreateWithUTF8CString("Array");
    JSValueRef exception = NULL;
    JSValueRef arrayConstructorValue = JSObjectGetProperty(self.contextRef, globalObjectRef, arrayString, &exception);
    JSStringRelease(arrayString);
    if ([self popExceptionWithErrorObject:&exception]) {
        // 用户不关心，所以可以不考虑抛出，直接在这里吃掉并打日志
//        HMLogError(JSArrayConstructorNotFound);

        return NO;
    }
    // JSValueToObject 有慢路径，因此最好先判断是否为对象
    if (!JSValueIsObject(self.contextRef, arrayConstructorValue)) {
        HMLogError(JSArrayConstructorNotFound);

        return NO;
    }
    JSObjectRef arrayConstructorObjectRef = JSValueToObject(self.contextRef, arrayConstructorValue, &exception);
    if ([self popExceptionWithErrorObject:&exception] || !arrayConstructorObjectRef) {
//        HMLogError(JSArrayConstructorNotFound);

        return NO;
    }
    JSStringRef isArrayString = JSStringCreateWithUTF8CString("isArray");
    // JSObjectGetProperty 要求对象不为空
    JSValueRef isArrayValue =
            JSObjectGetProperty(self.contextRef, arrayConstructorObjectRef, isArrayString, &exception);
    JSStringRelease(isArrayString);
    if ([self popExceptionWithErrorObject:&exception] || !JSValueIsObject(self.contextRef, isArrayValue)) {
//        HMLogError(IsArrayNotFound);

        return NO;
    }
    JSObjectRef isArray = JSValueToObject(self.contextRef, isArrayValue, &exception);
    if ([self popExceptionWithErrorObject:&exception]) {
//        HMLogError(IsArrayNotFound);

        return NO;
    }
    JSValueRef arguments[] = {
            valueRef
    };
    JSValueRef result = JSObjectCallAsFunction(self.contextRef, isArray, NULL, 1, arguments, &exception);
    if ([self popExceptionWithErrorObject:&exception]) {
//        HMLogError(@"isArray 抛出错误");

        return NO;
    }

    return JSValueToBoolean(self.contextRef, result);
}

- (BOOL)valueIsNativeObject:(HMBaseValue *)value {
    if (value.context != self || ![value isKindOfClass:HMJSCStrongValue.class]) {
        return NO;
    }
    HMJSCStrongValue *strongValue = (HMJSCStrongValue *) value;

    return [self valueRefIsNativeObject:strongValue.valueRef];
}

- (BOOL)valueRefIsNativeObject:(nullable JSValueRef)valueRef {
    return (BOOL) [self convertValueRefToNativeObject:valueRef];
}

- (BOOL)valueIsFunction:(HMBaseValue *)value {
    if (value.context != self || ![value isKindOfClass:HMJSCStrongValue.class]) {
        return NO;
    }
    HMJSCStrongValue *strongValue = (HMJSCStrongValue *) value;

    return [self valueRefIsFunction:strongValue.valueRef];
}

- (BOOL)valueRefIsFunction:(JSValueRef)valueRef {
    HMAssertMainQueue();
    if (!JSValueIsObject(self.contextRef, valueRef)) {
        return NO;
    }
    JSValueRef exception = NULL;
    JSObjectRef objectRef = JSValueToObject(self.contextRef, valueRef, &exception);
    if ([self popExceptionWithErrorObject:&exception]) {
        return NO;
    }
    if (!JSObjectIsFunction(self.contextRef, objectRef)) {
        return NO;
    }

    return YES;
}

- (BOOL)valueIsDictionary:(HMBaseValue *)value {
    if (value.context != self || ![value isKindOfClass:HMJSCStrongValue.class]) {
        return NO;
    }
    HMJSCStrongValue *strongValue = (HMJSCStrongValue *) value;

    return [self valueRefIsDictionary:strongValue.valueRef];
}

- (BOOL)valueRefIsDictionary:(JSValueRef)valueRef {
    HMAssertMainQueue();
    // 1. 是对象
    // 2. 不是数组
    // 3. 不是闭包
    // 4. 不是原生对象
    if (!JSValueIsObject(self.contextRef, valueRef)) {
        return NO;
    }
    if (JSValueIsArray(self.contextRef, valueRef)) {
        return NO;
    }
    if ([self valueRefIsFunction:valueRef]) {
        return NO;
    }
    if ([self valueRefIsNativeObject:valueRef]) {
        return NO;
    }

    return YES;
}

- (nullable NSNumber *)convertToNumberWithValue:(HMBaseValue *)value isForce:(BOOL)isForce {
    if (value.context != self || ![value isKindOfClass:HMJSCStrongValue.class]) {
        return nil;
    }
    HMJSCStrongValue *strongValue = (HMJSCStrongValue *) value;

    return [self convertValueRefToNumber:strongValue.valueRef isForce:isForce];
}

- (nullable NSObject *)convertToNativeObjectWithValue:(HMBaseValue *)value {
    if (value.context != self || ![value isKindOfClass:HMJSCStrongValue.class]) {
        return nil;
    }
    HMJSCStrongValue *strongValue = (HMJSCStrongValue *) value;

    return [self convertValueRefToNativeObject:strongValue.valueRef];
}

- (nullable NSString *)convertToStringWithValue:(HMBaseValue *)value isForce:(BOOL)isForce {
    if (value.context != self || ![value isKindOfClass:HMJSCStrongValue.class]) {
        return nil;
    }
    HMJSCStrongValue *strongValue = (HMJSCStrongValue *) value;

    return [self convertValueRefToString:strongValue.valueRef isForce:isForce];
}

//将 JavaScript 中的 JSValueRef 类型的值转换为 Objective-C 中的 NSString 类型。
- (nullable NSString *)convertValueRefToString:(JSValueRef)valueRef isForce:(BOOL)isForce {
    //用于确保该方法在主线程中执行。
    HMAssertMainQueue();
    // JSValueToStringCopy 有慢路径，因此先判断
    //如果 isForce 参数为 NO，并且传入的 valueRef 不是 JavaScript 字符串类型，则直接返回 nil。这个检查可能用于优化性能，避免不必要的转换操作。
    if (!isForce && !JSValueIsString(self.contextRef, valueRef)) {
        return nil;
    }
    //调用 JSValueToStringCopy 函数将 valueRef 转换为 JavaScript 字符串对象。如果转换过程中出现异常或者返回的字符串对象为空，则直接返回 nil。
    JSValueRef exception = NULL;
    JSStringRef stringRef = JSValueToStringCopy(self.contextRef, valueRef, &exception);
    // 空指针会返回 "" 空字符串，因此最好先判断一下
    if (exception || !stringRef) {
        return nil;
    }
    //通过 JSStringCopyCFString 函数将 JavaScript 字符串对象转换为 Core Foundation 字符串对象，然后通过 CFBridgingRelease 函数转换为 Objective-C 字符串对象，并释放原有的 Core Foundation 字符串对象。
    NSString *stringValue = CFBridgingRelease(JSStringCopyCFString(kCFAllocatorDefault, stringRef));
    JSStringRelease(stringRef);

    return stringValue;
}

//用于将 JavaScript 值（JSValueRef）转换为 NSNumber 对象的方法。在 JavaScriptCore 框架中，JavaScript 值可以是各种类型，包括数字、布尔值、字符串、对象等。这个方法专门处理 JavaScript 中的数字类型值。
//提供一个便捷的方式，用于从 JavaScript 环境中获取数字值，并将其转换为 Objective-C 中的 NSNumber 对象，以便在 Objective-C 代码中进行进一步处理。
- (nullable NSNumber *)convertValueRefToNumber:(JSValueRef)valueRef isForce:(BOOL)isForce {
    HMAssertMainQueue(); // 断言当前为主线程
    if (JSValueIsBoolean(self.contextRef, valueRef)) { // 如果值是布尔类型
        bool boolValue = JSValueToBoolean(self.contextRef, valueRef); // 将JS布尔值转换为C的布尔值

        return @(boolValue); // 返回NSNumber包装的布尔值
    } else if (!isForce && !JSValueIsNumber(self.contextRef, valueRef)) { // 如果不是强制转换且值不是数字类型
        return nil; // 返回空
    } else { // 否则
        // new Number() 是对象不是数字
        double numberValue = JSValueToNumber(self.contextRef, valueRef, NULL); // 将JS值转换为双精度浮点数

        return @(numberValue); // 返回NSNumber包装的数字
    }

    return nil; // 默认返回空
}


- (nullable NSObject *)convertValueRefToNativeObject:(nullable JSValueRef)valueRef {
    HMAssertMainQueue();
    if (!JSValueIsObject(self.contextRef, valueRef)) {
        return nil;
    }
    JSValueRef exception = NULL;
    JSObjectRef objectRef = JSValueToObject(self.contextRef, valueRef, &exception);
    if ([self popExceptionWithErrorObject:&exception] || !objectRef) {
        return nil;
    }
    JSStringRef privatePropertyName = JSStringCreateWithUTF8CString("_private");
    JSValueRef privateValueRef = JSObjectGetProperty(self.contextRef, objectRef, privatePropertyName, &exception);
    JSStringRelease(privatePropertyName);
    if ([self popExceptionWithErrorObject:&exception]) {
        return nil;
    }
    if (!JSValueIsObject(self.contextRef, privateValueRef)) {
        return nil;
    }
    JSObjectRef privateObjectRef = JSValueToObject(self.contextRef, privateValueRef, &exception);
    if ([self popExceptionWithErrorObject:&exception] || !privateObjectRef) {
        return nil;
    }
    // JSObjectGetPrivate 必须为非空
    id hostObject = (__bridge id) JSObjectGetPrivate(privateObjectRef);
    if (!hostObject || ![hostObject isKindOfClass:NSObject.class]) {
        return nil;
    }

    return (NSObject *) hostObject;
}

- (BOOL)popExceptionWithErrorObject:(JSValueRef _Nullable *_Nullable)errorObject {
    HMAssertMainQueue(); // 断言当前为主线程
    if (!errorObject || !*errorObject) { // 如果errorObject为空或者指向的值为空，则返回NO
        return NO;
    }
    if (!self.contextRef) { // 如果上下文引用为空
        HMLogError(@"Executor 初始化过程出错"); // 记录错误日志
    }
    // JSValueIsObject -> toJS 会断言当前 valueRef 如果是对象，则必须属于当前 VM Heap
    // 因此 contextRef 必须存在
    if (!JSValueIsObject(self.contextRef, *errorObject)) { // 如果errorObject不是JavaScript对象
        HMLogWarning(@"valueRef 参数不是 object"); // 记录警告日志
        return NO;
    }
    JSValueRef exception = NULL; // 异常变量初始化为NULL
    JSObjectRef objectRef = JSValueToObject(self.contextRef, *errorObject, &exception); // 将JS值转换为JavaScript对象
    if (exception || !objectRef) { // 如果转换过程中发生异常或者转换结果为空
        HMLogError(@"valueRef 转换 JSObjectRef 失败"); // 记录错误日志
        return NO;
    }
    // 以下代码用于从JavaScript对象中获取列、行、消息、名称和堆栈信息
    JSStringRef columnString = JSStringCreateWithUTF8CString("column"); // 列键名
    JSStringRef lineString = JSStringCreateWithUTF8CString("line"); // 行键名
    JSStringRef messageString = JSStringCreateWithUTF8CString("message"); // 消息键名
    JSStringRef nameString = JSStringCreateWithUTF8CString("name"); // 名称键名
    JSStringRef stackString = JSStringCreateWithUTF8CString("stack"); // 堆栈键名

    JSValueRef columnValueRef = JSObjectGetProperty(self.contextRef, objectRef, columnString, &exception); // 获取列值
    // 不需要判断 columnValueRef
    if (exception) { // 如果在获取列值时发生异常
        HMLogError(EXCEPTION_HANDLER_ERROR); // 记录错误日志
    }
    exception = NULL;
    JSValueRef lineValueRef = JSObjectGetProperty(self.contextRef, objectRef, lineString, &exception); // 获取行值
    if (exception) { // 如果在获取行值时发生异常
        HMLogError(EXCEPTION_HANDLER_ERROR); // 记录错误日志
    }
    exception = NULL;
    JSValueRef messageValueRef = JSObjectGetProperty(self.contextRef, objectRef, messageString, &exception); // 获取消息值
    if (exception) { // 如果在获取消息值时发生异常
        HMLogError(EXCEPTION_HANDLER_ERROR); // 记录错误日志
    }
    exception = NULL;
    JSValueRef nameValueRef = JSObjectGetProperty(self.contextRef, objectRef, nameString, &exception); // 获取名称值
    if (exception) { // 如果在获取名称值时发生异常
        HMLogError(EXCEPTION_HANDLER_ERROR); // 记录错误日志
    }
    exception = NULL;
    JSValueRef stackValueRef = JSObjectGetProperty(self.contextRef, objectRef, stackString, &exception); // 获取堆栈值
    if (exception) { // 如果在获取堆栈值时发生异常
        HMLogError(EXCEPTION_HANDLER_ERROR); // 记录错误日志
    }

    // 创建异常模型并填充相关信息
    HMExceptionModel *errorModel = [[HMExceptionModel alloc] init];
    errorModel.column = [self convertValueRefToNumber:columnValueRef isForce:NO]; // 列
    errorModel.line = [self convertValueRefToNumber:lineValueRef isForce:NO]; // 行
    errorModel.message = [self convertValueRefToString:messageValueRef isForce:NO]; // 消息
    errorModel.name = [self convertValueRefToString:nameValueRef isForce:NO]; // 名称
    errorModel.stack = [self convertValueRefToString:stackValueRef isForce:NO]; // 堆栈

    [self triggerExceptionHandler:errorModel]; // 触发异常处理程序
    JSStringRelease(columnString); // 释放列键名
    JSStringRelease(lineString); // 释放行键名
    JSStringRelease(messageString); // 释放消息键名
    JSStringRelease(nameString); // 释放名称键名
    JSStringRelease(stackString); // 释放堆栈键名

    return YES; // 返回处理成功
}


- (BOOL)compareWithValue:(HMBaseValue *)value anotherValue:(HMBaseValue *)anotherValue {
    // 仿照原生 [object isEqual:anotherObject]，如果 object 为空，最终为 NO
    if ([self valueIsNull:value] || [self valueIsUndefined:value]) {
        return NO;
    }
    if (value.context != self || anotherValue.context != self || ![value isKindOfClass:HMJSCStrongValue.class] || ![anotherValue isKindOfClass:HMJSCStrongValue.class]) {
        return NO;
    }
    HMJSCStrongValue *strongValue = (HMJSCStrongValue *) value;
    HMJSCStrongValue *anotherStrongValue = (HMJSCStrongValue *) anotherValue;

    // 如果两个都为 NULL，则等价于 JavaScript: null === null => true
    return JSValueIsStrictEqual(self.contextRef, strongValue.valueRef, anotherStrongValue.valueRef);
}

- (nullable HMBaseValue *)convertToValueWithNumber:(NSNumber *)number {
    return [[HMJSCStrongValue alloc] initWithValueRef:[self convertNumberToValueRef:number] executor:self];
}

- (JSValueRef)convertNumberToValueRef:(NSNumber *)number {
    HMAssertMainQueue();
    if (number == nil) {
        return NULL;
    }
    if (strcmp(number.objCType, @encode(BOOL)) == 0) {
        return JSValueMakeBoolean(self.contextRef, number.boolValue);
    } else {
        return JSValueMakeNumber(self.contextRef, number.doubleValue);
    }
}

- (JSValueRef)convertStringToValueRef:(NSString *)stringValue {
    HMAssertMainQueue();
    if (!stringValue) {
        return NULL;
    }
    // JSStringCreateWithCFString 如果传递 nil 会创建 "" 空字符串
    // 不需要转移所有权，因为当场复制
    JSStringRef stringRef = JSStringCreateWithCFString((__bridge CFStringRef) (stringValue));
    JSValueRef inlineValueRef = JSValueMakeString(self.contextRef, stringRef);
    JSStringRelease(stringRef);

    return inlineValueRef;
}

- (JSValueRef)convertNativeObjectToValueRef:(NSObject *)object {
    HMAssertMainQueue();
    if ([object hmValue].context == self && [[object hmValue] isKindOfClass:HMJSCStrongValue.class]) {
        // 先判断 hmValue，这样后续的闭包转换和原生组件导出可以减少调用
        // 做严格判断，同上下文才能复用 hmValue
        HMJSCStrongValue *strongValue = (HMJSCStrongValue *) [object hmValue];
        return strongValue.valueRef;
    }
    JSValueRef returnValueRef = NULL;
    NSString *className = NSStringFromClass(object.class);
    HMExportClass *exportClass = HMExportManager.sharedInstance.objcClasses[className];
    if (object && exportClass.jsClass.length > 0) {
        // 如果是导出组件，则通过 Object.create() 创建 JSValue，然后设置 _private
        JSStringRef hummerCreateObjectString = JSStringCreateWithUTF8CString("hummerCreateObject");
        JSValueRef exception = NULL;
        JSValueRef hummerCreateObjectFunction = JSObjectGetProperty(self.contextRef, JSContextGetGlobalObject(self.contextRef), hummerCreateObjectString, &exception);
        JSStringRelease(hummerCreateObjectString);
        if (![self popExceptionWithErrorObject:&exception] && JSValueIsObject(self.contextRef, hummerCreateObjectFunction)) {
            JSObjectRef hummerCreateObjectFunctionObjectRef = JSValueToObject(self.contextRef, hummerCreateObjectFunction, &exception);
            if (![self popExceptionWithErrorObject:&exception] && JSObjectIsFunction(self.contextRef, hummerCreateObjectFunctionObjectRef)) {
                JSStringRef jsClassNameString = JSStringCreateWithCFString((__bridge CFStringRef) (exportClass.jsClass));
                // 引用计数 +1
                JSClassDefinition hostObjectClassDef = kJSClassDefinitionEmpty;
                hostObjectClassDef.version = 0;
                hostObjectClassDef.attributes = kJSClassAttributeNoAutomaticPrototype;
                hostObjectClassDef.finalize = hummerFinalize;
                JSClassRef hostObjectClass = JSClassCreate(&hostObjectClassDef);

                // 填充不透明指针
                JSObjectRef objectRef = JSObjectMake(self.contextRef, hostObjectClass, (__bridge void *) object);
                if (objectRef) {
                    CFRetain((__bridge CFTypeRef) object);
                }
                JSClassRelease(hostObjectClass);

                // 第一个参数是 private 对象，第二个参数是导出对象 JS 类名
                JSValueRef args[] = {
                        objectRef,
                        JSValueMakeString(self.contextRef, jsClassNameString)
                };
                JSStringRelease(jsClassNameString);
                returnValueRef = JSObjectCallAsFunction(self.contextRef, hummerCreateObjectFunctionObjectRef, NULL, 2, args, &exception);
                // Hummer 内置代码
                [self popExceptionWithErrorObject:&exception];
                if (returnValueRef) {
                    HMLogDebug(HUMMER_RETAIN_TEMPLATE, className);
                    object.hmValue = [[HMJSCStrongValue alloc] initWithValueRef:returnValueRef executor:self];
                }
            }
        }
    }

    return returnValueRef;
}

- (nullable JSValueRef)convertFunctionToValueRef:(id)function {
    HMAssertMainQueue();
    if ([function hmValue].context == self && [[function hmValue] isKindOfClass:HMJSCStrongValue.class]) {
        // 先判断 hmValue，这样后续的闭包转换和原生组件导出可以减少调用
        // 做严格判断，同上下文才能复用 hmValue
        HMJSCStrongValue *strongValue = (HMJSCStrongValue *) [function hmValue];
        return strongValue.valueRef;
    }
    JSValueRef returnValueRef = NULL;
    if ([function isKindOfClass:NSClassFromString(@"NSBlock")]) {
        JSStringRef hummerCreateFunction = JSStringCreateWithUTF8CString("hummerCreateFunction");
        JSValueRef exception = NULL;
        JSValueRef createFunctionFunction = JSObjectGetProperty(self.contextRef, JSContextGetGlobalObject(self.contextRef), hummerCreateFunction, &exception);
        JSStringRelease(hummerCreateFunction);
        if (![self popExceptionWithErrorObject:&exception] && JSValueIsObject(self.contextRef, createFunctionFunction)) {
            JSObjectRef createFunctionFunctionObjectRef = JSValueToObject(self.contextRef, createFunctionFunction, &exception);
            if (![self popExceptionWithErrorObject:&exception] && JSObjectIsFunction(self.contextRef, createFunctionFunctionObjectRef)) {
                // 引用计数 +1
                HMLogDebug(HUMMER_CREATE_TEMPLATE, [function class]);
                JSClassDefinition hostObjectClassDef = kJSClassDefinitionEmpty;
                hostObjectClassDef.version = 0;
                hostObjectClassDef.attributes = kJSClassAttributeNoAutomaticPrototype;
                hostObjectClassDef.finalize = hummerFinalize;
                JSClassRef hostObjectClass = JSClassCreate(&hostObjectClassDef);

                // 填充不透明指针
                JSObjectRef objectRef = JSObjectMake(self.contextRef, hostObjectClass, (__bridge void *) function);
                if (objectRef) {
                    CFRetain((__bridge CFTypeRef) function);
                }
                JSClassRelease(hostObjectClass);

                JSValueRef args[] = {
                        objectRef
                };
                returnValueRef = JSObjectCallAsFunction(self.contextRef, createFunctionFunctionObjectRef, NULL, 1, args, &exception);
                [self popExceptionWithErrorObject:&exception];
                if (returnValueRef) {
                    [function setHmValue:[[HMJSCStrongValue alloc] initWithValueRef:returnValueRef executor:self]];
                }
            }
        }
    }

    return returnValueRef;
}

- (nullable JSValueRef)convertArrayToValueRef:(NSArray *)array {
    HMAssertMainQueue();
    __block JSObjectRef arrayRef = NULL;
    // Native -> JavaScript 空数组情况
    if (array && array.count == 0) {
        JSValueRef exception = NULL;
        arrayRef = JSObjectMakeArray(self.contextRef, 0, NULL, &exception);
        if ([self popExceptionWithErrorObject:&exception]) {
            return NULL;
        }
    }

    [array enumerateObjectsUsingBlock:^(id obj, NSUInteger idx, BOOL *stop) {
        JSValueRef inlineValueRef = [self convertObjectToValueRef:obj];
        JSValueRef exception = NULL;
        if (!arrayRef) {
            arrayRef = JSObjectMakeArray(self.contextRef, 0, NULL, &exception);
            if ([self popExceptionWithErrorObject:&exception] || !arrayRef) {
                // continue
                return;
            }
        }
        JSStringRef pushPropertyName = JSStringCreateWithUTF8CString("push");
        JSValueRef pushFunctionValueRef = JSObjectGetProperty(self.contextRef, arrayRef, pushPropertyName, &exception);
        JSStringRelease(pushPropertyName);
        if ([self popExceptionWithErrorObject:&exception] || !JSValueIsObject(self.contextRef, pushFunctionValueRef)) {
            return;
        }
        JSObjectRef objectRef = JSValueToObject(self.contextRef, pushFunctionValueRef, &exception);
        if ([self popExceptionWithErrorObject:&exception]) {
            return;
        }
        if (JSObjectIsFunction(self.contextRef, objectRef)) {
            // 忽略返回值
            JSValueRef argArray[] = {
                    inlineValueRef
            };
            // 忽略异常
            JSObjectCallAsFunction(self.contextRef, objectRef, arrayRef, 1, argArray, &exception);
            [self popExceptionWithErrorObject:&exception];
        }
    }];

    return arrayRef;
}

- (nullable JSValueRef)convertDictionaryToValueRef:(NSDictionary<NSString *, id> *)dictionary {
    HMAssertMainQueue();
    __block JSObjectRef objectRef = NULL;
    // 空字典情况
    if (dictionary && dictionary.count == 0) {
        objectRef = JSObjectMake(self.contextRef, NULL, NULL);

        return objectRef;
    }
    [dictionary enumerateKeysAndObjectsUsingBlock:^(NSString *key, id obj, BOOL *stop) {
        JSValueRef inlineValueRef = [self convertObjectToValueRef:obj];
        JSValueRef exception = NULL;
        if (!objectRef) {
            JSObjectRef globalThis = JSContextGetGlobalObject(self.contextRef);
            JSStringRef objectStringRef = JSStringCreateWithUTF8CString("Object");
            JSValueRef objectConstructor = JSObjectGetProperty(self.contextRef, globalThis, objectStringRef, &exception);
            JSStringRelease(objectStringRef);
            if ([self popExceptionWithErrorObject:&exception] || !JSValueIsObject(self.contextRef, objectConstructor)) {
                // continue
                return;
            }
            JSObjectRef objectConstructorObjectRef = JSValueToObject(self.contextRef, objectConstructor, &exception);
            if ([self popExceptionWithErrorObject:&exception] || !JSObjectIsConstructor(self.contextRef, objectConstructorObjectRef)) {
                return;
            }
            objectRef = JSObjectCallAsConstructor(self.contextRef, objectConstructorObjectRef, 0, NULL, &exception);
            // JSObjectSetProperty 需要 objectRef 为非空
            if ([self popExceptionWithErrorObject:&exception] || !objectRef) {
                // continue
                return;
            }
        }
        JSStringRef propertyName = JSStringCreateWithUTF8CString(key.UTF8String);
        // 忽略异常
        JSObjectSetProperty(self.contextRef, objectRef, propertyName, inlineValueRef, kJSPropertyAttributeNone, &exception);
        [self popExceptionWithErrorObject:&exception];
        JSStringRelease(propertyName);
    }];

    return objectRef;
}

- (nullable HMFunctionType)convertToFunctionWithValue:(HMBaseValue *)value {
    if (value.context != self || ![value isKindOfClass:HMJSCStrongValue.class]) {
        return nil;
    }
    HMJSCStrongValue *strongValue = (HMJSCStrongValue *) value;

    return [self convertValueRefToFunction:strongValue.valueRef];
}

- (nullable HMBaseValue *)convertToValueWithObject:(id)object {
    return [[HMJSCStrongValue alloc] initWithValueRef:[self convertObjectToValueRef:object] executor:self];
}

- (nullable JSValueRef)convertObjectToValueRef:(id)object {
    HMAssertMainQueue();
    if ([object isKindOfClass:HMJSCStrongValue.class]) {
        HMJSCStrongValue *strongValue = object;
        if (strongValue.context != self) {
            // JSValueRef -> 对象 -> JSValueRef
            return [self convertObjectToValueRef:strongValue.toObject];
        }

        // 业务方已经转好，直接添加就行
        return strongValue.valueRef;
    } else if (object == NSNull.null) {
        return JSValueMakeNull(self.contextRef);
    } else if ([object isKindOfClass:NSNumber.class]) {
        return [self convertNumberToValueRef:object];
    } else if ([object isKindOfClass:NSString.class]) {
        return [self convertStringToValueRef:object];
    } else if ([object isKindOfClass:NSArray.class]) {
        return [self convertArrayToValueRef:(NSArray *) object];
    } else if ([object isKindOfClass:NSDictionary.class]) {
        return [self convertDictionaryToValueRef:(NSDictionary<NSString *, id> *) object];
    } else if ([object hmValue].context == self) {
        // 先判断 hmValue，这样后续的闭包转换和原生组件导出可以减少调用
        // 做严格判断，同上下文才能复用 hmValue
        HMJSCStrongValue *strongValue = (HMJSCStrongValue *) [object hmValue];

        return strongValue.valueRef;
    } else if ([object isKindOfClass:NSClassFromString(@"NSBlock")]) {
        return [self convertFunctionToValueRef:object];
    } else {
        return [self convertNativeObjectToValueRef:object];
    }
}

- (nullable HMBaseValue *)objectForKeyedSubscript:(id)key {
    if (![key isKindOfClass:NSString.class]) {
        return nil;
    }

    return self.globalObject[key];
}

- (void)setObject:(id)object forKeyedSubscript:(id)key {
    if (![key isKindOfClass:NSString.class]) {
        return;
    }

    self.globalObject[key] = object;
}

- (nullable HMBaseValue *)getWithValue:(HMBaseValue *)value propertyName:(NSString *)propertyName {
    if (![value isKindOfClass:HMJSCStrongValue.class] || propertyName.length == 0) {
        return nil;
    }
    HMJSCStrongValue *strongValue = (HMJSCStrongValue *) value;
    HMAssertMainQueue();
    if (!JSValueIsObject(self.contextRef, strongValue.valueRef)) {
        return nil;
    }
    JSValueRef exception = NULL;
    JSObjectRef objectRef = JSValueToObject(self.contextRef, strongValue.valueRef, &exception);
    if ([self popExceptionWithErrorObject:&exception] || !objectRef) {
        return nil;
    }
    JSStringRef stringRef = JSStringCreateWithCFString((__bridge CFStringRef) propertyName);
    JSValueRef valueRef = JSObjectGetProperty(self.contextRef, objectRef, stringRef, &exception);
    JSStringRelease(stringRef);
    if ([self popExceptionWithErrorObject:&exception]) {
        return nil;
    }

    return [[HMJSCStrongValue alloc] initWithValueRef:valueRef executor:self];
}

- (void)setWithValue:(HMBaseValue *)value propertyName:(NSString *)propertyName propertyObject:(id)propertyObject {
    HMAssertMainQueue();
    if (![value isKindOfClass:HMJSCStrongValue.class] || propertyName.length == 0) {
        return;
    }
    HMJSCStrongValue *strongValue = (HMJSCStrongValue *) value;
    if (!JSValueIsObject(self.contextRef, strongValue.valueRef)) {
        return;
    }
    JSValueRef exception = NULL;
    JSObjectRef objectRef = JSValueToObject(self.contextRef, strongValue.valueRef, &exception);
    if ([self popExceptionWithErrorObject:&exception] || !objectRef) {
        return;
    }
    JSStringRef stringRef = JSStringCreateWithCFString((__bridge CFStringRef) propertyName);
    JSObjectSetProperty(self.contextRef, objectRef, stringRef, [self convertObjectToValueRef:propertyObject], kJSPropertyAttributeNone, &exception);
    [self popExceptionWithErrorObject:&exception];
    JSStringRelease(stringRef);
}

- (nullable id <HMBaseWeakValueProtocol>)createWeakValueWithStrongValue:(HMBaseValue *)strongValue {
    return [[HMJSCWeakValue alloc] initWithValue:strongValue];
}

- (NSString *)name {
    JSStringRef stringRef = JSGlobalContextCopyName(self.contextRef);
    if (!stringRef) {
        return nil;
    }

    return CFBridgingRelease(JSStringCopyCFString(kCFAllocatorDefault, stringRef));
}

- (nullable NSArray *)convertToArrayWithValue:(HMBaseValue *)value isPortableConvert:(BOOL)isPortableConvert {
    if (value.context != self || ![value isKindOfClass:HMJSCStrongValue.class]) {
        return nil;
    }
    HMJSCStrongValue *strongValue = (HMJSCStrongValue *) value;

    return [self convertValueRefToArray:strongValue.valueRef isPortableConvert:isPortableConvert];
}

- (nullable HMBaseValue *)callWithValue:(HMBaseValue *)value arguments:(NSArray *)arguments {
    HMAssertMainQueue();
    if (![value isKindOfClass:HMJSCStrongValue.class]) {
        return nil;
    }
    HMJSCStrongValue *strongValue = (HMJSCStrongValue *) value;
    if (!JSValueIsObject(self.contextRef, strongValue.valueRef)) {
        return nil;
    }
    JSValueRef exception = NULL;
    JSObjectRef objectRef = JSValueToObject(self.contextRef, strongValue.valueRef, &exception);
    if ([self popExceptionWithErrorObject:&exception] || !JSObjectIsFunction(self.contextRef, objectRef)) {
        return nil;
    }

    return [[HMJSCStrongValue alloc] initWithValueRef:[self callWithFunctionObject:objectRef thisObject:NULL argumentArray:arguments] executor:self];
}

- (nullable HMBaseValue *)invokeMethodWithValue:(HMBaseValue *)value method:(NSString *)method withArguments:(NSArray *)arguments {
    HMAssertMainQueue();
    if (![value isKindOfClass:HMJSCStrongValue.class] || method.length == 0) {
        return nil;
    }
    HMJSCStrongValue *strongValue = (HMJSCStrongValue *) value;
    if (!JSValueIsObject(self.contextRef, strongValue.valueRef)) {
        return nil;
    }
    JSValueRef exception = NULL;
    JSObjectRef objectRef = JSValueToObject(self.contextRef, strongValue.valueRef, &exception);
    if ([self popExceptionWithErrorObject:&exception] || !objectRef) {
        return nil;
    }

    JSStringRef stringRef = JSStringCreateWithCFString((__bridge CFStringRef) method);
    JSValueRef valueRef = JSObjectGetProperty(self.contextRef, objectRef, stringRef, &exception);
    JSStringRelease(stringRef);
    if ([self popExceptionWithErrorObject:&exception] || !JSValueIsObject(self.contextRef, valueRef)) {
        return nil;
    }
    JSObjectRef functionObjectRef = JSValueToObject(self.contextRef, valueRef, &exception);
    if ([self popExceptionWithErrorObject:&exception] || !JSObjectIsFunction(self.contextRef, functionObjectRef)) {
        return nil;
    }

    return [[HMJSCStrongValue alloc] initWithValueRef:[self callWithFunctionObject:functionObjectRef thisObject:objectRef argumentArray:arguments] executor:self];
}

- (void)dealloc {
    HMAssertMainQueue();
    NSEnumerator<HMJSCStrongValue *> *strongValueEnumerator = _strongValueReleasePool.objectEnumerator;
    HMJSCStrongValue *strongValue = nil;
    while ((strongValue = strongValueEnumerator.nextObject)) {
        [strongValue forceUnprotectWithGlobalContextRef:_contextRef];
    }

    JSGlobalContextRelease(_contextRef);
    NSEnumerator<id <HMBaseExecutorProtocol>> *enumerator = HMExecutorMap.objectEnumerator;
    id <HMBaseExecutorProtocol> value = nil;
    BOOL isNoExecutor = YES;
    while ((value = enumerator.nextObject)) {
        if ([value isKindOfClass:HMJSCExecutor.class]) {
            isNoExecutor = NO;
            break;
        }
    }

    if (isNoExecutor) {
        virtualMachineRef ? JSContextGroupRelease(virtualMachineRef) : nil;
        virtualMachineRef = nil;
    }
}

- (void)setName:(NSString *)name {
    if (name.length == 0) {
        name = @"Hummer JSContext";
    }
    JSStringRef stringRef = JSStringCreateWithCFString((__bridge CFStringRef) name);
    JSGlobalContextSetName(self.contextRef, stringRef);
    JSStringRelease(stringRef);
}

- (nullable HMFunctionType)convertValueRefToFunction:(JSValueRef)valueRef {
    HMAssertMainQueue();
    if (!JSValueIsObject(self.contextRef, valueRef)) {
        return nil;
    }
    JSValueRef exception = NULL;
    JSObjectRef objectRef = JSValueToObject(self.contextRef, valueRef, &exception);
    if ([self popExceptionWithErrorObject:&exception]) {
        return nil;
    }
    if (!JSObjectIsFunction(self.contextRef, objectRef)) {
        return nil;
    }

    JSStringRef privateStringRef = JSStringCreateWithUTF8CString("_privateFunction");
    JSValueRef privateValueRef = JSObjectGetProperty(self.contextRef, objectRef, privateStringRef, &exception);
    JSStringRelease(privateStringRef);
    if ([self popExceptionWithErrorObject:&exception]) {
        return nil;
    }

    // 是原先原生转成的 JS 闭包
    if (JSValueIsObject(self.contextRef, privateValueRef)) {
        JSObjectRef privateObjectRef = JSValueToObject(self.contextRef, valueRef, &exception);
        if (![self popExceptionWithErrorObject:&exception] && privateObjectRef && JSObjectGetPrivate(privateObjectRef) && [(__bridge id) JSObjectGetPrivate(privateObjectRef) isKindOfClass:NSClassFromString(@"NSBlock")]) {
            // 本次 JS 闭包是原生返回，复用原先的闭包
            return (__bridge HMFunctionType _Nullable) JSObjectGetPrivate(privateObjectRef);
        }
    }

    HMJSCStrongValue *valueWrapper = [[HMJSCStrongValue alloc] initWithValueRef:valueRef executor:self];
    // 出于主线程不阻塞原则，返回值只能使用回调返回
    HMFunctionType functionType = ^(NSArray *_Nullable argumentArray) {
        HMAssertMainQueue();
        if (valueWrapper.context) {
            // 当前还未被销毁
            // 重新判断一次 valueRef
            HMJSCExecutor *executor = (HMJSCExecutor *) valueWrapper.context;
            if (!JSValueIsObject(executor.contextRef, valueWrapper.valueRef)) {
                return (HMJSCStrongValue *) nil;
            }
            JSValueRef inlineException = NULL;
            JSObjectRef inlineObjectRef = JSValueToObject(executor.contextRef, valueWrapper.valueRef, &inlineException);
            if ([executor popExceptionWithErrorObject:&inlineException]) {
                return (HMJSCStrongValue *) nil;
            }
            if (!JSObjectIsFunction(executor.contextRef, inlineObjectRef)) {
                return (HMJSCStrongValue *) nil;
            }

            JSValueRef returnValueRef = [executor callWithFunctionObject:inlineObjectRef thisObject:NULL argumentArray:argumentArray];
            if (returnValueRef) {
                return [[HMJSCStrongValue alloc] initWithValueRef:returnValueRef executor:executor];
            }
        }

        return (HMJSCStrongValue *) nil;
    };
    [functionType setHmValue:valueWrapper];

    return functionType;
}

- (nullable JSValueRef)callWithFunctionObject:(nullable JSObjectRef)functionObjectRef thisObject:(nullable JSObjectRef)thisObjectRef argumentArray:(nullable NSArray *)argumentArray {
    JSValueRef exception = NULL;
    JSValueRef returnValueRef = NULL;
    if (argumentArray.count <= 8) {
        // stack
        JSValueRef valueRefArray[argumentArray.count];
        for (NSUInteger i = 0; i < argumentArray.count; ++i) {
            valueRefArray[i] = [self convertObjectToValueRef:argumentArray[i]];
        }
        returnValueRef = JSObjectCallAsFunction(self.contextRef, functionObjectRef, thisObjectRef, argumentArray.count, valueRefArray, &exception);
    } else {
        // heap
        NSUInteger count = argumentArray.count;
        JSValueRef *valueRefArray = NULL;
        if (count) {
            // malloc(0) return NULL or unique pointer that will be passed to free() safely
            valueRefArray = malloc(count * sizeof(JSValueRef));
            if (valueRefArray == NULL) {
                count = 0;
                HMAssert(NO, @"malloc() ENOMEM");
                if (errno) {
                    errno = 0;
                }
            }
        }
        
        if (count > 0) {
            [argumentArray enumerateObjectsUsingBlock:^(id obj, NSUInteger idx, BOOL *stop) {
                valueRefArray[idx] = [self convertObjectToValueRef:obj];
            }];
        }
        returnValueRef = JSObjectCallAsFunction(self.contextRef, functionObjectRef, thisObjectRef, count, valueRefArray, &exception);
        free(valueRefArray);
    }
    // 业务代码需要抛出异常
    [self popExceptionWithErrorObject:&exception];
#ifdef HMDEBUG
    HMBaseValue *thisValue = [[HMJSCStrongValue alloc] initWithValueRef:thisObjectRef executor:self];
    HMJSContext *context = [[HMJSGlobal globalObject] currentContext:self];
    JSStringRef namePropertyName = JSStringCreateWithUTF8CString("name");
    JSValueRef lengthValueRef = JSObjectGetProperty(self.contextRef, functionObjectRef, namePropertyName, NULL);
    JSStringRelease(namePropertyName);
    NSString *name = [self convertValueRefToString:lengthValueRef isForce:YES];
    [HMJSCallerInterceptor callJSWithTarget:thisValue functionName:name args:argumentArray context:context];
#endif
    
    return returnValueRef;
}

- (nullable NSArray *)convertValueRefToArray:(JSValueRef)valueRef isPortableConvert:(BOOL)isPortableConvert {
    HMAssertMainQueue();
    if (![self valueRefIsArray:valueRef]) {
        return nil;
    }
    JSValueRef exception = NULL;
    JSObjectRef objectRef = JSValueToObject(self.contextRef, valueRef, &exception);
    if ([self popExceptionWithErrorObject:&exception] || !objectRef) {
        return nil;
    }
    JSStringRef lengthPropertyName = JSStringCreateWithUTF8CString("length");
    JSValueRef lengthValueRef = JSObjectGetProperty(self.contextRef, objectRef, lengthPropertyName, &exception);
    JSStringRelease(lengthPropertyName);
    if ([self popExceptionWithErrorObject:&exception] || !JSValueIsNumber(self.contextRef, lengthValueRef)) {
        HMLogError(@"array.length 不是数字");

        return nil;
    }
    
    unsigned int length = [self convertValueRefToNumber:lengthValueRef isForce:NO].unsignedIntValue;
    NSMutableArray *resultArray = [NSMutableArray arrayWithCapacity:length];
    for (unsigned int i = 0; i < length; ++i) {
        JSValueRef indexValue = JSObjectGetPropertyAtIndex(self.contextRef, objectRef, i, &exception);
        if ([self popExceptionWithErrorObject:&exception]) {
            continue;
        }
        id resultObject = [self convertValueRefToObject:indexValue isPortableConvert:isPortableConvert];
        if (resultObject) {
            [resultArray addObject:resultObject];
        } else {
            // 兼容 JavaScriptCore toObject 实现，如果是数组，undefined 也转换为 NSNull.null，但是字典没有这个逻辑
            [resultArray addObject:NSNull.null];
        }
    }

    return resultArray.copy;
}

- (nullable NSDictionary<NSString *, id> *)convertToDictionaryWithValue:(HMBaseValue *)value isPortableConvert:(BOOL)isPortableConvert {
    if (value.context != self || ![value isKindOfClass:HMJSCStrongValue.class]) {
        return nil;
    }
    HMJSCStrongValue *strongValue = (HMJSCStrongValue *) value;

    return [self convertValueRefToDictionary:strongValue.valueRef isPortableConvert:isPortableConvert];
}

- (nullable NSDictionary<NSString *, id> *)convertValueRefToDictionary:(JSValueRef)valueRef isPortableConvert:(BOOL)isPortableConvert {
    HMAssertMainQueue();
    if (!JSValueIsObject(self.contextRef, valueRef)) {
        return nil;
    }
    // 1. 是对象
    // 2. 不是数组
    // 3. 不是闭包
    // 4. 不是原生对象
    if ([self valueRefIsArray:valueRef]) {
        return nil;
    }
    if ([self valueRefIsFunction:valueRef]) {
        return nil;
    }
    if ([self valueRefIsNativeObject:valueRef]) {
        return nil;
    }
    JSValueRef exception = NULL;
    JSObjectRef objectRef = JSValueToObject(self.contextRef, valueRef, &exception);
    // JSObjectCopyPropertyNames 要求非空对象
    if ([self popExceptionWithErrorObject:&exception] || !objectRef) {
        return nil;
    }
    // 字典转换
    JSPropertyNameArrayRef propertyNameArrayRef = JSObjectCopyPropertyNames(self.contextRef, objectRef);
    size_t count = JSPropertyNameArrayGetCount(propertyNameArrayRef);
    NSMutableDictionary<NSString *, id> *resultDictionary = [NSMutableDictionary dictionaryWithCapacity:count];
    for (size_t i = 0; i < count; ++i) {
        JSStringRef propertyName = JSPropertyNameArrayGetNameAtIndex(propertyNameArrayRef, i);
        NSString *propertyNameString = CFBridgingRelease(JSStringCopyCFString(kCFAllocatorDefault, propertyName));
        if (propertyNameString.length == 0) {
            // key 不能为 nil
            continue;
        }
        JSValueRef propertyValueRef = JSObjectGetProperty(self.contextRef, objectRef, propertyName, &exception);
        if ([self popExceptionWithErrorObject:&exception]) {
            continue;
        }
        id objectValue = [self convertValueRefToObject:propertyValueRef isPortableConvert:isPortableConvert];
        if (objectValue) {
            resultDictionary[propertyNameString] = objectValue;
        }
    }
    JSPropertyNameArrayRelease(propertyNameArrayRef);

    return resultDictionary.copy;
}

- (nullable id)convertToObjectWithValue:(HMBaseValue *)value isPortableConvert:(BOOL)isPortableConvert {
    if (value.context != self || ![value isKindOfClass:HMJSCStrongValue.class]) {
        return nil;
    }
    HMJSCStrongValue *strongValue = (HMJSCStrongValue *) value;

    return [self convertValueRefToObject:strongValue.valueRef isPortableConvert:isPortableConvert];
}

- (nullable id)convertValueRefToObject:(JSValueRef)valueRef isPortableConvert:(BOOL)isPortableConvert {
    if (JSValueIsUndefined(self.contextRef, valueRef)) {
        return nil;
    }
    
    // 兼容需要
    if (JSValueIsNull(self.contextRef, valueRef)) {
        return NSNull.null;
    }

    id returnValue = [self convertValueRefToString:valueRef isForce:NO];
    if (returnValue) {
        return returnValue;
    }
    returnValue = [self convertValueRefToNumber:valueRef isForce:NO];
    if (returnValue) {
        return returnValue;
    }

    if (!isPortableConvert) {
        // 原生对象
        returnValue = [self convertValueRefToNativeObject:valueRef];
        if (returnValue) {
            return returnValue;
        }

        // 闭包需要比字典优先判断
        returnValue = [self convertValueRefToFunction:valueRef];
        if (returnValue) {
            return returnValue;
        }
    }

    returnValue = [self convertValueRefToArray:valueRef isPortableConvert:isPortableConvert];
    if (returnValue) {
        return returnValue;
    }

    returnValue = [self convertValueRefToDictionary:valueRef isPortableConvert:isPortableConvert];
    if (returnValue) {
        return returnValue;
    }

    return nil;
}

- (void)addExceptionHandler:(HMExceptionHandler)handler key:(id)key {
    [self.exceptionHandlerMap setObject:handler forKey:key];
}

- (void)addConsoleHandler:(HMConsoleHandler)handler key:(id)key {
    [self.consoleHandlerMap setObject:handler forKey:key];
}

- (void)triggerExceptionHandler:(HMExceptionModel *)model {
    
    NSEnumerator *enumer = [self.exceptionHandlerMap objectEnumerator];
    HMExceptionHandler handler = [enumer nextObject];
    while (handler) {
        handler(model);
        handler = [enumer nextObject];
    }
}

- (void)triggerConsoleHandler:(NSString *)logString level:(HMLogLevel)logLevel {

    NSEnumerator *enumer = [self.consoleHandlerMap objectEnumerator];
    HMConsoleHandler handler = [enumer nextObject];
    while (handler) {
        handler(logString, logLevel);
        handler = [enumer nextObject];
    }
}


@end

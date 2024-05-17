//
//  HMExportManager.m
//  Hummer
//
//  Copyright © 2019年 didi. All rights reserved.
//

#import "HMExportManager.h"
#import "HMLogger.h"
#import <dlfcn.h>
#import <mach-o/getsect.h>
#import "HMExportClass.h"
#import <objc/runtime.h>
#import "HMUtility.h"

NS_ASSUME_NONNULL_BEGIN

@interface HMExportManager ()

@property (nonatomic, copy, nullable) NSDictionary<NSString *, HMExportClass *> *jsClasses;

@property (nonatomic, copy, nullable) NSDictionary<NSString *, HMExportClass *> *objcClasses;

@end

NS_ASSUME_NONNULL_END

@implementation HMExportManager

static id _sharedInstance = nil;

+ (instancetype)sharedInstance {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        _sharedInstance = [[self alloc] init];
    });

    return _sharedInstance;
}

- (instancetype)init {
    self = [super init];

    return self;
}

- (void)loadAllExportedComponent {
    if (self.jsClasses.count > 0 || self.objcClasses.count > 0) {
        return;
    } else {
        /**
         结构体，用于存储动态链接器加载的模块
         const char *dli_fname：模块的路径名，即文件名。
         void *dli_fbase：模块的基址，即模块在内存中的起始地址。
         */
        Dl_info info;
        //dladdr 函数通过传递指向 _sharedInstance 的指针和一个 Dl_info 结构体的指针来填充 Dl_info 结构体，从而获取到了当前可执行文件的信息，特别是基址信息，用于后续的操作。
        dladdr(&_sharedInstance, &info);

#ifdef __LP64__
        //addr 变量用于存储某些地址值
        uint64_t addr = 0;
        //mach_header 的值被设置为模块的基址，用作后续操作中的参考值。
        const uint64_t mach_header = (uint64_t) info.dli_fbase;
        //获取当前可执行文件中名为 "hm_export_class" 的 __DATA 段的信息，并将其赋值给 section 变量，以供后续使用。
        const struct section_64 *section = getsectbynamefromheader_64((void *) mach_header, "__DATA", "hm_export_class");
#else
        uint32_t addr = 0; const uint32_t mach_header = (uint32_t)info.dli_fbase;
        const struct section *section = getsectbynamefromheader((void *)mach_header, "__DATA", "hm_export_class");
#endif
        if (section) {
            NSMutableDictionary<NSString *, HMExportClass *> *jsClassesMutableDictionary = nil;
            NSMutableDictionary<NSString *, HMExportClass *> *objcClassesMutableDictionary = nil;

            // 原因为 UIWebView 从子线程通过 objc_msgSend 访问，实际上不存在危害，属于触发了苹果兜底警告
            // 代码见 HMExportClass -> - loadMethodOrProperty:withSelector: -> objc_msgSend
            HMLogDebug(@"--- 此框内如果出现 WebKit Threading Violation - initial use of WebKit from a secondary thread. 日志可以忽略 ---");
            for (addr = section->offset; addr < section->offset + section->size; addr += sizeof(HMExportStruct)) {
                HMExportStruct *component = (HMExportStruct *) (mach_header + addr);
                if (!component) {
                    continue;
                }

                NSString *jsClass = [NSString stringWithUTF8String:component->jsClass];
                NSString *objcClass = [NSString stringWithUTF8String:component->objcClass];

                HMExportClass *exportClass = [[HMExportClass alloc] init];
                exportClass.className = objcClass;
                exportClass.jsClass = jsClass;
                // 调用方法加载 method property
                [exportClass loadAllExportMethodAndProperty];

                if (jsClassesMutableDictionary.count == 0) {
                    // sizeof 返回 size_t -> unsigned int
                    jsClassesMutableDictionary = [NSMutableDictionary dictionaryWithCapacity:section->size / sizeof(HMExportStruct)];
                }
                if (objcClassesMutableDictionary.count == 0) {
                    objcClassesMutableDictionary = [NSMutableDictionary dictionaryWithCapacity:section->size / sizeof(HMExportStruct)];
                }
                jsClassesMutableDictionary[jsClass] = exportClass;
                objcClassesMutableDictionary[objcClass] = exportClass;
            }
            HMLogDebug(@"--- 结束 ---");
            if (jsClassesMutableDictionary.count > 0) {
                self.jsClasses = jsClassesMutableDictionary.copy;
            }
            if (objcClassesMutableDictionary.count > 0) {
                self.objcClasses = objcClassesMutableDictionary.copy;
            }
            [jsClassesMutableDictionary enumerateKeysAndObjectsUsingBlock:^(NSString *key, HMExportClass *obj, BOOL *stop) {
                NSParameterAssert(obj.className);
                Class clazz = NSClassFromString(obj.className);
                NSParameterAssert(clazz);
                if (!clazz) {
                    return;
                }
                /*
                 *调用 `class_getSuperclass(clazz)` 来获取 `clazz` 的父类。
                 * 将返回的父类赋值给 `clazz`，以便在下一次循环迭代中处理这个新的父类。
                 * `(void)` 是一个类型转换，用于忽略逗号表达式的值（在这里是新的 `clazz` 的值），因为 `while` 循环只需要检查后面的条件 `clazz && clazz != NSObject.class`。
                 * `clazz && clazz != NSObject.class` 确保 `clazz` 不是 `nil` 并且它不等于 `NSObject` 类。
                 */
                while ((void) (clazz = class_getSuperclass(clazz)), clazz && clazz != NSObject.class) {
                    //使用 `NSStringFromClass(clazz)` 获取当前 `clazz` 类的字符串表示（即类名）。
                    NSString *className = NSStringFromClass(clazz);
                    //尝试从 `objcClassesMutableDictionary` 字典中使用这个类名作为键来查找对应的 `HMExportClass` 对象。
                    HMExportClass *exportClass = objcClassesMutableDictionary[className];
                    //如果找到了 `HMExportClass` 对象（即 `exportClass` 不为 `nil`），则设置 `obj.superClassReference` 为这个 `exportClass` 并立即跳出循环。
                    if (exportClass) {
                        // 查找到了，停止循环
                        obj.superClassReference = exportClass;
                        break;
                    }
                }
            }];
            NSLog(@"");
        } else {
            HMLogError(@"没有导出组件");
        }
    }
}

@end

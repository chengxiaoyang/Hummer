//
//  HMExportClass.m
//  Hummer
//
//  Copyright © 2019年 didi. All rights reserved.
//

#import "HMExportClass.h"

#import <objc/runtime.h>
#import <objc/message.h>
#import "HMExportMethod.h"
#import "HMUtility.h"
#import "HMExportProperty.h"
#import "HMExportBaseClass.h"

@interface HMExportClass ()

NS_ASSUME_NONNULL_BEGIN

@property (nonatomic, nullable, copy) NSDictionary<NSString *, HMExportBaseClass *> *classMethodPropertyList;

@property (nonatomic, nullable, copy) NSDictionary<NSString *, HMExportBaseClass *> *instanceMethodPropertyList;
//方法中，使用 Objective-C 运行时的函数 objc_msgSend 调用指定的方法或属性，并将其转换为 HMExportBaseClass 对象。
- (void)loadMethodOrProperty:(Class)clazz withSelector:(SEL)selector isClassMethodProperty:(BOOL)isClassMethodProperty;

NS_ASSUME_NONNULL_END

@end

//这段代码的主要功能是在运行时加载和管理 Objective-C 类中的导出方法和属性，以便在 JavaScript 中调用和使用。
@implementation HMExportClass

//方法用于加载所有的导出方法和属性。
- (void)loadAllExportMethodAndProperty {
    // 加载当前信息
    NSParameterAssert(self.className);
    Class clazz = NSClassFromString(self.className);
    NSParameterAssert(clazz);
    if (!clazz) {
        return;
    }
    unsigned int outCount = 0;
    // 不包含父类
    Method *methods = class_copyMethodList(object_getClass(clazz), &outCount);
    for (int i = 0; i < outCount; ++i) {
        SEL selector = method_getName(methods[i]);
        const char *charSelector = sel_getName(selector);
        if (charSelector[0] != '_') {
            continue;
        }
        
        if (strstr(charSelector, "__hm_export_method_") == charSelector || strstr(charSelector, "__hm_export_property_") == charSelector) {
            BOOL isClass = (strstr(charSelector, "__hm_export_method_class_") == charSelector) || (strstr(charSelector, "__hm_export_property_class_") == charSelector);
            [self loadMethodOrProperty:clazz withSelector:selector isClassMethodProperty:isClass];
        }
    }
    // 需要 free
    if (methods) {
        free(methods);
    }
    // 不需要加载父类信息
}

//方法用于根据名称查询属性。
- (HMExportProperty *)propertyWithName:(NSString *)name isClass:(BOOL)isClass {
    HMExportBaseClass *exportProperty = nil;
    if (isClass) {
        exportProperty = self.classMethodPropertyList[name];
    } else {
        exportProperty = self.instanceMethodPropertyList[name];
    }
    if (![exportProperty isKindOfClass:HMExportProperty.class]) {
        return nil;
    }
    
    return (HMExportProperty *) exportProperty;
}

//方法用于根据名称查询方法
- (HMExportMethod *)methodWithName:(NSString *)name isClass:(BOOL)isClass {
    HMExportBaseClass *exportMethod = nil;
    if (isClass) {
        exportMethod = self.classMethodPropertyList[name];
    } else {
        exportMethod = self.instanceMethodPropertyList[name];
    }
    if (![exportMethod isKindOfClass:HMExportMethod.class]) {
        return nil;
    }
    
    return (HMExportMethod *) exportMethod;
}

//方法中，使用 Objective-C 运行时的函数 objc_msgSend 调用指定的方法或属性，并将其转换为 HMExportBaseClass 对象。
//然后根据是否为类方法或实例方法，将其存储到相应的列表中。
- (void)loadMethodOrProperty:(Class)clazz withSelector:(SEL)selector isClassMethodProperty:(BOOL)isClassMethodProperty {
    //这是Objective-C的运行时函数，用于向一个对象发送消息（即调用方法）。
    //它的典型签名是 id objc_msgSend(id self, SEL op, ...)，其中self是接收消息的对象，op是要调用的方法的SEL（选择器），而...表示方法的参数列表。
    id exportMethodObject = ((id (*)(id, SEL)) objc_msgSend)(clazz, selector);
    if (![exportMethodObject isKindOfClass:HMExportBaseClass.class]) {
        HMLogError(@"export [%@] error", NSStringFromSelector(selector));
        
        return;
    }
    
    HMExportBaseClass *exportBaseClass = exportMethodObject;
    SEL testSelector = [exportBaseClass getTestSelector];
    if (!isClassMethodProperty) {
        // 兼容判断
        if (class_getClassMethod(clazz, testSelector) && class_getInstanceMethod(clazz, testSelector)) {
            // 同名方法取实例方法
            HMLogWarning(@"存在 Class/Instance 同名方法 %@，为了保持兼容，取实例方法", exportBaseClass.jsFieldName);
        } else if (class_getClassMethod(clazz, testSelector)) {
            isClassMethodProperty = YES;
            HMLogWarning(@"请使用 HM_EXPORT_CLASS_METHOD/PROPERTY 来导出类方法类属性");
        }
     }
    NSMutableDictionary<NSString *, __kindof HMExportBaseClass *> *baseObjectList = nil;
    if (isClassMethodProperty) {
        baseObjectList = self.classMethodPropertyList.mutableCopy;
        self.classMethodPropertyList = nil;
    } else {
        baseObjectList = self.instanceMethodPropertyList.mutableCopy;
        self.instanceMethodPropertyList = nil;
    }
    if (baseObjectList.count == 0) {
        baseObjectList = NSMutableDictionary.dictionary;
    }
    baseObjectList[exportBaseClass.jsFieldName] = exportBaseClass;
    if (isClassMethodProperty) {
        self.classMethodPropertyList = baseObjectList;
    } else {
        self.instanceMethodPropertyList = baseObjectList;
    }
}

//方法用于根据名称查询方法或属性
- (nullable HMExportBaseClass *)methodOrPropertyWithName:(NSString *)name isClass:(BOOL)isClass {
    HMExportBaseClass *exportMethod = nil;
    if (isClass) {
        exportMethod = self.classMethodPropertyList[name];
    } else {
        exportMethod = self.instanceMethodPropertyList[name];
    }

    return exportMethod;
}

@end

//
//  HMAttrManager.m
//  Hummer
//
//  Copyright © 2019年 didi. All rights reserved.
//

#import "HMAttrManager.h"

#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>

//这个类用于表示视图属性和 CSS 样式属性之间的对应关系。
@interface HMViewAttribute()
//视图属性名称
@property (nonatomic, strong) NSString *viewProp;
//CSS 样式属性名称
@property (nonatomic, strong) NSString *cssAttr;
//属性转换的方法选择器
@property (nonatomic, assign) SEL converter;

@end

@implementation HMViewAttribute

//方法初始化对象
- (instancetype)initWithProperty:(NSString *)viewProp
                         cssAttr:(NSString *)cssAttr
                       converter:(SEL)converter {
    self = [super init];
    if (self) {
        _viewProp = viewProp;
        _cssAttr = cssAttr;
        _converter = converter;
    }
    return self;
}

//方法简化创建实例的过程。
+ (instancetype)viewAttrWithName:(NSString *)viewProp
                         cssAttr:(NSString *)cssAttr
                       converter:(SEL)converter {
    return [[self alloc] initWithProperty:viewProp
                                  cssAttr:cssAttr
                                converter:converter];
}

@end

@interface HMAttrManager()

@property (nonatomic, strong) NSMutableDictionary *attrs;
@property (nonatomic, strong) NSMutableArray * classes;

@end

@implementation HMAttrManager

static HMAttrManager * __sharedInstance = nil;

+ (instancetype)sharedManager {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        if (__sharedInstance == nil) {
            __sharedInstance = [[self alloc] init];
        }
    });
    return __sharedInstance;
}

+ (instancetype)allocWithZone:(struct _NSZone *)zone {
    @synchronized(self) {
        if (__sharedInstance == nil) {
            __sharedInstance = [super allocWithZone:zone];
        }
    }
    return __sharedInstance;
}

- (NSMutableDictionary *)attrs {
    if (!_attrs) {
        _attrs = [NSMutableDictionary dictionary];
    }
    return _attrs;
}

- (NSMutableArray *)classes {
    if (!_classes) {
        _classes = [NSMutableArray array];
    }
    return _classes;
}

//方法加载指定类的视图属性
- (void)loadViewAttrForClass:(Class)clazz {
    if (!clazz || ![clazz isSubclassOfClass:[UIView class]]) return;
    
    if (![self.classes containsObject:clazz]) {
        [self.classes addObject:clazz];
        [self loadAllAttrWithClass:clazz];
    }
}

//递归加载指定类及其父类的视图属性。
- (void)loadAllAttrWithClass:(Class)cls {
    if (cls != [UIView class]) {
        Class superCls = class_getSuperclass(cls);
        [self loadAllAttrWithClass:superCls];
    }
    [self addViewAttrForClass:cls];
}

//方法解析指定类的方法列表，提取以 __hm_view_attribute_ 开头的方法，并将其返回的 HMViewAttribute 对象中的 CSS 属性添加到映射字典中。
- (void)addViewAttrForClass:(Class)clazz {
    if (!clazz || ![clazz isSubclassOfClass:[UIView class]]) return;
    
    unsigned int outCount = 0;
    Method *methods = class_copyMethodList(object_getClass(clazz), &outCount);
    for (NSInteger idx = 0; idx < outCount; idx++) {
        SEL selector = method_getName(methods[idx]);
        NSString *methodName = NSStringFromSelector(selector);
        if ([methodName hasPrefix:@"__hm_view_attribute_"] &&
            [clazz respondsToSelector:selector]) {
            HMViewAttribute *object = ((HMViewAttribute*(*)(id, SEL))objc_msgSend)(clazz, selector);
            if (object && object.cssAttr) self.attrs[object.cssAttr] = object;
        }
    }
    if (methods) free(methods);
}

//方法根据 CSS 属性名称获取对应的转换方法选择器。
- (SEL)converterWithCSSAttr:(NSString *)cssAttr {
    if (!cssAttr) return nil;
    
    HMViewAttribute *object = self.attrs[cssAttr];
    return object.converter;
}

//方法根据 CSS 属性名称获取对应的视图属性名称。
- (NSString *)viewPropWithCSSAttr:(NSString *)cssAttr {
    if (!cssAttr) return nil;
    
    HMViewAttribute *object = self.attrs[cssAttr];
    return object.viewProp;
}

@end

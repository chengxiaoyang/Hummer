//
//  HMViewController.h
//  Hummer
//
//  Copyright © 2019年 didi. All rights reserved.
//

#import "HMViewController.h"
#import "Hummer.h"
#import "HMJSGlobal.h"
#import <Hummer/HMBaseExecutorProtocol.h>
#import <Hummer/HMRootViewLifeCycle.h>
#import "HMBaseValue.h"

#if __has_include(<SocketRocket/SRWebSocket.h>)
#import <SocketRocket/SRWebSocket.h>
#endif

@interface HMViewController ()<HMJSContextDelegate>

@property (nonatomic, strong) UIView *naviView;
@property (nonatomic, strong) UIView *hmRootView;


@property (nonatomic, strong) HMJSContext  *context;
@property (nonatomic, strong) HMBaseValue *renderPage;
//RootView生命周期函数
@property (nonatomic, strong) HMRootViewLifeCycle *lifeCycle;


@end

@implementation HMViewController

+ (instancetype)hmxPageControllerWithURL:(NSString *)URL
                                  params:(NSDictionary *)params {
    if (!URL) {
        return nil;
    }
    return [[self alloc] initWithURL:URL params:params];
}

- (instancetype)initWithURL:(NSString *)URL
                     params:(NSDictionary *)params {
    if (self = [super init]) {
        self.URL = URL ;
        self.params = params;
    }
    return self;
}

- (void)addCustomNavigationView:(UIView *)customNaviView {
    if (nil == customNaviView) {
        return;
    }
    [self.naviView removeFromSuperview];
    [self.view addSubview:customNaviView];
    self.naviView = customNaviView;
    
    CGFloat naviHeight = self.naviView ? CGRectGetHeight(self.naviView.frame) : 0;
    CGFloat hmHeight = CGRectGetHeight(self.view.bounds) - naviHeight;
    CGFloat hmWidth = CGRectGetWidth(self.view.bounds);
    
    CGRect containerFrame = CGRectMake(0, naviHeight, hmWidth, hmHeight);
    self.hmRootView.frame = containerFrame;
}

- (void)initHMRootView {
    /** hummer渲染view */
    self.hmRootView = [[UIView alloc] initWithFrame:self.view.bounds];
    self.hmRootView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.view addSubview:self.hmRootView];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor whiteColor];
    self.automaticallyAdjustsScrollViewInsets = NO;
    self.lifeCycle = [HMRootViewLifeCycle create];
    [self initHMRootView];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(didBecomeActive) name:UIApplicationDidBecomeActiveNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(didEnterBackground) name:UIApplicationDidEnterBackgroundNotification object:nil];
    
    if (!self.hm_pageID.length) {
        self.hm_pageID = @([self hash]).stringValue;
    }
    
    if ([[NSURL URLWithString:self.URL].pathExtension containsString:@"js"] && ([self.URL hasPrefix:@"http"] ||[self.URL hasPrefix:@"https"]))
    {// hummer js 模式加载
        __weak typeof(self)weakSelf = self;
        [HMJavaScriptLoader loadBundleWithURL:[NSURL URLWithString:self.URL] onProgress:^(HMLoaderProgress *progressData) {
        } onComplete:^(NSError *error, HMDataSource *source) {
            __strong typeof(self) self = weakSelf;
            if (!error) {
                HMExecOnMainQueue(^{
                    NSString *script = [[NSString alloc] initWithData:source.data encoding:NSUTF8StringEncoding];
                    [self renderWithScript:script];
                });
            }
        }];
    }else {
        //hummer 离线包模式加载
        NSString * script = nil;
        if (self.loadBundleJSBlock) {
            script = HM_SafeRunBlock(self.loadBundleJSBlock,self.URL);
        }else if ([[NSURL URLWithString:self.URL].pathExtension containsString:@"js"] && [self.URL hasPrefix:@"file"]){
            script = [NSString stringWithContentsOfURL:[NSURL URLWithString:self.URL] encoding:NSUTF8StringEncoding error:nil];
        }
        [self renderWithScript:script];
    }
}


- (void)didBecomeActive {
    UIViewController *vc = HMTopViewController();
    if (vc != self) {
        return;
    }
    [self.lifeCycle onAppear];
}

- (void)didEnterBackground{
    UIViewController *vc = HMTopViewController();
    if (vc != self) {
        return;
    }
    [self.lifeCycle onDisappear];
}
#pragma mark -渲染脚本

- (void)renderWithScript:(NSString *)script {
    if (script.length == 0) {
        return;
    }
    
    //设置页面参数
    NSMutableDictionary * pData = [NSMutableDictionary dictionary];
    if (self.URL) {
        pData[@"url"]=self.URL;
    }
    pData[@"params"] = self.params ?: @{};
    
    //渲染脚本之前 注册bridge
    NSString *namespace = nil;
    //没有搞懂这是干嘛的
    if ([self respondsToSelector:@selector(hm_namespace)]) {
        namespace = [self hm_namespace];
    }
    HMJSContext *context = [[HMJSContext alloc] initWithNamespace:namespace];
    self.context = context;
    context.rootView = self.hmRootView;
    context.pageInfo = pData;
    context.delegate = self;
    HM_SafeRunBlock(self.registerJSBridgeBlock,context);
    
    //执行脚本
    [context evaluateScript:script fileName:self.URL];
}

#pragma mark - View 生命周期管理
- (BOOL)hm_didClickGoBack {
    if ([[self callJSWithFunc:@"onBack" arguments:@[]] toBool]) {return YES;}
    if ([self respondsToSelector:@selector(hm_triggerNativeGoBack)]) {
        [self hm_triggerNativeGoBack];
    }else{
        if (self.navigationController) {
            [self.navigationController popViewControllerAnimated:YES];
        }
    }
    return NO;
}
- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    [self.lifeCycle onAppear];
}

- (void)viewDidDisappear:(BOOL)animated {
    [super viewDidDisappear:animated];
    [self.lifeCycle onDisappear];
}

- (void)didMoveToParentViewController:(UIViewController *)parent {
    if (!parent) {
        HMBaseValue * jsPageResult = self.renderPage.context[@"Hummer"][@"pageResult"];
        HM_SafeRunBlock(self.hm_dismissBlock,jsPageResult);
    }
}

- (void)dealloc {
    [self.lifeCycle onDestroy];
    [[NSNotificationCenter defaultCenter] removeObserver:self name:UIApplicationDidBecomeActiveNotification object:nil];
    [[NSNotificationCenter defaultCenter] removeObserver:self name:UIApplicationDidEnterBackgroundNotification object:nil];
}

#pragma mark - Call Hummer

- (HMBaseValue *)callJSWithFunc:(NSString *)func arguments:(NSArray *)arguments {

    return [self.renderPage invokeMethod:func withArguments:arguments];
}


#pragma mark - HMJSContextDelegate
- (void)context:(HMJSContext *)context didRenderFailed:(NSError *)error {
    
}

- (void)context:(HMJSContext *)context didRenderPage:(HMBaseValue *)page {
    self.renderPage = page;
    [self.lifeCycle setJSValue:page];
}

- (void)context:(HMJSContext *)context reloadBundle:(NSDictionary *)bundleInfo {
    
    __weak typeof(self)weakSelf = self;
    HMExecOnMainQueue(^{
        if (!weakSelf) {
            return;
        }
        [self callJSWithFunc:@"onDestroy" arguments:@[]];
        [self.hmRootView.subviews enumerateObjectsUsingBlock:^(__kindof UIView * _Nonnull obj, NSUInteger idx, BOOL * _Nonnull stop) {
            [obj removeFromSuperview];
        }];
        NSString *URLString = [bundleInfo valueForKey:@"url"];
        NSURL * URL  = [NSURL URLWithString:URLString];
        if (!URL) {
            return;
        }
        [HMJavaScriptLoader loadWithSource:URL inJSBundleSource:nil completion:^(NSError * _Nullable error, NSString * _Nullable script) {
            __strong typeof(self) self = weakSelf;
            if (!error) {
                HMExecOnMainQueue(^{
                    [self renderWithScript:script];
                });
            }
        }];
    });
}
@end

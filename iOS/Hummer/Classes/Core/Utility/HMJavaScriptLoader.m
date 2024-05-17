//
//  HMJavaScriptLoader.m
//  Hummer
//
//  Copyright © 2019年 didi. All rights reserved.
//

#import "HMJavaScriptLoader.h"

#import "HMUtility.h"

NSString *const HMJSLoaderErrorDomain = @"HMJSLoaderErrorDomain";

static void syncJsBundleAtURL(NSURL *url,
                              HMLoaderProgressBlock progressBlock,
                              HMLoaderCompleteBlock completeBlock);

@implementation HMLoaderProgress

@end
//这个类负责加载JavaScript包。它包含用于异步加载
@implementation HMDataSource

+ (HMDataSource *) dataSourceCreateWithURL:(NSURL*)url
                                      data:(NSData*)data
                                    lenght:(NSNumber*)length {
    HMDataSource *dataSource = [HMDataSource new];
    dataSource.url = url;
    dataSource.length = length;
    dataSource.data = data;
    
    return dataSource;
}

@end

@implementation HMJavaScriptLoader

+ (void)loadBundleWithURL:(NSURL*)url
                  onProgress:(HMLoaderProgressBlock)progressBlock
                  onComplete:(HMLoaderCompleteBlock)completeBlock {
    unsigned int sourceLen;
    NSError *error;
    NSData *data = [self syncJsBundleAtURL:url
                              sourceLength:&sourceLen
                                     error:&error];
    
    if (data) {
        completeBlock(nil,[HMDataSource dataSourceCreateWithURL:url
                                                           data:data
                                                         lenght:@(sourceLen)]);
        return;
    }
    
    syncJsBundleAtURL(url, progressBlock, completeBlock);
    return;
}

//同步加载JavaScript包
+ (NSData *)syncJsBundleAtURL:(NSURL *)scriptURL
                 sourceLength:(unsigned int *)sourceLength
                        error:(NSError **)error {
    //检查传入的scriptURL是否为nil，如果是，则表示URL为空，将生成一个错误并返回nil。
    if (!scriptURL) {
        if (error) {
            NSString *desc = [NSString stringWithFormat:@"Url is nil. "
                              @"unsanitizedScriptURLString = %@", scriptURL.absoluteString];
            *error = [NSError errorWithDomain:HMJSLoaderErrorDomain
                                         code:HMJSLoaderErrorNoScriptURL
                                     userInfo:@{NSLocalizedDescriptionKey: desc}];
        }
        
        return nil;
    }
    //检查传入的scriptURL是否为nil，如果是，则表示URL为空，将生成一个错误并返回nil。
    if (!scriptURL.fileURL) {
        if (error) {
            *error = [NSError errorWithDomain:HMJSLoaderErrorDomain
                                         code:HMJSLoaderErrorCannotBeLoadedSynchronously
                                     userInfo:@{NSLocalizedDescriptionKey:[NSString stringWithFormat:@"Cannot load %@ URLs synchronously",
                                                scriptURL.scheme]}];
        }
        
        return nil;
    }
    //尝试以只读模式打开指定URL的文件。
    FILE *bundle = fopen(scriptURL.path.UTF8String, "r");
    //检查文件是否成功打开，如果打开失败，则表示无法打开指定的文件，将生成一个错误并返回nil。
    if (!bundle) {
        if (error) {
            NSString *errorString = [NSString stringWithFormat:@"Error opening bundle %@", scriptURL.path];
            NSDictionary *userInfo = @{NSLocalizedDescriptionKey:errorString};
            *error = [NSError errorWithDomain:HMJSLoaderErrorDomain
                                         code:HMJSLoaderErrorFailedOpeningFile
                                     userInfo:userInfo];
        }
        return nil;
    }
    //使用NSData类的方法从文件中读取数据，并存储在source变量中。如果发生错误，会将错误信息保存在error参数中
    NSData *source = [NSData dataWithContentsOfFile:scriptURL.path
                                            options:NSDataReadingMappedIfSafe
                                              error:error];
    //如果传入了sourceLength参数且成功读取了数据，则将读取的数据的长度保存在sourceLength指向的地址中。
    if (sourceLength && source != nil) {
        *sourceLength = (unsigned int)source.length;
    }
    return source;
}

//用于从指定的源加载JavaScript，并在加载完成后调用完成块返回结果
+ (BOOL)loadWithSource:(id<HMURLConvertible>)source inJSBundleSource:(id<HMURLConvertible>)bundleSource completion:(HMJSLoaderCompleteBlock)completion {
    
    NSString *sourceString = [source hm_asString];
    NSURL *url = [source hm_asUrl];
    //检查源是否以.开头。如果是，则表示源是相对于 bundleSource 的相对路径。
    if([sourceString hasPrefix:@"."]){
        //如果源是相对路径，则将其解析为完整的URL，相对路径基于 bundleSource。
        url = [NSURL URLWithString:[source hm_asString] relativeToURL:[bundleSource hm_asUrl]];
    }
    [self loadBundleWithURL:url onProgress:nil onComplete:^(NSError *error, HMDataSource *source) {
        if (completion) {
            NSString *script = [[NSString alloc] initWithData:source.data encoding:NSUTF8StringEncoding];
            completion(error, script);
        }
    }];
    return YES;
    
}

@end

//这段代码是一个用于同步加载JavaScript包的辅助函数
static void syncJsBundleAtURL(NSURL *url,
                              __unused HMLoaderProgressBlock progressBlock,
                              HMLoaderCompleteBlock completeBlock) {
    //检查传入的URL是否为文件URL。如果是文件URL，则在后台线程上异步读取文件内容，并在主线程上调用 completeBlock 完成加载。
    if (url.fileURL) {
        //使用GCD在后台线程上执行异步任务。
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            //尝试从文件中读取数据，并将结果保存在 source 变量中。如果发生错误，会将错误信息保存在 error 变量中。
            NSError *error = nil;
            NSData *source = [NSData dataWithContentsOfFile:url.path
                                                    options:NSDataReadingMappedIfSafe
                                                      error:&error];
            //使用自定义的宏 HMExecOnMainQueue 将代码块调度到主队列上执行。
            HMExecOnMainQueue(^{
                //调用完成块，将错误信息和加载的数据源传递给调用者。
                completeBlock(error,[HMDataSource dataSourceCreateWithURL:url
                                                                     data:source
                                                                   lenght:@(source.length)]);
            });
        });
        return;
    }
    //如果URL不是文件URL，则创建一个NSURLSessionDataTask对象，用于从指定URL异步下载数据。
    NSURLSessionDataTask *dataTask = [[NSURLSession sharedSession] dataTaskWithURL:url
                                                                 completionHandler:^(NSData * _Nullable data,
                                                                                     NSURLResponse * _Nullable response,
                                                                                     NSError * _Nullable error) {
        //异步任务完成后，使用 HMExecOnMainQueue 宏将结果传递给 completeBlock 完成加载。
        HMExecOnMainQueue(^{
            HMDataSource *dataSource = [HMDataSource dataSourceCreateWithURL:url
                                                                        data:data
                                                                      lenght:@(data.length)];
            completeBlock(error, dataSource);
        });
    }];
    [dataTask resume];
}


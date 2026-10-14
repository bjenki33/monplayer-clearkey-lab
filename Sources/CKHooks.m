#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>

static const void *CKTaskData = &CKTaskData;
static const void *CKTaskRejected = &CKTaskRejected;
static IMP CKOriginalTask, CKOriginalURLTask, CKOriginalDownloadTask, CKOriginalURLDownloadTask;
static IMP CKOriginalSessionFactory;
static NSMutableSet<NSValue *> *CKDelegateHooks;
static NSMutableSet<NSValue *> *CKAsyncHooks;

static Class CKRuntimeClass(void) { return NSClassFromString(@"CKRuntime"); }
static void CKNativeEvent(NSInteger code) {
    Class runtime = CKRuntimeClass();
    if ([runtime respondsToSelector:@selector(nativeEvent:)])
        ((void (*)(id, SEL, NSInteger))objc_msgSend)(runtime, @selector(nativeEvent:), code);
}
static void CKObserve(NSData *data, NSURL *url) {
    Class runtime = CKRuntimeClass();
    if (data && [runtime respondsToSelector:@selector(observe:source:)]) {
        ((void (*)(id, SEL, id, id))objc_msgSend)(runtime, @selector(observe:source:), data, url);
    }
}
static BOOL CKSuccessfulResponse(NSURLResponse *response) {
    return ![response isKindOfClass:NSHTTPURLResponse.class] ||
        (((NSHTTPURLResponse *)response).statusCode >= 200 && ((NSHTTPURLResponse *)response).statusCode < 300);
}
static void CKObserveFile(NSURL *file, NSURLResponse *response) {
    NSNumber *size = nil;
    if (!file.isFileURL || !CKSuccessfulResponse(response) ||
        ![file getResourceValue:&size forKey:NSURLFileSizeKey error:nil] || size.unsignedLongLongValue > 4*1024*1024) return;
    NSData *data = [NSData dataWithContentsOfURL:file options:NSDataReadingMappedIfSafe error:nil];
    CKObserve(data, response.URL);
}
static BOOL CKRoute(AVPlayerItem *item) {
    Class runtime = CKRuntimeClass();
    return item && [runtime respondsToSelector:@selector(route:)] &&
        ((BOOL (*)(id, SEL, id))objc_msgSend)(runtime, @selector(route:), item);
}
static AVPlayerItem *CKPlaceholder(void) {
    Class runtime = CKRuntimeClass();
    if ([runtime respondsToSelector:@selector(placeholderItem)]) return ((id (*)(id,SEL))objc_msgSend)(runtime,@selector(placeholderItem));
    return nil;
}
static id CKNativeContext(NSURL *url) {
    Class runtime = CKRuntimeClass();
    if (url && [runtime respondsToSelector:@selector(nativeContextForURL:)])
        return ((id (*)(id, SEL, id))objc_msgSend)(runtime, @selector(nativeContextForURL:), url);
    return nil;
}
static NSURL *CKContextURL(id context) {
    return context ? ((id (*)(id, SEL))objc_msgSend)(context, @selector(url)) : nil;
}
static void CKAttachContext(id context, AVAsset *asset) {
    if (context && asset) ((void (*)(id, SEL, id))objc_msgSend)(context, @selector(attach:), asset);
}
static void CKNativePlaying(AVPlayer *player, float rate) {
    Class runtime = CKRuntimeClass();
    if ([runtime respondsToSelector:@selector(nativePlaying:rate:)])
        ((void (*)(id, SEL, id, float))objc_msgSend)(runtime, @selector(nativePlaying:rate:), player, rate);
}
static NSURLSessionDataTask *CKTask(id self, SEL cmd, NSURLRequest *request,
                                   void (^completion)(NSData *, NSURLResponse *, NSError *)) {
    // Observe the existing completion; never proxy, alter, retry or redirect requests.
    void (^wrapped)(NSData *, NSURLResponse *, NSError *) = completion ? ^(NSData *data, NSURLResponse *response, NSError *error) {
        if (!error && CKSuccessfulResponse(response)) CKObserve(data, response.URL ?: request.URL);
        completion(data, response, error);
    } : nil;
    return ((id (*)(id, SEL, id, id))CKOriginalTask)(self, cmd, request, wrapped);
}
static NSURLSessionDataTask *CKURLTask(id self, SEL cmd, NSURL *url,
                                      void (^completion)(NSData *, NSURLResponse *, NSError *)) {
    void (^wrapped)(NSData *, NSURLResponse *, NSError *) = completion ? ^(NSData *data, NSURLResponse *response, NSError *error) {
        if (!error && CKSuccessfulResponse(response)) CKObserve(data, response.URL ?: url);
        completion(data, response, error);
    } : nil;
    return ((id (*)(id, SEL, id, id))CKOriginalURLTask)(self, cmd, url, wrapped);
}
static NSURLSessionDownloadTask *CKDownloadTask(id self, SEL cmd, NSURLRequest *request,
                                               void (^completion)(NSURL *, NSURLResponse *, NSError *)) {
    void (^wrapped)(NSURL *, NSURLResponse *, NSError *) = completion ? ^(NSURL *file, NSURLResponse *response, NSError *error) {
        if (!error) CKObserveFile(file, response);
        completion(file, response, error);
    } : nil;
    return ((id (*)(id, SEL, id, id))CKOriginalDownloadTask)(self, cmd, request, wrapped);
}
static NSURLSessionDownloadTask *CKURLDownloadTask(id self, SEL cmd, NSURL *url,
                                                  void (^completion)(NSURL *, NSURLResponse *, NSError *)) {
    void (^wrapped)(NSURL *, NSURLResponse *, NSError *) = completion ? ^(NSURL *file, NSURLResponse *response, NSError *error) {
        if (!error) CKObserveFile(file, response);
        completion(file, response, error);
    } : nil;
    return ((id (*)(id, SEL, id, id))CKOriginalURLDownloadTask)(self, cmd, url, wrapped);
}
static void CKReceive(NSURLSessionDataTask *task, NSData *data) {
    @synchronized(task) {
        NSMutableData *buffer = objc_getAssociatedObject(task, CKTaskData);
        if (!buffer && data.length && !objc_getAssociatedObject(task, CKTaskRejected)) {
            buffer = [NSMutableData data];
            objc_setAssociatedObject(task, CKTaskData, buffer, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        if (buffer) {
            BOOL reject = buffer.length + data.length > 4*1024*1024;
            if (!reject) {
                [buffer appendData:data];
                const unsigned char *bytes = buffer.bytes; NSUInteger offset = 0;
                if (buffer.length >= 3 && !memcmp(bytes, "\xef\xbb\xbf", 3)) offset = 3;
                while (offset < buffer.length && (bytes[offset] == ' ' || bytes[offset] == '\r' || bytes[offset] == '\n' || bytes[offset] == '\t')) offset++;
                if (buffer.length >= offset + 7) reject = memcmp(bytes + offset, "#EXTM3U", 7) != 0;
            }
            if (reject) {
                objc_setAssociatedObject(task, CKTaskData, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                objc_setAssociatedObject(task, CKTaskRejected, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            }
        }
    }
}
static void CKComplete(NSURLSessionTask *task, NSError *error) {
    NSData *data;
    @synchronized(task) {
        data = [objc_getAssociatedObject(task, CKTaskData) copy];
        objc_setAssociatedObject(task, CKTaskData, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(task, CKTaskRejected, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    if (!error && CKSuccessfulResponse(task.response)) CKObserve(data, task.response.URL ?: task.currentRequest.URL);
}
static void CKBindAsyncCompletions(Class target) {
    // Foundation async calls may bypass the two-argument completion factories.
    NSArray<NSString *> *names = @[@"dataTaskWithRequest:delegate:completionHandler:",
        @"_dataTaskWithRequest:delegate:completionHandler:", @"dataTaskWithURL:delegate:completionHandler:",
        @"_dataTaskWithURL:delegate:completionHandler:"];
    @synchronized(NSURLSession.class) {
        if (!CKAsyncHooks) CKAsyncHooks = [NSMutableSet set];
        for (NSString *name in names) {
            SEL selector = NSSelectorFromString(name);
            Method method = class_getInstanceMethod(target, selector);
            if (!method || method_getNumberOfArguments(method) != 5) continue;
            char *result = method_copyReturnType(method), *input = method_copyArgumentType(method, 2);
            char *delegate = method_copyArgumentType(method, 3), *completion = method_copyArgumentType(method, 4);
            BOOL compatible = result && result[0] == '@' && input && input[0] == '@' &&
                delegate && delegate[0] == '@' && completion && !strcmp(completion, "@?");
            free(result); free(input); free(delegate); free(completion);
            if (!compatible) continue;
            IMP original = method_getImplementation(method);
            if ([CKAsyncHooks containsObject:[NSValue valueWithPointer:original]]) continue;
            BOOL requestInput = [name containsString:@"WithRequest:"];
            IMP wrapper = imp_implementationWithBlock(^(id receiver, id inputValue, id taskDelegate,
                                                        void (^done)(NSData *, NSURLResponse *, NSError *)) {
                NSURL *url = requestInput ? ((NSURLRequest *)inputValue).URL : inputValue;
                void (^wrapped)(NSData *, NSURLResponse *, NSError *) = done ? ^(NSData *data, NSURLResponse *response, NSError *error) {
                    if (!error && CKSuccessfulResponse(response)) CKObserve(data, response.URL ?: url);
                    done(data, response, error);
                } : nil;
                return ((id (*)(id, SEL, id, id, id))original)(receiver, selector, inputValue, taskDelegate, wrapped);
            });
            [CKAsyncHooks addObject:[NSValue valueWithPointer:wrapper]];
            class_replaceMethod(target, selector, wrapper, method_getTypeEncoding(method));
            CKNativeEvent(8);
        }
    }
}
static BOOL CKEnterCallback(NSURLSessionTask *task, SEL selector) {
    // A subclass calling super must forward both originals but observe only once.
    NSMutableDictionary *local = NSThread.currentThread.threadDictionary;
    NSMutableSet *active = local[@"CKNativeDelegateCallbacks"];
    if (!active) local[@"CKNativeDelegateCallbacks"] = active = [NSMutableSet set];
    NSString *key = [NSString stringWithFormat:@"%p:%@", task, NSStringFromSelector(selector)];
    if ([active containsObject:key]) return NO;
    [active addObject:key]; return YES;
}
static void CKLeaveCallback(NSURLSessionTask *task, SEL selector) {
    NSMutableSet *active = NSThread.currentThread.threadDictionary[@"CKNativeDelegateCallbacks"];
    [active removeObject:[NSString stringWithFormat:@"%p:%@", task, NSStringFromSelector(selector)]];
    if (!active.count) [NSThread.currentThread.threadDictionary removeObjectForKey:@"CKNativeDelegateCallbacks"];
}
static void CKBindDelegate(id delegate) {
    if (!delegate) return;
    Class target = object_getClass(delegate);
    NSArray<NSString *> *selectors = @[@"URLSession:dataTask:didReceiveData:",
        @"URLSession:task:didCompleteWithError:", @"URLSession:downloadTask:didFinishDownloadingToURL:"];
    @synchronized(NSURLSession.class) {
        if (!CKDelegateHooks) CKDelegateHooks = [NSMutableSet set];
        for (NSUInteger index = 0; index < selectors.count; index++) {
            SEL selector = NSSelectorFromString(selectors[index]);
            Method method = class_getInstanceMethod(target, selector);
            IMP original = method ? method_getImplementation(method) : NULL;
            if (original && [CKDelegateHooks containsObject:[NSValue valueWithPointer:original]]) continue;
            struct objc_method_description description = protocol_getMethodDescription(
                index == 2 ? @protocol(NSURLSessionDownloadDelegate) :
                index == 0 ? @protocol(NSURLSessionDataDelegate) : @protocol(NSURLSessionTaskDelegate),
                selector, NO, YES);
            if (!description.types) description = protocol_getMethodDescription(
                @protocol(NSURLSessionDownloadDelegate), selector, YES, YES);
            const char *encoding = method ? method_getTypeEncoding(method) : description.types;
            if (!encoding) continue;
            IMP wrapper = imp_implementationWithBlock(^(id receiver, NSURLSession *session, NSURLSessionTask *task, id value) {
                BOOL outer = CKEnterCallback(task, selector);
                @try {
                    if (outer) {
                        if (index == 0) CKReceive((NSURLSessionDataTask *)task, value);
                        else if (index == 1) CKComplete(task, value);
                        else CKObserveFile(value, task.response);
                    }
                    if (original) ((void (*)(id, SEL, id, id, id))original)(receiver, selector, session, task, value);
                } @finally { if (outer) CKLeaveCallback(task, selector); }
            });
            [CKDelegateHooks addObject:[NSValue valueWithPointer:wrapper]];
            class_replaceMethod(target, selector, wrapper, encoding);
            CKNativeEvent(2);
        }
    }
}
static NSURLSession *CKSessionFactory(id self, SEL cmd, NSURLSessionConfiguration *config,
                                     id delegate, NSOperationQueue *queue) {
    // Bind before Foundation caches optional delegate callbacks, including late Swift classes.
    CKBindDelegate(delegate);
    NSURLSession *session = ((id (*)(id, SEL, id, id, id))CKOriginalSessionFactory)(self, cmd, config, delegate, queue);
    CKBindAsyncCompletions(object_getClass(session));
    return session;
}
@interface AVPlayer (CKHooks)
- (instancetype)ck_initWithPlayerItem:(AVPlayerItem *)item __attribute__((objc_method_family(init)));
- (instancetype)ck_initWithURL:(NSURL *)url __attribute__((objc_method_family(init)));
- (void)ck_replaceCurrentItemWithPlayerItem:(AVPlayerItem *)item;
- (void)ck_play;
- (void)ck_pause;
- (void)ck_setRate:(float)rate;
- (void)ck_playImmediatelyAtRate:(float)rate;
+ (instancetype)ck_nativePlayerWithURL:(NSURL *)url;
@end
@implementation AVPlayer (CKHooks)
+ (instancetype)ck_nativePlayerWithURL:(NSURL *)url {
    id context = CKNativeContext(url);
    if (!context) return [self ck_nativePlayerWithURL:url];
    AVPlayerItem *item = [AVPlayerItem playerItemWithURL:CKContextURL(context)];
    CKAttachContext(context, item.asset);
    return [self playerWithPlayerItem:item];
}
- (instancetype)ck_initWithPlayerItem:(AVPlayerItem *)item {
    if (CKRoute(item)) item = CKPlaceholder();
    return [self ck_initWithPlayerItem:item];
}
- (instancetype)ck_initWithURL:(NSURL *)url {
    id native = CKNativeContext(url);
    if (native) {
        AVPlayerItem *item = [AVPlayerItem playerItemWithURL:CKContextURL(native)];
        CKAttachContext(native, item.asset);
        return [self initWithPlayerItem:item];
    }
    Class runtime = CKRuntimeClass();
    BOOL routed = [runtime respondsToSelector:@selector(routeURL:)] &&
        ((BOOL (*)(id, SEL, id))objc_msgSend)(runtime, @selector(routeURL:), url);
    if (routed) return [self initWithPlayerItem:CKPlaceholder()];
    return [self ck_initWithURL:url];
}
- (void)ck_replaceCurrentItemWithPlayerItem:(AVPlayerItem *)item {
    if (CKRoute(item)) item = CKPlaceholder();
    [self ck_replaceCurrentItemWithPlayerItem:item];
}
- (void)ck_play { [self ck_play]; CKNativePlaying(self, 1); }
- (void)ck_pause { [self ck_pause]; CKNativePlaying(self, 0); }
- (void)ck_setRate:(float)rate { [self ck_setRate:rate]; CKNativePlaying(self, rate); }
- (void)ck_playImmediatelyAtRate:(float)rate { [self ck_playImmediatelyAtRate:rate]; CKNativePlaying(self, rate); }
@end
@interface AVURLAsset (CKNativeHooks)
- (instancetype)ck_nativeInitWithURL:(NSURL *)url options:(NSDictionary *)options __attribute__((objc_method_family(init)));
+ (instancetype)ck_nativeURLAssetWithURL:(NSURL *)url options:(NSDictionary *)options;
@end
@implementation AVURLAsset (CKNativeHooks)
+ (instancetype)ck_nativeURLAssetWithURL:(NSURL *)url options:(NSDictionary *)options {
    id context = CKNativeContext(url);
    NSMutableDictionary *local = context ? [options mutableCopy] : nil;
    if (context) [local removeObjectForKey:@"AVURLAssetHTTPHeaderFieldsKey"];
    AVURLAsset *asset = [self ck_nativeURLAssetWithURL:CKContextURL(context) ?: url options:context ? local : options];
    CKAttachContext(context, asset); return asset;
}
- (instancetype)ck_nativeInitWithURL:(NSURL *)url options:(NSDictionary *)options {
    id context = CKNativeContext(url);
    NSMutableDictionary *local = context ? [options mutableCopy] : nil;
    if (context) [local removeObjectForKey:@"AVURLAssetHTTPHeaderFieldsKey"];
    AVURLAsset *asset = [self ck_nativeInitWithURL:CKContextURL(context) ?: url options:context ? local : options];
    CKAttachContext(context, asset); return asset;
}
@end
@interface AVPlayerItem (CKNativeHooks)
- (instancetype)ck_nativeInitWithURL:(NSURL *)url __attribute__((objc_method_family(init)));
- (instancetype)ck_nativeInitWithAsset:(AVAsset *)asset __attribute__((objc_method_family(init)));
- (instancetype)ck_nativeInitWithAsset:(AVAsset *)asset automaticallyLoadedAssetKeys:(NSArray *)keys __attribute__((objc_method_family(init)));
+ (instancetype)ck_nativePlayerItemWithURL:(NSURL *)url;
+ (instancetype)ck_nativePlayerItemWithAsset:(AVAsset *)asset;
+ (instancetype)ck_nativePlayerItemWithAsset:(AVAsset *)asset automaticallyLoadedAssetKeys:(NSArray *)keys;
@end
static AVAsset *CKNativeAsset(AVAsset *asset) {
    if (![asset isKindOfClass:AVURLAsset.class]) return asset;
    id context = CKNativeContext(((AVURLAsset *)asset).URL);
    if (!context) return asset;
    AVURLAsset *mapped = [AVURLAsset URLAssetWithURL:CKContextURL(context) options:nil];
    CKAttachContext(context, mapped); return mapped;
}
@implementation AVPlayerItem (CKNativeHooks)
+ (instancetype)ck_nativePlayerItemWithURL:(NSURL *)url {
    id context = CKNativeContext(url);
    AVPlayerItem *item = [self ck_nativePlayerItemWithURL:CKContextURL(context) ?: url];
    CKAttachContext(context, item.asset); return item;
}
+ (instancetype)ck_nativePlayerItemWithAsset:(AVAsset *)asset {
    return [self ck_nativePlayerItemWithAsset:CKNativeAsset(asset)];
}
+ (instancetype)ck_nativePlayerItemWithAsset:(AVAsset *)asset automaticallyLoadedAssetKeys:(NSArray *)keys {
    return [self ck_nativePlayerItemWithAsset:CKNativeAsset(asset) automaticallyLoadedAssetKeys:keys];
}
- (instancetype)ck_nativeInitWithURL:(NSURL *)url {
    id context = CKNativeContext(url);
    AVPlayerItem *item = [self ck_nativeInitWithURL:CKContextURL(context) ?: url];
    CKAttachContext(context, item.asset); return item;
}
- (instancetype)ck_nativeInitWithAsset:(AVAsset *)asset {
    return [self ck_nativeInitWithAsset:CKNativeAsset(asset)];
}
- (instancetype)ck_nativeInitWithAsset:(AVAsset *)asset automaticallyLoadedAssetKeys:(NSArray *)keys {
    return [self ck_nativeInitWithAsset:CKNativeAsset(asset) automaticallyLoadedAssetKeys:keys];
}
@end
static void CKExchange(Class target, SEL original, SEL replacement) {
    Method a = class_getInstanceMethod(target, original), b = class_getInstanceMethod(target, replacement);
    if (a && b) method_exchangeImplementations(a, b);
}
static void CKInstall(Class target, SEL selector, IMP replacement, IMP *saved) {
    Method method = class_getInstanceMethod(target, selector);
    if (!method) return;
    *saved = method_getImplementation(method);
    class_replaceMethod(target, selector, replacement, method_getTypeEncoding(method));
}
__attribute__((constructor)) static void CKBootstrap(void) {
    @autoreleasepool {
        CKInstall([NSURLSession.sharedSession class], @selector(dataTaskWithRequest:completionHandler:), (IMP)CKTask, &CKOriginalTask);
        CKInstall([NSURLSession.sharedSession class], @selector(dataTaskWithURL:completionHandler:), (IMP)CKURLTask, &CKOriginalURLTask);
        CKInstall([NSURLSession.sharedSession class], @selector(downloadTaskWithRequest:completionHandler:), (IMP)CKDownloadTask, &CKOriginalDownloadTask);
        CKInstall([NSURLSession.sharedSession class], @selector(downloadTaskWithURL:completionHandler:), (IMP)CKURLDownloadTask, &CKOriginalURLDownloadTask);
        CKBindAsyncCompletions(object_getClass(NSURLSession.sharedSession));
        CKInstall(object_getClass(NSURLSession.class), @selector(sessionWithConfiguration:delegate:delegateQueue:),
                  (IMP)CKSessionFactory, &CKOriginalSessionFactory);
        CKExchange(AVPlayer.class, @selector(initWithPlayerItem:), @selector(ck_initWithPlayerItem:));
        CKExchange(AVPlayer.class, @selector(initWithURL:), @selector(ck_initWithURL:));
        CKExchange(AVPlayer.class, @selector(replaceCurrentItemWithPlayerItem:), @selector(ck_replaceCurrentItemWithPlayerItem:));
        CKExchange(AVPlayer.class, @selector(play), @selector(ck_play));
        CKExchange(AVPlayer.class, @selector(pause), @selector(ck_pause));
        CKExchange(AVPlayer.class, @selector(setRate:), @selector(ck_setRate:));
        CKExchange(AVPlayer.class, @selector(playImmediatelyAtRate:), @selector(ck_playImmediatelyAtRate:));
        CKExchange(object_getClass(AVPlayer.class), @selector(playerWithURL:), @selector(ck_nativePlayerWithURL:));
        CKExchange(AVURLAsset.class, @selector(initWithURL:options:), @selector(ck_nativeInitWithURL:options:));
        CKExchange(object_getClass(AVURLAsset.class), @selector(URLAssetWithURL:options:), @selector(ck_nativeURLAssetWithURL:options:));
        CKExchange(AVPlayerItem.class, @selector(initWithURL:), @selector(ck_nativeInitWithURL:));
        CKExchange(AVPlayerItem.class, @selector(initWithAsset:), @selector(ck_nativeInitWithAsset:));
        CKExchange(AVPlayerItem.class, @selector(initWithAsset:automaticallyLoadedAssetKeys:),
                   @selector(ck_nativeInitWithAsset:automaticallyLoadedAssetKeys:));
        CKExchange(object_getClass(AVPlayerItem.class), @selector(playerItemWithURL:), @selector(ck_nativePlayerItemWithURL:));
        CKExchange(object_getClass(AVPlayerItem.class), @selector(playerItemWithAsset:), @selector(ck_nativePlayerItemWithAsset:));
        CKExchange(object_getClass(AVPlayerItem.class), @selector(playerItemWithAsset:automaticallyLoadedAssetKeys:),
                   @selector(ck_nativePlayerItemWithAsset:automaticallyLoadedAssetKeys:));
        // UI is installed after launch, outside the loader's initialization stack.
        [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationDidFinishLaunchingNotification object:nil queue:NSOperationQueue.mainQueue
            usingBlock:^(NSNotification *note) {
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), ^{
                    Class runtime = CKRuntimeClass();
                    CKNativeEvent(1);
                    if ([runtime respondsToSelector:@selector(installPanel)]) ((void (*)(id,SEL))objc_msgSend)(runtime,@selector(installPanel));
                });
            }];
    }
}

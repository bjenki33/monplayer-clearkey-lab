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
    return ((id (*)(id, SEL, id, id, id))CKOriginalSessionFactory)(self, cmd, config, delegate, queue);
}
@interface AVPlayer (CKHooks)
- (instancetype)ck_initWithPlayerItem:(AVPlayerItem *)item __attribute__((objc_method_family(init)));
- (instancetype)ck_initWithURL:(NSURL *)url __attribute__((objc_method_family(init)));
- (void)ck_replaceCurrentItemWithPlayerItem:(AVPlayerItem *)item;
@end
@implementation AVPlayer (CKHooks)
- (instancetype)ck_initWithPlayerItem:(AVPlayerItem *)item {
    if (CKRoute(item)) item = CKPlaceholder();
    return [self ck_initWithPlayerItem:item];
}
- (instancetype)ck_initWithURL:(NSURL *)url {
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
        CKInstall(object_getClass(NSURLSession.class), @selector(sessionWithConfiguration:delegate:delegateQueue:),
                  (IMP)CKSessionFactory, &CKOriginalSessionFactory);
        CKExchange(AVPlayer.class, @selector(initWithPlayerItem:), @selector(ck_initWithPlayerItem:));
        CKExchange(AVPlayer.class, @selector(initWithURL:), @selector(ck_initWithURL:));
        CKExchange(AVPlayer.class, @selector(replaceCurrentItemWithPlayerItem:), @selector(ck_replaceCurrentItemWithPlayerItem:));
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

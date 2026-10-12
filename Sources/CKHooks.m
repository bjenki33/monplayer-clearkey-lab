#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>

static const void *CKTaskData = &CKTaskData;
static const void *CKTaskRejected = &CKTaskRejected;
static IMP CKOriginalTask, CKOriginalData, CKOriginalComplete;

static Class CKRuntimeClass(void) { return NSClassFromString(@"CKRuntime"); }
static void CKObserve(NSData *data, NSURL *url) {
    Class runtime = CKRuntimeClass();
    if (data && [runtime respondsToSelector:@selector(observe:source:)]) {
        ((void (*)(id, SEL, id, id))objc_msgSend)(runtime, @selector(observe:source:), data, url);
    }
}
static BOOL CKRoute(AVPlayerItem *item) {
    Class runtime = CKRuntimeClass();
    return item && [runtime respondsToSelector:@selector(route:)] &&
        ((BOOL (*)(id, SEL, id))objc_msgSend)(runtime, @selector(route:), item);
}
static NSURLSessionDataTask *CKTask(id self, SEL cmd, NSURLRequest *request,
                                   void (^completion)(NSData *, NSURLResponse *, NSError *)) {
    // Observe the existing completion; never proxy, alter, retry or redirect requests.
    void (^wrapped)(NSData *, NSURLResponse *, NSError *) = completion ? ^(NSData *data, NSURLResponse *response, NSError *error) {
        if (!error) CKObserve(data, response.URL ?: request.URL);
        completion(data, response, error);
    } : nil;
    return ((id (*)(id, SEL, id, id))CKOriginalTask)(self, cmd, request, wrapped);
}
static void CKDidReceive(id self, SEL cmd, NSURLSession *session, NSURLSessionDataTask *task, NSData *data) {
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
    ((void (*)(id, SEL, id, id, id))CKOriginalData)(self, cmd, session, task, data);
}
static void CKDidComplete(id self, SEL cmd, NSURLSession *session, NSURLSessionTask *task, NSError *error) {
    NSData *data;
    @synchronized(task) {
        data = [objc_getAssociatedObject(task, CKTaskData) copy];
        objc_setAssociatedObject(task, CKTaskData, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(task, CKTaskRejected, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    if (!error) CKObserve(data, task.response.URL ?: task.currentRequest.URL);
    ((void (*)(id, SEL, id, id, id))CKOriginalComplete)(self, cmd, session, task, error);
}
@interface AVPlayer (CKHooks)
- (instancetype)ck_initWithPlayerItem:(AVPlayerItem *)item __attribute__((objc_method_family(init)));
- (instancetype)ck_initWithURL:(NSURL *)url __attribute__((objc_method_family(init)));
- (void)ck_replaceCurrentItemWithPlayerItem:(AVPlayerItem *)item;
@end
@implementation AVPlayer (CKHooks)
- (instancetype)ck_initWithPlayerItem:(AVPlayerItem *)item {
    if (CKRoute(item)) item = nil;
    return [self ck_initWithPlayerItem:item];
}
- (instancetype)ck_initWithURL:(NSURL *)url {
    Class runtime = CKRuntimeClass();
    BOOL routed = [runtime respondsToSelector:@selector(routeURL:)] &&
        ((BOOL (*)(id, SEL, id))objc_msgSend)(runtime, @selector(routeURL:), url);
    if (routed) return [self initWithPlayerItem:nil];
    return [self ck_initWithURL:url];
}
- (void)ck_replaceCurrentItemWithPlayerItem:(AVPlayerItem *)item {
    if (CKRoute(item)) item = nil;
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
        Class delegate = NSClassFromString(@"Alamofire.SessionDelegate");
        if (!delegate) delegate = NSClassFromString(@"_TtC9Alamofire15SessionDelegate");
        if (delegate) {
            CKInstall(delegate, @selector(URLSession:dataTask:didReceiveData:), (IMP)CKDidReceive, &CKOriginalData);
            CKInstall(delegate, @selector(URLSession:task:didCompleteWithError:), (IMP)CKDidComplete, &CKOriginalComplete);
        }
        CKExchange(AVPlayer.class, @selector(initWithPlayerItem:), @selector(ck_initWithPlayerItem:));
        CKExchange(AVPlayer.class, @selector(initWithURL:), @selector(ck_initWithURL:));
        CKExchange(AVPlayer.class, @selector(replaceCurrentItemWithPlayerItem:), @selector(ck_replaceCurrentItemWithPlayerItem:));
        // UI is installed after launch, outside the loader's initialization stack.
        [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationDidFinishLaunchingNotification object:nil queue:NSOperationQueue.mainQueue
            usingBlock:^(NSNotification *note) {
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), ^{
                    Class runtime = CKRuntimeClass();
                    if ([runtime respondsToSelector:@selector(installPanel)]) ((void (*)(id,SEL))objc_msgSend)(runtime,@selector(installPanel));
                });
            }];
    }
}

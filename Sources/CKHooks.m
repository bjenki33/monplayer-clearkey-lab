#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>

static const void *CKTaskData = &CKTaskData;
static IMP CKOriginalTask, CKOriginalData, CKOriginalComplete;
static IMP CKOriginalInitPlayer, CKOriginalReplace;

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
        if (!buffer && data.length && data.length <= 4*1024*1024) {
            NSString *prefix = [[NSString alloc] initWithData:[data subdataWithRange:NSMakeRange(0, MIN(data.length, 128))]
                                                   encoding:NSUTF8StringEncoding];
            if ([[prefix stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] hasPrefix:@"#EXTM3U"]) {
                buffer = [NSMutableData data];
                objc_setAssociatedObject(task, CKTaskData, buffer, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            }
        }
        if (buffer && buffer.length + data.length <= 4*1024*1024) [buffer appendData:data];
        else if (buffer) objc_setAssociatedObject(task, CKTaskData, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    ((void (*)(id, SEL, id, id, id))CKOriginalData)(self, cmd, session, task, data);
}
static void CKDidComplete(id self, SEL cmd, NSURLSession *session, NSURLSessionTask *task, NSError *error) {
    NSData *data;
    @synchronized(task) {
        data = [objc_getAssociatedObject(task, CKTaskData) copy];
        objc_setAssociatedObject(task, CKTaskData, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    if (!error) CKObserve(data, task.response.URL ?: task.currentRequest.URL);
    ((void (*)(id, SEL, id, id, id))CKOriginalComplete)(self, cmd, session, task, error);
}
static id CKInitPlayer(id self, SEL cmd, AVPlayerItem *item) {
    if (CKRoute(item)) item = nil;
    return ((id (*)(id, SEL, id))CKOriginalInitPlayer)(self, cmd, item);
}
static void CKReplace(id self, SEL cmd, AVPlayerItem *item) {
    if (CKRoute(item)) item = nil;
    ((void (*)(id, SEL, id))CKOriginalReplace)(self, cmd, item);
}
static IMP CKInstall(Class target, SEL selector, IMP replacement) {
    Method method = class_getInstanceMethod(target, selector);
    if (!method) return NULL;
    IMP original = method_getImplementation(method);
    class_replaceMethod(target, selector, replacement, method_getTypeEncoding(method));
    return original;
}
__attribute__((constructor)) static void CKBootstrap(void) {
    @autoreleasepool {
        CKOriginalTask = CKInstall([NSURLSession.sharedSession class], @selector(dataTaskWithRequest:completionHandler:), (IMP)CKTask);
        Class delegate = NSClassFromString(@"Alamofire.SessionDelegate");
        if (!delegate) delegate = NSClassFromString(@"_TtC9Alamofire15SessionDelegate");
        if (delegate) {
            CKOriginalData = CKInstall(delegate, @selector(URLSession:dataTask:didReceiveData:), (IMP)CKDidReceive);
            CKOriginalComplete = CKInstall(delegate, @selector(URLSession:task:didCompleteWithError:), (IMP)CKDidComplete);
        }
        CKOriginalInitPlayer = CKInstall(AVPlayer.class, @selector(initWithPlayerItem:), (IMP)CKInitPlayer);
        CKOriginalReplace = CKInstall(AVPlayer.class, @selector(replaceCurrentItemWithPlayerItem:), (IMP)CKReplace);
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

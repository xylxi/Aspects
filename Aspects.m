//
//  Aspects.m
//  Aspects - A delightful, simple library for aspect oriented programming.
//
//  Copyright (c) 2014 Peter Steinberger. Licensed under the MIT license.
//

#import "Aspects.h"
#import <libkern/OSAtomic.h>
#import <objc/runtime.h>
#import <objc/message.h>

#define AspectLog(...)
//#define AspectLog(...) do { NSLog(__VA_ARGS__); }while(0)
#define AspectLogError(...) do { NSLog(__VA_ARGS__); }while(0)

// Block internals.
typedef NS_OPTIONS(int, AspectBlockFlags) {
	AspectBlockFlagsHasCopyDisposeHelpers = (1 << 25),
	AspectBlockFlagsHasSignature          = (1 << 30)
};

/***
 Block对应的结构体，定义这个结构体只有一个目的：拿到block的方法签名，也就是获取signature字段的值。拿到方法签名你就可以使用NSInvocation调用这个block
 */
typedef struct _AspectBlock {
	__unused Class isa;
	AspectBlockFlags flags;
	__unused int reserved;
	void (__unused *invoke)(struct _AspectBlock *block, ...);
	struct {
		unsigned long int reserved;
		unsigned long int size;
		// requires AspectBlockFlagsHasCopyDisposeHelpers
		void (*copy)(void *dst, const void *src);
		void (*dispose)(const void *);
		// requires AspectBlockFlagsHasSignature
		const char *signature;
		const char *layout;
	} *descriptor;
	// imported variables
} *AspectBlockRef;

/** 这要是NSInvocation信息 */
@interface AspectInfo : NSObject <AspectInfo>
/**
 * instance：传进来实例
 * originalInvocation：原始方法的Invocation
 */
- (id)initWithInstance:(__unsafe_unretained id)instance
            invocation:(NSInvocation *)invocation;
@property (nonatomic, unsafe_unretained, readonly) id instance;
/// 原始方法的参数列表(出去self和SEL)
@property (nonatomic, strong, readonly) NSArray *arguments;
@property (nonatomic, strong, readonly) NSInvocation *originalInvocation;
@end

// Tracks a single aspect.
// 一个简单的aspect，存放一些基础信息，
// 比较有意思的是，其中还保存了block的方法签名，
// 这个是为了生成NSInvocation对象，为的是实现动态调用block，block被允许是任意个数的参数，
/** 每进行一个hook，都会生成一个AspectIdentifier对应。*/
@interface AspectIdentifier : NSObject
+ (instancetype)identifierWithSelector:(SEL)selector
                                object:(id)object
                               options:(AspectOptions)options
                                 block:(id)block
                                 error:(NSError **)error;

- (BOOL)invokeWithInfo:(id<AspectInfo>)info;
@property (nonatomic, assign) SEL selector;
@property (nonatomic, strong) id block;
@property (nonatomic, strong) NSMethodSignature *blockSignature;
@property (nonatomic, weak) id object;
@property (nonatomic, assign) AspectOptions options;
@end

// Tracks all aspects for an object/class.
// 绑定在对象上的一个容器，来存放aspect。
/** 可以理解为容器，用于盛放AspectIdentifier对象。一个selector对应一个AspectsContainer对象， 使用objc_setAssociatedObject存储在实例对象或者类对象上 key就是selector*/
@interface AspectsContainer : NSObject
- (void)addAspect:(AspectIdentifier *)aspect withOptions:(AspectOptions)injectPosition;
- (BOOL)removeAspect:(id)aspect;
- (BOOL)hasAspects;
@property (atomic, copy) NSArray *beforeAspects;
@property (atomic, copy) NSArray *insteadAspects;
@property (atomic, copy) NSArray *afterAspects;
@end

/**每一个class对应一个AspectTracker。  在一个继承链上一个selector只能被hook一次， AspectTracker就是实现这中需求的数据结构。Aspect hook一个selector是通过method swizzling配合消息转发实现的， 如果一个继承链中对同一个selector 进行多次method swizzling，会出现意想不到的效果*/
@interface AspectTracker : NSObject
- (id)initWithTrackedClass:(Class)trackedClass;
/// 被追踪的类
@property (nonatomic, strong) Class trackedClass;
/// 类名
@property (nonatomic, readonly) NSString *trackedClassName;
/// 记录着被hook替换的方法名，防止重复替换方法
@property (nonatomic, strong) NSMutableSet *selectorNames;
/// key   = hookingSelectorName
/// value = set<AspectTracker>      干嘛用的
@property (nonatomic, strong) NSMutableDictionary *selectorNamesToSubclassTrackers;
- (void)addSubclassTracker:(AspectTracker *)subclassTracker hookingSelectorName:(NSString *)selectorName;
- (void)removeSubclassTracker:(AspectTracker *)subclassTracker hookingSelectorName:(NSString *)selectorName;
- (BOOL)subclassHasHookedSelectorName:(NSString *)selectorName;
- (NSSet *)subclassTrackersHookingSelectorName:(NSString *)selectorName;
@end

@interface NSInvocation (Aspects)
- (NSArray *)aspects_arguments;
@end

#define AspectPositionFilter 0x07

#define AspectError(errorCode, errorDescription) do { \
AspectLogError(@"Aspects: %@", errorDescription); \
if (error) { *error = [NSError errorWithDomain:AspectErrorDomain code:errorCode userInfo:@{NSLocalizedDescriptionKey: errorDescription}]; }}while(0)

NSString *const AspectErrorDomain = @"AspectErrorDomain";
static NSString *const AspectsSubclassSuffix = @"_Aspects_";
static NSString *const AspectsMessagePrefix = @"aspects_";

@implementation NSObject (Aspects)

///////////////////////////////////////////////////////////////////////////////////////////
#pragma mark - Public Aspects API

+ (id<AspectToken>)aspect_hookSelector:(SEL)selector
                      withOptions:(AspectOptions)options
                       usingBlock:(id)block
                            error:(NSError **)error {
    return aspect_add((id)self, selector, options, block, error);
}

/// @return A token which allows to later deregister the aspect.
- (id<AspectToken>)aspect_hookSelector:(SEL)selector
                      withOptions:(AspectOptions)options
                       usingBlock:(id)block
                            error:(NSError **)error {
    return aspect_add(self, selector, options, block, error);
}

///////////////////////////////////////////////////////////////////////////////////////////
#pragma mark - Private Helper

/** 这里的self可以是实例对象 也可以是类对象*/
static id aspect_add(id self, SEL selector, AspectOptions options, id block, NSError **error) {
    NSCParameterAssert(self);
    NSCParameterAssert(selector);
    NSCParameterAssert(block);
    __block AspectIdentifier *identifier = nil;
    // 加锁
    aspect_performLocked(^{
        if (aspect_isSelectorAllowedAndTrack(self, selector, options, error)) {
            AspectsContainer *aspectContainer = aspect_getContainerForObject(self, selector);
            // 创建aspect(方面/切面)
            identifier = [AspectIdentifier identifierWithSelector:selector
                                                           object:self
                                                          options:options
                                                            block:block
                                                            error:error];
            if (identifier) {
                // 将aspect添加到容器中
                [aspectContainer addAspect:identifier withOptions:options];

                // Modify the class to allow message interception.
                // 修改class，以允许消息拦截
                /** block封装好了开始下一个重头戏。 method swizzling 和消息转发*/
                aspect_prepareClassAndHookSelector(self, selector, error);
            }
        }
    });
    return identifier;
}

static BOOL aspect_remove(AspectIdentifier *aspect, NSError **error) {
    NSCAssert([aspect isKindOfClass:AspectIdentifier.class], @"Must have correct type.");

    __block BOOL success = NO;
    aspect_performLocked(^{
        id self = aspect.object; // strongify
        if (self) {
            AspectsContainer *aspectContainer = aspect_getContainerForObject(self, aspect.selector);
            success = [aspectContainer removeAspect:aspect];

            aspect_cleanupHookedClassAndSelector(self, aspect.selector);
            // destroy token
            aspect.object = nil;
            aspect.block = nil;
            aspect.selector = NULL;
        }else {
            NSString *errrorDesc = [NSString stringWithFormat:@"Unable to deregister hook. Object already deallocated: %@", aspect];
            AspectError(AspectErrorRemoveObjectAlreadyDeallocated, errrorDesc);
        }
    });
    return success;
}

static void aspect_performLocked(dispatch_block_t block) {
    static OSSpinLock aspect_lock = OS_SPINLOCK_INIT;
    OSSpinLockLock(&aspect_lock);
    block();
    OSSpinLockUnlock(&aspect_lock);
}

static SEL aspect_aliasForSelector(SEL selector) {
    NSCParameterAssert(selector);
	return NSSelectorFromString([AspectsMessagePrefix stringByAppendingFormat:@"_%@", NSStringFromSelector(selector)]);
}

/** 获取block的方法签名。其方法就是讲block强制类型转换为AspectBlockRef,根据标志位和结构体的结构，获取signature*/
static NSMethodSignature *aspect_blockMethodSignature(id block, NSError **error) {
    AspectBlockRef layout = (__bridge void *)block;
	if (!(layout->flags & AspectBlockFlagsHasSignature)) {
        // 判断是发有标志位，如果没有，就是没有方法签
        NSString *description = [NSString stringWithFormat:@"The block %@ doesn't contain a type signature.", block];
        AspectError(AspectErrorMissingBlockSignature, description);
        return nil;
    }
	void *desc = layout->descriptor;
	desc += 2 * sizeof(unsigned long int);// 向下偏移2个unsigned long int位置
	if (layout->flags & AspectBlockFlagsHasCopyDisposeHelpers) {
        // 如果有Copy和Dispose函数，在偏移2个
		desc += 2 * sizeof(void *);
    }
	if (!desc) {
        NSString *description = [NSString stringWithFormat:@"The block %@ doesn't has a type signature.", block];
        AspectError(AspectErrorMissingBlockSignature, description);
        return nil;
    }
    // 获取签名
	const char *signature = (*(const char **)desc);
	return [NSMethodSignature signatureWithObjCTypes:signature];
}

/// 这个函数的作用是把我们要替换的方法block和要替换的原方法，进行对比。如何对比呢？对比两者的方法签名。
static BOOL aspect_isCompatibleBlockSignature(NSMethodSignature *blockSignature, id object, SEL selector, NSError **error) {
    NSCParameterAssert(blockSignature);
    NSCParameterAssert(object);
    NSCParameterAssert(selector);

    BOOL signaturesMatch = YES;
    // 获取原始select的签名
    // object不管是对象还是class，[object class]最终会拿到class
    // 获取实例方法的签名
    NSMethodSignature *methodSignature = [[object class] instanceMethodSignatureForSelector:selector];
    if (blockSignature.numberOfArguments > methodSignature.numberOfArguments) {
        // 如果block的参数大于select的参数
        signaturesMatch = NO;
    }else {
        if (blockSignature.numberOfArguments > 1) {
            // 如果block有参数，并且第一个参数不是对象类型就返回NO
            // 因为第2个参数(第一个参数默认是self)必须是 id<AspectInfo> aspectInfo
            const char *blockType = [blockSignature getArgumentTypeAtIndex:1];
            if (blockType[0] != '@') {
                signaturesMatch = NO;
            }
        }
        // Argument 0 is self/block, argument 1 is SEL or id<AspectInfo>. We start comparing at argument 2.
        // The block can have less arguments than the method, that's ok.
        if (signaturesMatch) {
            for (NSUInteger idx = 2; idx < blockSignature.numberOfArguments; idx++) {
                // 比较除了前两个参数外，其余的参数类型是否一致
                const char *methodType = [methodSignature getArgumentTypeAtIndex:idx];
                const char *blockType = [blockSignature getArgumentTypeAtIndex:idx];
                // Only compare parameter, not the optional type data.
                if (!methodType || !blockType || methodType[0] != blockType[0]) {
                    signaturesMatch = NO; break;
                }
            }
        }
    }

    if (!signaturesMatch) {
        NSString *description = [NSString stringWithFormat:@"Block signature %@ doesn't match %@.", blockSignature, methodSignature];
        AspectError(AspectErrorIncompatibleBlockSignature, description);
        return NO;
    }
    return YES;
}

///////////////////////////////////////////////////////////////////////////////////////////
#pragma mark - Class + Selector Preparation

static BOOL aspect_isMsgForwardIMP(IMP impl) {
    return impl == _objc_msgForward
#if !defined(__arm64__)
    || impl == (IMP)_objc_msgForward_stret
#endif
    ;
}


/** 
 *  被hook的selector的imp 被替换为此函数的返回值。当执行这个selector时就会执行消息转发，这也就是手动触发消息转发
 *  大概是这样：如果转发的消息的返回值是struct类型，就使用_objc_msgForward_stret 否则使用_objc_msgForward
 *  如果函数返回是个结构体就用_objc_msgForward_stret
 *  其它情况使用           _objc_msgForward
 */
static IMP aspect_getMsgForwardIMP(NSObject *self, SEL selector) {
    IMP msgForwardIMP = _objc_msgForward;
#if !defined(__arm64__)
    // As an ugly internal runtime implementation detail in the 32bit runtime, we need to determine of the method we hook returns a struct or anything larger than id.
    // https://developer.apple.com/library/mac/documentation/DeveloperTools/Conceptual/LowLevelABI/000-Introduction/introduction.html
    // https://github.com/ReactiveCocoa/ReactiveCocoa/issues/783
    // http://infocenter.arm.com/help/topic/com.arm.doc.ihi0042e/IHI0042E_aapcs.pdf (Section 5.4)
    Method method = class_getInstanceMethod(self.class, selector);
    const char *encoding = method_getTypeEncoding(method);
    BOOL methodReturnsStructValue = encoding[0] == _C_STRUCT_B;
    if (methodReturnsStructValue) {
        @try {
            NSUInteger valueSize = 0;
            NSGetSizeAndAlignment(encoding, &valueSize, NULL);

            if (valueSize == 1 || valueSize == 2 || valueSize == 4 || valueSize == 8) {
                methodReturnsStructValue = NO;
            }
        } @catch (__unused NSException *e) {}
    }
    if (methodReturnsStructValue) {
        msgForwardIMP = (IMP)_objc_msgForward_stret;
    }
#endif
    return msgForwardIMP;
}

/** 为了实现消息转发，在这个地方进行一些method swizzling操作。
 1， 首先进行swizzleForwardInvocation。将forwardInvocation的实现替换为 自定义方法__ASPECTS_ARE_BEING_CALLED__
 并添加selector __aspects_forwardInvocation:设置其实现为forwardInvocation原来的实现。 需要进行消息转发的selector都会执行__ASPECTS_ARE_BEING_CALLED__
 2， 将hook 的selector的实现替换为_objc_msgForward 或者_objc_msgForward_stret （具体哪一个根据selector的返回值类型确定）,同时添加selector: aspect_aliasForSelector(selector)其实现为selector原来的实现。 此时调用selector时就会进行消息转发。
 */
static void aspect_prepareClassAndHookSelector(NSObject *self, SEL selector, NSError **error) {
    NSCParameterAssert(selector);
    // 1、对self类的forwardInvocation:方法进行hook，然后返回当前类的子类
    Class klass = aspect_hookClass(self, error);
    // 获取最初的Method
    Method targetMethod = class_getInstanceMethod(klass, selector);
    // 获取最初的IMP
    IMP targetMethodIMP = method_getImplementation(targetMethod);
    //2、swizzle 要hook的selector。如果selector的实现是_objc_msgForward或者_objc_msgForward_stret， 就不进行method swizzle 了。
    if (!aspect_isMsgForwardIMP(targetMethodIMP)) {
        // Make a method alias for the existing method implementation, it not already copied.
        // 为现有方法实现创建方法别名，它尚未复制。
        const char *typeEncoding = method_getTypeEncoding(targetMethod);
        // 获取swizz的SEL
        SEL aliasSelector = aspect_aliasForSelector(selector);
        if (![klass instancesRespondToSelector:aliasSelector]) {//没有使用aliasSelector 保存selector原来的实现
            __unused BOOL addedAlias = class_addMethod(klass, aliasSelector, method_getImplementation(targetMethod), typeEncoding);
            NSCAssert(addedAlias, @"Original implementation for %@ is already copied to %@ on %@", NSStringFromSelector(selector), NSStringFromSelector(aliasSelector), klass);
        }

        // We use forwardInvocation to hook in.
        // 将最初的selector修改实现
        class_replaceMethod(klass, selector, aspect_getMsgForwardIMP(self, selector), typeEncoding);
        AspectLog(@"Aspects: Installed hook for -[%@ %@].", klass, NSStringFromSelector(selector));
    }
}

// Will undo the runtime changes made.
static void aspect_cleanupHookedClassAndSelector(NSObject *self, SEL selector) {
    NSCParameterAssert(self);
    NSCParameterAssert(selector);

	Class klass = object_getClass(self);
    BOOL isMetaClass = class_isMetaClass(klass);
    if (isMetaClass) {
        klass = (Class)self;
    }

    // Check if the method is marked as forwarded and undo that.
    Method targetMethod = class_getInstanceMethod(klass, selector);
    IMP targetMethodIMP = method_getImplementation(targetMethod);
    if (aspect_isMsgForwardIMP(targetMethodIMP)) {
        // Restore the original method implementation.
        const char *typeEncoding = method_getTypeEncoding(targetMethod);
        SEL aliasSelector = aspect_aliasForSelector(selector);
        Method originalMethod = class_getInstanceMethod(klass, aliasSelector);
        IMP originalIMP = method_getImplementation(originalMethod);
        NSCAssert(originalMethod, @"Original implementation for %@ not found %@ on %@", NSStringFromSelector(selector), NSStringFromSelector(aliasSelector), klass);

        class_replaceMethod(klass, selector, originalIMP, typeEncoding);
        AspectLog(@"Aspects: Removed hook for -[%@ %@].", klass, NSStringFromSelector(selector));
    }

    // Deregister global tracked selector
    aspect_deregisterTrackedSelector(self, selector);

    // Get the aspect container and check if there are any hooks remaining. Clean up if there are not.
    AspectsContainer *container = aspect_getContainerForObject(self, selector);
    if (!container.hasAspects) {
        // Destroy the container
        aspect_destroyContainerForObject(self, selector);

        // Figure out how the class was modified to undo the changes.
        NSString *className = NSStringFromClass(klass);
        if ([className hasSuffix:AspectsSubclassSuffix]) {
            Class originalClass = NSClassFromString([className stringByReplacingOccurrencesOfString:AspectsSubclassSuffix withString:@""]);
            NSCAssert(originalClass != nil, @"Original class must exist");
            object_setClass(self, originalClass);
            AspectLog(@"Aspects: %@ has been restored.", NSStringFromClass(originalClass));

            // We can only dispose the class pair if we can ensure that no instances exist using our subclass.
            // Since we don't globally track this, we can't ensure this - but there's also not much overhead in keeping it around.
            //objc_disposeClassPair(object.class);
        }else {
            // Class is most likely swizzled in place. Undo that.
            if (isMetaClass) {
                aspect_undoSwizzleClassInPlace((Class)self);
            }else if (self.class != klass) {
            	aspect_undoSwizzleClassInPlace(klass);
            }
        }
    }
}

///////////////////////////////////////////////////////////////////////////////////////////
#pragma mark - Hook Class

/**
 * 1、已经生成子类，则返回该子类
 * 2、如果baseClass是meta class的话，说明这个方法为类方法，就直接进入method swizzling。
 * 3、class元类或被KVO过，则直接进入method swizzling
 * 4、其他情况则先生成class的一个子类，再将class的isa指针指向那个子类，并对该子类进行method swizzling
 *
 *
 * 中间类的好处
    我们可以了解到Aspects的设计思想，hook 是在runtime中动态创建子类的基础上实现的。所有的 swizzling 操作都发生
    在子类，这样做的好处是你不需要去更改对象本身的类，也就是，当你在 remove aspects 的时候，如果发现当前对象的
    aspect 都被移除了，那么，你可以将 isa 指针重新指回对象本身的类，从而消除了该对象的 swizzling ,同时也不会影响
    到其他该类的不同对象)这样对原来替换的类或者对象没有任何影响而且可以在子类基础上新增或者删除aspect
 */
static Class aspect_hookClass(NSObject *self, NSError **error) {
    NSCParameterAssert(self);
	Class statedClass = self.class;         // -(id)class方法
	Class baseClass = object_getClass(self);// 获取isa
	NSString *className = NSStringFromClass(baseClass);

    // Already subclassed
    /** 当hook一个对象的selector时会生成一个子类，子类前缀就是AspectsSubclassSuffix。当self对应的类就是生成的子类，直接返回*/
	if ([className hasSuffix:AspectsSubclassSuffix]) {
        // 第一种情况其实是已经替换过了forwardInvocation的情况。
        // 意思就是无论怎么样，都至少调用过aspect_swizzleForwardInvocation方法。
		return baseClass;

        // We swizzle a class object, not a single object.
	}else if (class_isMetaClass(baseClass)) {
        return aspect_swizzleClassInPlace((Class)self);
        // Probably a KVO'ed class. Swizzle in place. Also swizzle meta classes in place.
    }else if (statedClass != baseClass) {
        // 如果是一个没有被监听过(KVO)的对象那么 statedClass == baseClass
        return aspect_swizzleClassInPlace(baseClass);
    }
    // 如果是一个没有对KVO的实例对象(注意不是class对象)
    // Default case. Create dynamic subclass.
	const char *subclassName = [className stringByAppendingString:AspectsSubclassSuffix].UTF8String;
	Class subclass = objc_getClass(subclassName);
    // 创建前缀就是AspectsSubclassSuffix的子类
	if (subclass == nil) {
		subclass = objc_allocateClassPair(baseClass, subclassName, 0);
		if (subclass == nil) {
            NSString *errrorDesc = [NSString stringWithFormat:@"objc_allocateClassPair failed to allocate class %s.", subclassName];
            AspectError(AspectErrorFailedToAllocateClassPair, errrorDesc);
            return nil;
        }
        // hook原类的forwardInvocation:
		aspect_swizzleForwardInvocation(subclass);
        // 就像KVO一样伪装
		aspect_hookedGetClass(subclass, statedClass);
		aspect_hookedGetClass(object_getClass(subclass), statedClass);
        // 注册
		objc_registerClassPair(subclass);
	}
    // 将self对象的isa指向子类
	object_setClass(self, subclass);
	return subclass;
}

static NSString *const AspectsForwardInvocationSelectorName = @"__aspects_forwardInvocation:";
static void aspect_swizzleForwardInvocation(Class klass) {
    NSCParameterAssert(klass);
    // If there is no method, replace will act like class_addMethod.
    // class_replaceMethod原来的实现
    IMP originalImplementation = class_replaceMethod(klass, @selector(forwardInvocation:), (IMP)__ASPECTS_ARE_BEING_CALLED__, "v@:@");
    if (originalImplementation) {
        class_addMethod(klass, NSSelectorFromString(AspectsForwardInvocationSelectorName), originalImplementation, "v@:@");
    }
    AspectLog(@"Aspects: %@ is now aspect aware.", NSStringFromClass(klass));
}

static void aspect_undoSwizzleForwardInvocation(Class klass) {
    NSCParameterAssert(klass);
    Method originalMethod = class_getInstanceMethod(klass, NSSelectorFromString(AspectsForwardInvocationSelectorName));
    Method objectMethod = class_getInstanceMethod(NSObject.class, @selector(forwardInvocation:));
    // There is no class_removeMethod, so the best we can do is to retore the original implementation, or use a dummy.
    IMP originalImplementation = method_getImplementation(originalMethod ?: objectMethod);
    class_replaceMethod(klass, @selector(forwardInvocation:), originalImplementation, "v@:@");

    AspectLog(@"Aspects: %@ has been restored.", NSStringFromClass(klass));
}

static void aspect_hookedGetClass(Class class, Class statedClass) {
    NSCParameterAssert(class);
    NSCParameterAssert(statedClass);
	Method method = class_getInstanceMethod(class, @selector(class));
	IMP newIMP = imp_implementationWithBlock(^(id self) {
		return statedClass;
	});
	class_replaceMethod(class, @selector(class), newIMP, method_getTypeEncoding(method));
}

///////////////////////////////////////////////////////////////////////////////////////////
#pragma mark - Swizzle Class In Place

static void _aspect_modifySwizzledClasses(void (^block)(NSMutableSet *swizzledClasses)) {
    static NSMutableSet *swizzledClasses;
    static dispatch_once_t pred;
    dispatch_once(&pred, ^{
        swizzledClasses = [NSMutableSet new];
    });
    @synchronized(swizzledClasses) {
        block(swizzledClasses);
    }
}

static Class aspect_swizzleClassInPlace(Class klass) {
    NSCParameterAssert(klass);
    NSString *className = NSStringFromClass(klass);

    _aspect_modifySwizzledClasses(^(NSMutableSet *swizzledClasses) {
        if (![swizzledClasses containsObject:className]) {
            aspect_swizzleForwardInvocation(klass);
            [swizzledClasses addObject:className];
        }
    });
    return klass;
}

static void aspect_undoSwizzleClassInPlace(Class klass) {
    NSCParameterAssert(klass);
    NSString *className = NSStringFromClass(klass);

    _aspect_modifySwizzledClasses(^(NSMutableSet *swizzledClasses) {
        if ([swizzledClasses containsObject:className]) {
            aspect_undoSwizzleForwardInvocation(klass);
            [swizzledClasses removeObject:className];
        }
    });
}

///////////////////////////////////////////////////////////////////////////////////////////
#pragma mark - Aspect Invoke Point

// This is a macro so we get a cleaner stack trace.
#define aspect_invoke(aspects, info) \
for (AspectIdentifier *aspect in aspects) {\
    [aspect invokeWithInfo:info];\
    if (aspect.options & AspectOptionAutomaticRemoval) { \
        aspectsToRemove = [aspectsToRemove?:@[] arrayByAddingObject:aspect]; \
    } \
}

// This is the swizzled forwardInvocation: method.
/** 
 * des:消息经过转发后都会来到这里（这里包括手动消息转发和自动消息转发）在这里进行统一的处理： 
 *     调用block，调用原方法实现
 */
static void __ASPECTS_ARE_BEING_CALLED__(__unsafe_unretained NSObject *self, SEL selector, NSInvocation *invocation) {
    NSCParameterAssert(self);
    NSCParameterAssert(invocation);
    SEL originalSelector = invocation.selector;
	SEL aliasSelector = aspect_aliasForSelector(invocation.selector);
    // 如果originalSelector被hook过，那么invocation的实际selector是aliasSelector
    // 替换invocation的selector，为了[invocation invoke] 调用原来的方法
    invocation.selector = aliasSelector;
    // 获取绑定在self中的aliasSelector
    AspectsContainer *objectContainer = objc_getAssociatedObject(self, aliasSelector);
    // 获取绑定在Class中的aliasSelecor
    AspectsContainer *classContainer = aspect_getContainerForClass(object_getClass(self), aliasSelector);
    
    AspectInfo *info = [[AspectInfo alloc] initWithInstance:self invocation:invocation];
    NSArray *aspectsToRemove = nil;

    // Before hooks.
    aspect_invoke(classContainer.beforeAspects, info);
    aspect_invoke(objectContainer.beforeAspects, info);

    // Instead hooks.
    BOOL respondsToAlias = YES;// 判断select是否被调用了
    if (objectContainer.insteadAspects.count || classContainer.insteadAspects.count) {
        aspect_invoke(classContainer.insteadAspects, info);
        aspect_invoke(objectContainer.insteadAspects, info);
    }else {
        // 没有Instead hooks时就执行selector 被hook之前的实现。
        Class klass = object_getClass(invocation.target);
        do {
            if ((respondsToAlias = [klass instancesRespondToSelector:aliasSelector])) {
                [invocation invoke];
                break;
            }
        }while (!respondsToAlias && (klass = class_getSuperclass(klass)));
    }

    // After hooks.
    aspect_invoke(classContainer.afterAspects, info);
    aspect_invoke(objectContainer.afterAspects, info);

    // If no hooks are installed, call original implementation (usually to throw an exception)
    /**调用一个没有实现的selector会触发 自动消息转发，在这种情况下整个继承链中都不会响应aliasSelector也就导致respondsToAlias=false, 开始执行下面的方法*/
    if (!respondsToAlias) {
        // 如果没有被调用，说明 originalSelector 没有被hook，所以将invocation.selector 改回来
        invocation.selector = originalSelector;
        // 原来的forwardInvocation
        SEL originalForwardInvocationSEL = NSSelectorFromString(AspectsForwardInvocationSelectorName);
        // 如果实现了forwardInvocation,执行原来的消息转发，否则调用doesNotRecognizeSelector，抛出异常。
        if ([self respondsToSelector:originalForwardInvocationSEL]) {
            ((void( *)(id, SEL, NSInvocation *))objc_msgSend)(self, originalForwardInvocationSEL, invocation);
        }else {
            [self doesNotRecognizeSelector:invocation.selector];
        }
    }

    // Remove any hooks that are queued for deregistration.
    [aspectsToRemove makeObjectsPerformSelector:@selector(remove)];
}
#undef aspect_invoke

///////////////////////////////////////////////////////////////////////////////////////////
#pragma mark - Aspect Container Management

// Loads or creates the aspect container.
static AspectsContainer *aspect_getContainerForObject(NSObject *self, SEL selector) {
    NSCParameterAssert(self);
    // 生成中间的SEL
    SEL aliasSelector = aspect_aliasForSelector(selector);
    // 从self中，获取AspectsContainer
    AspectsContainer *aspectContainer = objc_getAssociatedObject(self, aliasSelector);
    if (!aspectContainer) {
        // 如果没有AspectsContainer，就创建一个，并添加
        aspectContainer = [AspectsContainer new];
        // 以 aliasSelector 为 key 存储 aspectContainer
        objc_setAssociatedObject(self, aliasSelector, aspectContainer, OBJC_ASSOCIATION_RETAIN);
    }
    return aspectContainer;
}

static AspectsContainer *aspect_getContainerForClass(Class klass, SEL selector) {
    NSCParameterAssert(klass);
    AspectsContainer *classContainer = nil;
    do {
        classContainer = objc_getAssociatedObject(klass, selector);
        if (classContainer.hasAspects) break;
    }while ((klass = class_getSuperclass(klass)));

    return classContainer;
}

static void aspect_destroyContainerForObject(id<NSObject> self, SEL selector) {
    NSCParameterAssert(self);
    SEL aliasSelector = aspect_aliasForSelector(selector);
    objc_setAssociatedObject(self, aliasSelector, nil, OBJC_ASSOCIATION_RETAIN);
}

///////////////////////////////////////////////////////////////////////////////////////////
#pragma mark - Selector Blacklist Checking

static NSMutableDictionary *aspect_getSwizzledClassesDict() {
    static NSMutableDictionary *swizzledClassesDict;
    static dispatch_once_t pred;
    dispatch_once(&pred, ^{
        swizzledClassesDict = [NSMutableDictionary new];
    });
    return swizzledClassesDict;
}

/**
 *  1、这个方法主要是防止一些黑名单内的方法（retain, release, autorelease, forwardInvocation）
 *  2、以及已经被hook过的方法被hook。
 */
static BOOL aspect_isSelectorAllowedAndTrack(NSObject *self, SEL selector, AspectOptions options, NSError **error) {
    // 1、不允许hook的方法列表
    static NSSet *disallowedSelectorList;
    static dispatch_once_t pred;
    dispatch_once(&pred, ^{
        disallowedSelectorList = [NSSet setWithObjects:@"retain", @"release", @"autorelease", @"forwardInvocation:", nil];
    });

    // Check against the blacklist.
    NSString *selectorName = NSStringFromSelector(selector);
    if ([disallowedSelectorList containsObject:selectorName]) {
        NSString *errorDescription = [NSString stringWithFormat:@"Selector %@ is blacklisted.", selectorName];
        AspectError(AspectErrorSelectorBlacklisted, errorDescription);
        return NO;
    }

    // Additional checks.
    AspectOptions position = options&AspectPositionFilter;
    // 2、如果要切dealloc方法，只能在方法执行之前
    if ([selectorName isEqualToString:@"dealloc"] && position != AspectPositionBefore) {
        NSString *errorDesc = @"AspectPositionBefore is the only valid position when hooking dealloc.";
        AspectError(AspectErrorSelectorDeallocPosition, errorDesc);
        return NO;
    }

    // 判断方法是否存在
    if (![self respondsToSelector:selector] && ![self.class instancesRespondToSelector:selector]) {
        NSString *errorDesc = [NSString stringWithFormat:@"Unable to find selector -[%@ %@].", NSStringFromClass(self.class), selectorName];
        AspectError(AspectErrorDoesNotRespondToSelector, errorDesc);
        return NO;
    }

    // Search for the current class and the class hierarchy IF we are modifying a class object
    // class_isMetaClass 先判断是不是元类。接下来的判断都是判断元类里面能否允许被替换方法。
    // self 为 Class 那么 object_getClass(self) 是元类
    // self 为 对象   那么 object_getClass(self) 是类
    if (class_isMetaClass(object_getClass(self))) {
        // 当前类
        Class klass = [self class];
        NSMutableDictionary *swizzledClassesDict = aspect_getSwizzledClassesDict();
        // 当前类
        Class currentClass = [self class];

        AspectTracker *tracker = swizzledClassesDict[currentClass];
        if ([tracker subclassHasHookedSelectorName:selectorName]) {
            // 因为一个方法在一个类的层级里面只能被hook一次
            NSSet *subclassTracker = [tracker subclassTrackersHookingSelectorName:selectorName];
            NSSet *subclassNames = [subclassTracker valueForKey:@"trackedClassName"];
            NSString *errorDescription = [NSString stringWithFormat:@"Error: %@ already hooked subclasses: %@. A method can only be hooked once per class hierarchy.", selectorName, subclassNames];
            AspectError(AspectErrorSelectorAlreadyHookedInClassHierarchy, errorDescription);
            return NO;
        }

        do {
            tracker = swizzledClassesDict[currentClass];
            if ([tracker.selectorNames containsObject:selectorName]) {
                if (klass == currentClass) {
                    // Already modified and topmost!
                    return YES;
                }
                NSString *errorDescription = [NSString stringWithFormat:@"Error: %@ already hooked in %@. A method can only be hooked once per class hierarchy.", selectorName, NSStringFromClass(currentClass)];
                AspectError(AspectErrorSelectorAlreadyHookedInClassHierarchy, errorDescription);
                return NO;
            }
            // 寻找元类的父类
        } while ((currentClass = class_getSuperclass(currentClass)));//

        // Add the selector as being modified.
        // 将方法添加到对应类的tracker中
        currentClass = klass;
        AspectTracker *subclassTracker = nil;
        do {
            tracker = swizzledClassesDict[currentClass];
            if (!tracker) {
                // 根据当前类生成 tracker 对象
                tracker = [[AspectTracker alloc] initWithTrackedClass:currentClass];
                // 保存起来
                swizzledClassesDict[(id<NSCopying>)currentClass] = tracker;
            }
            if (subclassTracker) {
                [tracker addSubclassTracker:subclassTracker hookingSelectorName:selectorName];
            } else {
                // 存取hook的方法
                [tracker.selectorNames addObject:selectorName];
            }

            // All superclasses get marked as having a subclass that is modified.
            // 所有父类被标记为具有修改的子类。
            subclassTracker = tracker;
            // 拿到父类
        }while ((currentClass = class_getSuperclass(currentClass)));
	} else {
		return YES;
	}

    return YES;
}

static void aspect_deregisterTrackedSelector(id self, SEL selector) {
    if (!class_isMetaClass(object_getClass(self))) return;

    NSMutableDictionary *swizzledClassesDict = aspect_getSwizzledClassesDict();
    NSString *selectorName = NSStringFromSelector(selector);
    Class currentClass = [self class];
    AspectTracker *subclassTracker = nil;
    do {
        AspectTracker *tracker = swizzledClassesDict[currentClass];
        if (subclassTracker) {
            [tracker removeSubclassTracker:subclassTracker hookingSelectorName:selectorName];
        } else {
            [tracker.selectorNames removeObject:selectorName];
        }
        if (tracker.selectorNames.count == 0 && tracker.selectorNamesToSubclassTrackers) {
            [swizzledClassesDict removeObjectForKey:currentClass];
        }
        subclassTracker = tracker;
    }while ((currentClass = class_getSuperclass(currentClass)));
}

@end

@implementation AspectTracker

- (id)initWithTrackedClass:(Class)trackedClass {
    if (self = [super init]) {
        _trackedClass = trackedClass;
        _selectorNames = [NSMutableSet new];
        _selectorNamesToSubclassTrackers = [NSMutableDictionary new];
    }
    return self;
}

- (BOOL)subclassHasHookedSelectorName:(NSString *)selectorName {
    return self.selectorNamesToSubclassTrackers[selectorName] != nil;
}

- (void)addSubclassTracker:(AspectTracker *)subclassTracker hookingSelectorName:(NSString *)selectorName {
    NSMutableSet *trackerSet = self.selectorNamesToSubclassTrackers[selectorName];
    if (!trackerSet) {
        trackerSet = [NSMutableSet new];
        self.selectorNamesToSubclassTrackers[selectorName] = trackerSet;
    }
    [trackerSet addObject:subclassTracker];
}
- (void)removeSubclassTracker:(AspectTracker *)subclassTracker hookingSelectorName:(NSString *)selectorName {
    NSMutableSet *trackerSet = self.selectorNamesToSubclassTrackers[selectorName];
    [trackerSet removeObject:subclassTracker];
    if (trackerSet.count == 0) {
        [self.selectorNamesToSubclassTrackers removeObjectForKey:selectorName];
    }
}
- (NSSet *)subclassTrackersHookingSelectorName:(NSString *)selectorName {
    NSMutableSet *hookingSubclassTrackers = [NSMutableSet new];
    for (AspectTracker *tracker in self.selectorNamesToSubclassTrackers[selectorName]) {
        if ([tracker.selectorNames containsObject:selectorName]) {
            [hookingSubclassTrackers addObject:tracker];
        }
        [hookingSubclassTrackers unionSet:[tracker subclassTrackersHookingSelectorName:selectorName]];
    }
    return hookingSubclassTrackers;
}
- (NSString *)trackedClassName {
    return NSStringFromClass(self.trackedClass);
}

- (NSString *)description {
    return [NSString stringWithFormat:@"<%@: %@, trackedClass: %@, selectorNames:%@, subclass selector names: %@>", self.class, self, NSStringFromClass(self.trackedClass), self.selectorNames, self.selectorNamesToSubclassTrackers.allKeys];
}

@end

///////////////////////////////////////////////////////////////////////////////////////////
#pragma mark - NSInvocation (Aspects)

@implementation NSInvocation (Aspects)

// Thanks to the ReactiveCocoa team for providing a generic solution for this.
- (id)aspect_argumentAtIndex:(NSUInteger)index {
	const char *argType = [self.methodSignature getArgumentTypeAtIndex:index];
	// Skip const type qualifier.
	if (argType[0] == _C_CONST) argType++;

#define WRAP_AND_RETURN(type) do { type val = 0; [self getArgument:&val atIndex:(NSInteger)index]; return @(val); } while (0)
	if (strcmp(argType, @encode(id)) == 0 || strcmp(argType, @encode(Class)) == 0) {
		__autoreleasing id returnObj;
		[self getArgument:&returnObj atIndex:(NSInteger)index];
		return returnObj;
	} else if (strcmp(argType, @encode(SEL)) == 0) {
        SEL selector = 0;
        [self getArgument:&selector atIndex:(NSInteger)index];
        return NSStringFromSelector(selector);
    } else if (strcmp(argType, @encode(Class)) == 0) {
        __autoreleasing Class theClass = Nil;
        [self getArgument:&theClass atIndex:(NSInteger)index];
        return theClass;
        // Using this list will box the number with the appropriate constructor, instead of the generic NSValue.
	} else if (strcmp(argType, @encode(char)) == 0) {
		WRAP_AND_RETURN(char);
	} else if (strcmp(argType, @encode(int)) == 0) {
		WRAP_AND_RETURN(int);
	} else if (strcmp(argType, @encode(short)) == 0) {
		WRAP_AND_RETURN(short);
	} else if (strcmp(argType, @encode(long)) == 0) {
		WRAP_AND_RETURN(long);
	} else if (strcmp(argType, @encode(long long)) == 0) {
		WRAP_AND_RETURN(long long);
	} else if (strcmp(argType, @encode(unsigned char)) == 0) {
		WRAP_AND_RETURN(unsigned char);
	} else if (strcmp(argType, @encode(unsigned int)) == 0) {
		WRAP_AND_RETURN(unsigned int);
	} else if (strcmp(argType, @encode(unsigned short)) == 0) {
		WRAP_AND_RETURN(unsigned short);
	} else if (strcmp(argType, @encode(unsigned long)) == 0) {
		WRAP_AND_RETURN(unsigned long);
	} else if (strcmp(argType, @encode(unsigned long long)) == 0) {
		WRAP_AND_RETURN(unsigned long long);
	} else if (strcmp(argType, @encode(float)) == 0) {
		WRAP_AND_RETURN(float);
	} else if (strcmp(argType, @encode(double)) == 0) {
		WRAP_AND_RETURN(double);
	} else if (strcmp(argType, @encode(BOOL)) == 0) {
		WRAP_AND_RETURN(BOOL);
	} else if (strcmp(argType, @encode(bool)) == 0) {
		WRAP_AND_RETURN(BOOL);
	} else if (strcmp(argType, @encode(char *)) == 0) {
		WRAP_AND_RETURN(const char *);
	} else if (strcmp(argType, @encode(void (^)(void))) == 0) {
		__unsafe_unretained id block = nil;
		[self getArgument:&block atIndex:(NSInteger)index];
		return [block copy];
	} else {
		NSUInteger valueSize = 0;
		NSGetSizeAndAlignment(argType, &valueSize, NULL);

		unsigned char valueBytes[valueSize];
		[self getArgument:valueBytes atIndex:(NSInteger)index];

		return [NSValue valueWithBytes:valueBytes objCType:argType];
	}
	return nil;
#undef WRAP_AND_RETURN
}

- (NSArray *)aspects_arguments {
	NSMutableArray *argumentsArray = [NSMutableArray array];
	for (NSUInteger idx = 2; idx < self.methodSignature.numberOfArguments; idx++) {
        NSLog(@"idx=%@",[self aspect_argumentAtIndex:idx]);
		[argumentsArray addObject:[self aspect_argumentAtIndex:idx] ?: NSNull.null];
	}
	return [argumentsArray copy];
}

@end

///////////////////////////////////////////////////////////////////////////////////////////
#pragma mark - AspectIdentifier

@implementation AspectIdentifier

+ (instancetype)identifierWithSelector:(SEL)selector object:(id)object options:(AspectOptions)options block:(id)block error:(NSError **)error {
    NSCParameterAssert(block);
    NSCParameterAssert(selector);
    // 获取block的方法签名
    NSMethodSignature *blockSignature = aspect_blockMethodSignature(block, error); // TODO: check signature compatibility, etc.
    // 根据block的签名和要hook的selector对比，判断是否能hook
    if (!aspect_isCompatibleBlockSignature(blockSignature, object, selector, error)) {
        return nil;
    }

    AspectIdentifier *identifier = nil;
    if (blockSignature) {
        identifier = [AspectIdentifier new];
        identifier.selector = selector;
        identifier.block = block;
        identifier.blockSignature = blockSignature;
        identifier.options = options;
        identifier.object = object; // weak
    }
    return identifier;
}

// 执行AspectIdentifier中的block
- (BOOL)invokeWithInfo:(id<AspectInfo>)info {
    // block的Invocation
    NSInvocation *blockInvocation = [NSInvocation invocationWithMethodSignature:self.blockSignature];
    // 原始的Invocation
    NSInvocation *originalInvocation = info.originalInvocation;
    // 参数个数
    NSUInteger numberOfArguments = self.blockSignature.numberOfArguments;

    // Be extra paranoid. We already check that on hook registration.
    if (numberOfArguments > originalInvocation.methodSignature.numberOfArguments) {
        AspectLogError(@"Block has too many arguments. Not calling %@", info);
        return NO;
    }

    // The `self` of the block will be the AspectInfo. Optional.
    if (numberOfArguments > 1) {
        // 如果block有参数，下标为1的参数为info
        [blockInvocation setArgument:&info atIndex:1];
    }
    
    // 将originalInvocation中的参数取出来赋值到blockInvocation中
	void *argBuf = NULL;
    for (NSUInteger idx = 2; idx < numberOfArguments; idx++) {
        // 参数类型
        const char *type = [originalInvocation.methodSignature getArgumentTypeAtIndex:idx];
		NSUInteger argSize;
        // 类型占用的大小
		NSGetSizeAndAlignment(type, &argSize, NULL);
        // 为argBuf分配argSize大小的内存
		if (!(argBuf = reallocf(argBuf, argSize))) {
            AspectLogError(@"Failed to allocate memory for block invocation.");
			return NO;
		}
        // 获取值
		[originalInvocation getArgument:argBuf atIndex:idx];
        // 赋值
		[blockInvocation setArgument:argBuf atIndex:idx];
    }
    // 这里Target设置为self.block。也就执行了我们hook方法的block
    [blockInvocation invokeWithTarget:self.block];
    
    if (argBuf != NULL) {
        // 释放空间
        free(argBuf);
    }
    return YES;
}

- (NSString *)description {
    return [NSString stringWithFormat:@"<%@: %p, SEL:%@ object:%@ options:%tu block:%@ (#%tu args)>", self.class, self, NSStringFromSelector(self.selector), self.object, self.options, self.block, self.blockSignature.numberOfArguments];
}

- (BOOL)remove {
    return aspect_remove(self, NULL);
}

@end

///////////////////////////////////////////////////////////////////////////////////////////
#pragma mark - AspectsContainer

@implementation AspectsContainer

- (BOOL)hasAspects {
    return self.beforeAspects.count > 0 || self.insteadAspects.count > 0 || self.afterAspects.count > 0;
}

- (void)addAspect:(AspectIdentifier *)aspect withOptions:(AspectOptions)options {
    NSParameterAssert(aspect);
    NSUInteger position = options&AspectPositionFilter;
    switch (position) {
        case AspectPositionBefore:  self.beforeAspects  = [(self.beforeAspects ?:@[]) arrayByAddingObject:aspect];break;
        case AspectPositionInstead: self.insteadAspects = [(self.insteadAspects?:@[]) arrayByAddingObject:aspect]; break;
        case AspectPositionAfter:   {
            self.afterAspects   = [(self.afterAspects  ?:@[]) arrayByAddingObject:aspect];
        }
            break;
    }
}

- (BOOL)removeAspect:(id)aspect {
    for (NSString *aspectArrayName in @[NSStringFromSelector(@selector(beforeAspects)),
                                        NSStringFromSelector(@selector(insteadAspects)),
                                        NSStringFromSelector(@selector(afterAspects))]) {
        NSArray *array = [self valueForKey:aspectArrayName];
        NSUInteger index = [array indexOfObjectIdenticalTo:aspect];
        if (array && index != NSNotFound) {
            NSMutableArray *newArray = [NSMutableArray arrayWithArray:array];
            [newArray removeObjectAtIndex:index];
            [self setValue:newArray forKey:aspectArrayName];
            return YES;
        }
    }
    return NO;
}

- (NSString *)description {
    return [NSString stringWithFormat:@"<%@: %p, before:%@, instead:%@, after:%@>", self.class, self, self.beforeAspects, self.insteadAspects, self.afterAspects];
}

@end

///////////////////////////////////////////////////////////////////////////////////////////
#pragma mark - AspectInfo

@implementation AspectInfo

@synthesize arguments = _arguments;

- (id)initWithInstance:(__unsafe_unretained id)instance invocation:(NSInvocation *)invocation {
    NSCParameterAssert(instance);
    NSCParameterAssert(invocation);
    if (self = [super init]) {
        _instance = instance;
        _originalInvocation = invocation;
    }
    return self;
}

- (NSArray *)arguments {
    // Lazily evaluate arguments, boxing is expensive.
    if (!_arguments) {
        _arguments = self.originalInvocation.aspects_arguments;
    }
    return _arguments;
}

@end

// 参考资料
// http://blog.ypli.xyz/ios/aop-mian-xiang-qie-mian-bian-cheng-yu-aspects-yuan-ma-jie-xi
// http://www.jianshu.com/p/ededf8c7f4c6
// http://yulingtianxia.com/blog/2016/06/15/Objective-C-Message-Sending-and-Forwarding/
// http://tech.glowing.com/cn/implement-kvo/ 

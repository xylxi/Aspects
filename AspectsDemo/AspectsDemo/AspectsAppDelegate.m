//
//  AspectsAppDelegate.m
//  AspectsDemo
//
//  Created by Peter Steinberger on 03/05/14.
//  Copyright (c) 2014 PSPDFKit GmbH. All rights reserved.
//

#import "AspectsAppDelegate.h"
#import "AspectsViewController.h"
#import "Aspects.h"
#import <objc/runtime.h>

@implementation AspectsAppDelegate

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    AspectsViewController *aspectsController = [AspectsViewController new];
    self.window = [[UIWindow alloc] initWithFrame:[[UIScreen mainScreen] bounds]];
    self.window.backgroundColor = [UIColor whiteColor];
    self.window.rootViewController = [[UINavigationController alloc] initWithRootViewController:aspectsController];
    [self.window makeKeyAndVisible];
    
    [self addObserver:aspectsController forKeyPath:@"view" options:NSKeyValueObservingOptionNew context:nil];

    // Ignore hooks when we are testing.
    if (!NSClassFromString(@"XCTestCase")) {
        
        [aspectsController aspect_hookSelector:@selector(buttonPressed:) withOptions:0 usingBlock:^(id<AspectInfo> info, id sender) {
            NSLog(@"arg = %@",info.arguments);
        } error:NULL];
        
        [aspectsController aspect_hookSelector:@selector(buttonPressed:) withOptions:0 usingBlock:^() {
            NSLog(@"bind class button");
        } error:NULL];
    }

    return YES;
}

@end

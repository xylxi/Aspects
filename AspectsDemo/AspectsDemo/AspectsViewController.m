//
//  AspectsViewController.m
//  AspectsDemo
//
//  Created by DMW_W on 2017/6/14.
//  Copyright © 2017年 PSPDFKit GmbH. All rights reserved.
//

#import "AspectsViewController.h"
#import "Aspects.h"
#import "NSInvocation+Block.h"

@interface AspectsViewController ()

@end

@implementation AspectsViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor whiteColor];
    
    UIButton *button = [UIButton buttonWithType:UIButtonTypeCustom];
    [self.view addSubview:button];
    [button setTitle:@"tap" forState:UIControlStateNormal];
    [button setTitleColor:[UIColor redColor] forState:UIControlStateNormal];
    button.frame = CGRectMake(100, 100, 100, 100);
    [button addTarget:self action:@selector(buttonPressed:) forControlEvents:UIControlEventTouchUpInside];
    
    void (^myBlock)(id, NSArray*,double, int**) = ^(id obj1, NSArray* array, double dNum,int** pi) {
        NSLog(@"%@,Hey!",obj1);
    };
    int* i = NULL;
    NSInvocation* inv = [NSInvocation invocationWithBlockAndArguments:myBlock,[NSObject new],@[@1,@2,@3],1.23,&i];
    [inv invoke];
}


- (void)buttonPressed:(UIButton *)sender {
    AspectsViewController *vc = [[AspectsViewController alloc] init];
    vc.view.backgroundColor = [UIColor whiteColor];
    [self presentViewController:vc animated:YES completion:^{
        [vc aspect_hookSelector:@selector(buttonPressed:) withOptions:0 usingBlock:^(id info) {
            NSLog(@"bind self button2");
        } error:NULL];
    }];
}

+ (void)test {
    NSLog(@"test");
}

@end

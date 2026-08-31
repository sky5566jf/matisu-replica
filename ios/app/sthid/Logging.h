#pragma once
#import <Foundation/Foundation.h>
// shim：TrollVNC 的 TVLog 直接映射 NSLog
#define TVLog(...) NSLog(__VA_ARGS__)

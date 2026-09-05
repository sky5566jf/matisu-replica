// ShowUI.m — showUI 动态参数界面（WKWebView 渲染）
// 与 Android ShowUI.kt 同构：自包含 HTML（不依赖 mui）、JS collect() 遍历 form、
// 确认返回 1,值...；取消返回 0；config 持久化 'ui_input::::' 前缀 + '###' 拼接。
// iOS 特性：Service/后台线程不能直接建 UI → 主线程建独立 UIWindow（windowLevel 最高），
// 引擎线程用 semaphore 阻塞等 WKScriptMessageHandler 回传结果。
#import "ShowUI.h"
#import "MatisuPaths.h"
#import <WebKit/WebKit.h>
#import <UIKit/UIKit.h>

// ---------------- 全局状态 ----------------
static volatile NSString *gResultJson = nil;   // JS 回传 {"Submit":0/1,"Data":[...]}
static dispatch_semaphore_t gSem = nil;
static UIWindow *gShowWin = nil;
static WKWebView *gShowWeb = nil;
static id<WKScriptMessageHandler> gBridge = nil;

@interface ShowUIBridge : NSObject <WKScriptMessageHandler>
@property (assign) dispatch_semaphore_t sem;
@end
@implementation ShowUIBridge
- (void)userContentController:(WKUserContentController *)ucc
      didReceiveScriptMessage:(WKScriptMessage *)message {
    if (![message.body isKindOfClass:[NSString class]]) return;
    gResultJson = [message.body copy];
    dispatch_semaphore_signal(self.sem);
}
@end

// ---------------- 工具函数（对齐 Android 版） ----------------
static NSString *Esc(NSString *s) {
    if (!s) return @"";
    NSMutableString *m = [s mutableCopy];
    [m replaceOccurrencesOfString:@"&" withString:@"&amp;" options:0 range:NSMakeRange(0, m.length)];
    [m replaceOccurrencesOfString:@"<" withString:@"&lt;" options:0 range:NSMakeRange(0, m.length)];
    [m replaceOccurrencesOfString:@">" withString:@"&gt;" options:0 range:NSMakeRange(0, m.length)];
    [m replaceOccurrencesOfString:@"\"" withString:@"&quot;" options:0 range:NSMakeRange(0, m.length)];
    return m;
}

/// 颜色：数字直接用（R*65536+G*256+B）；'r,g,b' 字符串转 #RRGGBB
static NSString *ColorCss(id v) {
    if (!v) return nil;
    if ([v isKindOfClass:[NSNumber class]]) {
        long c = [v longValue] & 0xFFFFFF;
        return [NSString stringWithFormat:@"#%06lX", (unsigned long)c];
    }
    if ([v isKindOfClass:[NSString class]]) {
        NSArray<NSString *> *p = [v componentsSeparatedByString:@","];
        if (p.count == 3) {
            int r = [p[0] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]].intValue & 0xFF;
            int g = [p[1] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]].intValue & 0xFF;
            int b = [p[2] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]].intValue & 0xFF;
            return [NSString stringWithFormat:@"#%02X%02X%02X", r, g, b];
        }
    }
    return nil;
}

static NSArray<NSString *> *ItemsOf(NSDictionary *ut) {
    id arr = ut[@"item"];
    if ([arr isKindOfClass:[NSArray class]]) {
        NSMutableArray *r = [NSMutableArray array];
        for (id it in arr) [r addObject:[NSString stringWithFormat:@"%@", it ?: @""]];
        return r;
    }
    NSString *list = [ut[@"list"] isKindOfClass:[NSString class]] ? ut[@"list"] : nil;
    if (list.length) {
        NSMutableArray *r = [NSMutableArray array];
        for (NSString *it in [list componentsSeparatedByString:@","])
            [r addObject:[it stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]]];
        return r;
    }
    return @[];
}

/// select 字段：默认下标（0 起）或默认文本 → 0 起下标或 -1
static NSInteger SelectIdx(NSDictionary *ut, NSArray<NSString *> *items) {
    id v = ut[@"select"];
    if (!v) return -1;
    if ([v isKindOfClass:[NSNumber class]]) return [v integerValue];
    NSString *s = [NSString stringWithFormat:@"%@", v];
    if (s.length && [[NSCharacterSet decimalDigitCharacterSet] isSupersetOfSet:
         [NSCharacterSet characterSetWithCharactersInString:s]]) return [s integerValue];
    NSUInteger ix = [items indexOfObject:s];
    return ix == NSNotFound ? -1 : (NSInteger)ix;
}

static NSString *StyleOf(NSDictionary *ut) {
    NSMutableString *sb = [NSMutableString string];
    NSString *bg = ColorCss(ut[@"background"]);
    if (bg) [sb appendFormat:@"background-color:%@;", bg];
    NSString *fg = ColorCss(ut[@"color"]);
    if (fg) [sb appendFormat:@"color:%@;", fg];
    return sb;
}

// ---------------- uicfg 持久化 ----------------
static NSString *UicfgPath(NSString *name) {
    if (!name.length) return nil;
    NSMutableString *safe = [name mutableCopy];
    NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:@"[^A-Za-z0-9_\\-\\u4e00-\\u9fa5]" options:0 error:nil];
    [re replaceMatchesInString:safe options:0 range:NSMakeRange(0, safe.length) withTemplate:@"_"];
    NSString *dir = [MatisuDataRoot() stringByAppendingPathComponent:@"uicfg"];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    return [dir stringByAppendingPathComponent:[safe stringByAppendingString:@".xcfg"]];
}

static NSString *CfgValueAt(NSDictionary *utable, NSUInteger idx) {
    NSString *name = [utable[@"config"] isKindOfClass:[NSString class]] ? utable[@"config"] : nil;
    if (!name.length) return nil;
    NSString *p = UicfgPath(name);
    NSString *raw = [NSString stringWithContentsOfFile:p encoding:NSUTF8StringEncoding error:nil];
    if (!raw) return nil;
    if ([raw hasPrefix:@"ui_input::::"]) raw = [raw substringFromIndex:12];
    NSArray *parts = [raw componentsSeparatedByString:@"###"];
    if (idx >= parts.count) return nil;
    NSString *v = parts[idx];
    return v.length ? v : nil;
}

// ---------------- 控件 HTML（对齐 Android elementHtml） ----------------
static NSString *ElementHtml(NSDictionary *ut, NSString *cfgv) {
    NSString *type = [ut[@"type"] isKindOfClass:[NSString class]] ? ut[@"type"] : @"Label";
    NSString *st = StyleOf(ut);
    if ([type isEqualToString:@"Label"]) {
        NSString *text = [[ut[@"text"] isKindOfClass:[NSString class]] ? ut[@"text"] : @"" stringByReplacingOccurrencesOfString:@"\n" withString:@"<br>"];
        NSString *align = [ut[@"align"] isKindOfClass:[NSString class]] ? ut[@"align"] : @"center";
        return [NSString stringWithFormat:@"<div class=\"card\" style=\"%@\"><h4 align=\"%@\">%@</h4></div>", st, Esc(align), text];
    }
    if ([type isEqualToString:@"Edit"]) {
        NSString *def = cfgv ?: ([ut[@"text"] isKindOfClass:[NSString class]] ? ut[@"text"] : @"");
        return [NSString stringWithFormat:@"<form class=\"card\" name=\"input\"><div class=\"row\" style=\"%@\">"
                @"<label>%@</label>"
                @"<input type=\"text\" value=\"%@\" placeholder=\"%@\">"
                @"</div></form>", st, Esc(ut[@"caption"]), Esc(def), Esc(ut[@"prompt"])];
    }
    if ([type isEqualToString:@"EditMulti"]) {
        NSString *def = cfgv ?: ([ut[@"text"] isKindOfClass:[NSString class]] ? ut[@"text"] : @"");
        return [NSString stringWithFormat:@"<form class=\"card\" name=\"input\" style=\"%@\">"
                @"<textarea rows=\"%ld\" placeholder=\"%@\">%@</textarea>"
                @"</form>", st, (long)([ut[@"rows"] respondsToSelector:@selector(integerValue)] ? [ut[@"rows"] integerValue] : 2), Esc(ut[@"prompt"]), Esc(def)];
    }
    if ([type isEqualToString:@"RadioGroup"]) {
        NSArray *items = ItemsOf(ut);
        NSInteger def = cfgv.length ? [cfgv integerValue] : SelectIdx(ut, items);
        NSMutableString *sb = [NSMutableString string];
        [items enumerateObjectsUsingBlock:^(NSString *it, NSUInteger i, BOOL *stop) {
            [sb appendFormat:@"<div class=\"row radio\" style=\"%@\"><label>%@</label><input type=\"radio\" name=\"vradio\"%@></div>",
                st, Esc(it), ((def >= 0 && (NSUInteger)def == i) ? @" checked" : @"")];
        }];
        return [NSString stringWithFormat:@"<form class=\"card\" name=\"radio\">%@</form>", sb];
    }
    if ([type isEqualToString:@"ComboBox"]) {
        NSArray *items = ItemsOf(ut);
        NSInteger def = cfgv.length ? [cfgv integerValue] : SelectIdx(ut, items);
        NSMutableString *sb = [NSMutableString string];
        [items enumerateObjectsUsingBlock:^(NSString *it, NSUInteger i, BOOL *stop) {
            [sb appendFormat:@"<option value=\"%lu\"%@>%@</option>", (unsigned long)i,
                ((def >= 0 && (NSUInteger)def == i) ? @" selected" : @""), Esc(it)];
        }];
        return [NSString stringWithFormat:@"<form class=\"card\" name=\"select\"><select class=\"sel\" style=\"%@\">%@</select></form>", st, sb];
    }
    if ([type isEqualToString:@"CheckBoxGroup"]) {
        NSArray *items = ItemsOf(ut);
        NSMutableSet *checked = [NSMutableSet set];
        NSString *raw = cfgv;
        if (!raw) {
            id sv = ut[@"select"];
            if ([sv isKindOfClass:[NSString class]]) raw = sv;
            else if ([sv isKindOfClass:[NSArray class]]) {
                NSMutableArray *a = [NSMutableArray array];
                for (id it in sv) [a addObject:[NSString stringWithFormat:@"%@", it ?: @""]];
                raw = [a componentsJoinedByString:@"@"];
            } else raw = @"";
        }
        if (raw.length && [raw containsString:@"@"]) {
            for (NSString *p in [raw componentsSeparatedByString:@"@"]) {
                NSString *t = [p stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
                if (t.length && [[NSCharacterSet decimalDigitCharacterSet] isSupersetOfSet:
                     [NSCharacterSet characterSetWithCharactersInString:t]])
                    [checked addObject:@(t.integerValue)];
            }
        } else if (raw.length == items.count && [[NSCharacterSet characterSetWithCharactersInString:@"01"] isSupersetOfSet:
                     [NSCharacterSet characterSetWithCharactersInString:raw]]) {
            for (NSUInteger i = 0; i < raw.length; i++)
                if ([raw characterAtIndex:i] == '1') [checked addObject:@(i)];
        } else if (raw.length && [[NSCharacterSet decimalDigitCharacterSet] isSupersetOfSet:
                     [NSCharacterSet characterSetWithCharactersInString:raw]]) {
            [checked addObject:@(raw.integerValue)];
        }
        NSMutableString *sb = [NSMutableString string];
        [items enumerateObjectsUsingBlock:^(NSString *it, NSUInteger i, BOOL *stop) {
            [sb appendFormat:@"<div class=\"row radio\" style=\"%@\"><label>%@</label><input type=\"checkbox\" name=\"vcheckbox\"%@></div>",
                st, Esc(it), ([checked containsObject:@(i)] ? @" checked" : @"")];
        }];
        return [NSString stringWithFormat:@"<form class=\"card\" name=\"checkbox\">%@</form>", sb];
    }
    if ([type isEqualToString:@"Image"])
        return [NSString stringWithFormat:@"<div class=\"card\" style=\"%@\"><img src=\"%@\" style=\"width:100%%\"></div>", st, Esc(ut[@"src"])];
    if ([type isEqualToString:@"Iframe"])
        return [NSString stringWithFormat:@"<div class=\"card\"><iframe height=\"100%%\" width=\"100%%\" src=\"%@\" frameborder=\"0\"></iframe></div>", Esc(ut[@"src"])];
    return @"";
}

// ---------------- HTML 生成（对齐 Android buildHtml） ----------------
static NSString *BuildHtml(NSDictionary *utable) {
    NSArray *views = [utable[@"views"] isKindOfClass:[NSArray class]] ? utable[@"views"] : @[];
    NSMutableString *sb = [NSMutableString string];
    NSUInteger ci = 0;
    for (NSDictionary *v in views) {
        if (![v isKindOfClass:[NSDictionary class]]) continue;
        NSString *t = [v[@"type"] isKindOfClass:[NSString class]] ? v[@"type"] : @"Label";
        if ([t isEqualToString:@"Label"] || [t isEqualToString:@"Image"] || [t isEqualToString:@"Iframe"]) {
            [sb appendString:ElementHtml(v, nil)];
        } else {
            [sb appendString:ElementHtml(v, CfgValueAt(utable, ci))];
            ci++;
        }
    }
    long timer = [utable[@"timer"] respondsToSelector:@selector(longValue)] ? [utable[@"timer"] longValue] : 0;
    NSString *title = Esc([utable[@"title"] isKindOfClass:[NSString class]] ? utable[@"title"] : @"");
    NSString *cancelName = [utable[@"cancelname"] isKindOfClass:[NSString class]] && [utable[@"cancelname"] length]
        ? Esc(utable[@"cancelname"]) : Esc([utable[@"button"] isKindOfClass:[NSArray class]] && [utable[@"button"] count] > 0 ? [utable[@"button"] firstObject] : @"取消");
    NSString *okName = [utable[@"okname"] isKindOfClass:[NSString class]] && [utable[@"okname"] length]
        ? Esc(utable[@"okname"]) : Esc([utable[@"button"] isKindOfClass:[NSArray class]] && [utable[@"button"] count] > 1 ? utable[@"button"][1] : @"确认");
    NSString *timerJs = timer > 0
        ? [NSString stringWithFormat:@"var left=%ld;setInterval(function(){var e=document.getElementById('timex');e.innerText=left;left--;if(left<0){doSubmit(1);}},1000);", timer]
        : @"";
    return [NSString stringWithFormat:
        @"<!DOCTYPE html><html><head><meta charset=\"utf-8\">\n"
        @"<meta name=\"viewport\" content=\"width=device-width,initial-scale=1,maximum-scale=1,user-scalable=no\">\n"
        @"<title>%@</title>\n"
        @"<style>\n"
        @"body{margin:0;font-family:sans-serif;background:#f2f2f7;}\n"
        @"#bar{position:fixed;top:0;left:0;right:0;height:48px;background:#fff;border-bottom:1px solid #ddd;display:flex;align-items:center;justify-content:center;}\n"
        @"#bar h1{font-size:18px;margin:0;}\n"
        @"#timex{position:absolute;right:14px;color:#e64340;font-size:14px;}\n"
        @"#foot{position:fixed;bottom:0;left:0;right:0;height:56px;background:#fff;border-top:1px solid #ddd;display:flex;align-items:center;justify-content:center;gap:12px;}\n"
        @"#foot button{width:40%%;height:38px;font-size:16px;border:none;border-radius:6px;color:#fff;}\n"
        @"#btnCancel{background:#e64340;} #btnOk{background:#1aad19;}\n"
        @"#content{position:fixed;top:48px;bottom:56px;left:0;right:0;overflow-y:auto;padding:10px;}\n"
        @".card{background:#fff;border-radius:8px;margin:8px 0;padding:10px 12px;box-shadow:0 1px 2px rgba(0,0,0,.06);}\n"
        @".row{display:flex;align-items:center;padding:8px 0;border-bottom:1px solid #f0f0f0;}\n"
        @".row label{flex:1;font-size:15px;}\n"
        @".row input[type=text],textarea{flex:1;font-size:15px;border:none;outline:none;background:transparent;}\n"
        @"textarea{width:97%%;resize:vertical;}\n"
        @".radio{justify-content:space-between;}\n"
        @".radio input{width:20px;height:20px;}\n"
        @".sel{width:100%%;font-size:15px;padding:6px;border:1px solid #ddd;border-radius:4px;background:#fff;}\n"
        @"</style></head><body>\n"
        @"<div id=\"bar\"><h1>%@</h1><span id=\"timex\"></span></div>\n"
        @"<div id=\"content\">%@</div>\n"
        @"<div id=\"foot\"><button id=\"btnCancel\" onclick=\"doSubmit(0)\">%@</button>\n"
        @"<button id=\"btnOk\" onclick=\"doSubmit(1)\">%@</button></div>\n"
        @"<script>\n"
        @"function collect(){\n"
        @"  var out=[];\n"
        @"  var forms=document.querySelectorAll('form');\n"
        @"  for(var i=0;i<forms.length;i++){\n"
        @"    var f=forms[i],n=f.name;\n"
        @"    if(n==='input'){var inp=f.querySelector('input[type=text],textarea');out.push(inp?inp.value:'');}\n"
        @"    else if(n==='select'){var s=f.querySelector('select');out.push(s?s.value:'0');}\n"
        @"    else if(n==='radio'){var rs=f.querySelectorAll('input[type=radio]');var r='0';for(var j=0;j<rs.length;j++){if(rs[j].checked)r=String(j);}out.push(r);}\n"
        @"    else if(n==='checkbox'){var cs=f.querySelectorAll('input[type=checkbox]');var a=[];for(var j=0;j<cs.length;j++){if(cs[j].checked)a.push(j);}out.push(a.join('@'));}\n"
        @"  }\n"
        @"  return out;\n"
        @"}\n"
        @"function doSubmit(v){\n"
        @"  webkit.messageHandlers.matisu.postMessage(JSON.stringify({Submit:v,Data:collect()}));\n"
        @"}\n"
        @"%@\n"
        @"</script></body></html>",
        title, title, sb, cancelName, okName, timerJs];
}

// ---------------- 主入口 ----------------
NSArray<NSString *> *MatisuShowUIRun(NSDictionary *uitable) {
    if (![uitable isKindOfClass:[NSDictionary class]]) return @[@"0"];
    NSString *html = BuildHtml(uitable);
    long timerSec = [uitable[@"timer"] respondsToSelector:@selector(longValue)] ? [utable[@"timer"] longValue] : 0;
    gResultJson = nil;
    gSem = dispatch_semaphore_create(0);

    __block BOOL added = NO;
    dispatch_async(dispatch_get_main_queue(), ^{
        @try {
            UIWindow *win = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
            win.windowLevel = UIWindowLevelAlert + 100;
            UIViewController *vc = [[UIViewController alloc] init];
            win.rootViewController = vc;
            WKWebViewConfiguration *cfg = [[WKWebViewConfiguration alloc] init];
            ShowUIBridge *bridge = [ShowUIBridge new];
            bridge.sem = gSem;
            gBridge = bridge;
            [cfg.userContentController addScriptMessageHandler:bridge name:@"matisu"];
            WKWebView *wv = [[WKWebView alloc] initWithFrame:vc.view.bounds configuration:cfg];
            wv.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
            wv.backgroundColor = [UIColor whiteColor];
            [vc.view addSubview:wv];
            gShowWin = win; gShowWeb = wv;
            [win makeKeyAndVisible];
            [wv loadHTMLString:html baseURL:nil];
            added = YES;
        } @catch (NSException *e) {
            gShowWin = nil; gShowWeb = nil; gBridge = nil;
            dispatch_semaphore_signal(gSem);
        }
    });

    // JS 里的 timer 到时也会自动提交；这里只兜底总超时
    NSTimeInterval total = timerSec > 0 ? timerSec + 30.0 : 3600.0;
    if (total > 7200.0) total = 7200.0;
    dispatch_semaphore_wait(gSem, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(total * NSEC_PER_SEC)));

    NSString *res = gResultJson;
    gResultJson = nil;
    dispatch_async(dispatch_get_main_queue(), ^{
        @try {
            [gShowWeb.configuration.userContentController removeScriptMessageHandlerForName:@"matisu"];
            gShowWin.hidden = YES;
        } @catch (NSException *e) {}
        gShowWin = nil; gShowWeb = nil; gBridge = nil;
    });
    [NSThread sleepForTimeInterval:0.3];

    if (!added || !res) return @[@"0"];
    NSData *d = [res dataUsingEncoding:NSUTF8StringEncoding];
    NSDictionary *j = d ? [NSJSONSerialization JSONObjectWithData:d options:0 error:nil] : nil;
    if (![j isKindOfClass:[NSDictionary class]]) return @[@"0"];
    int submit = [j[@"Submit"] respondsToSelector:@selector(intValue)] ? [j[@"Submit"] intValue] : 0;
    NSArray *data = [j[@"Data"] isKindOfClass:[NSArray class]] ? j[@"Data"] : @[];

    NSMutableArray<NSString *> *out = [NSMutableArray array];
    if (submit == 1) {
        [out addObject:@"1"];
        for (id v in data) [out addObject:[NSString stringWithFormat:@"%@", v ?: @""]];
        // config 持久化
        NSString *cfgName = [uitable[@"config"] isKindOfClass:[NSString class]] ? uitable[@"config"] : nil;
        if (cfgName.length) {
            NSString *p = UicfgPath(cfgName);
            if (p) {
                NSString *joined = [out.subarrayFromIndex:1 componentsJoinedByString:@"###"];
                NSString *content = [NSString stringWithFormat:@"ui_input::::%@", joined];
                [content writeToFile:p atomically:YES encoding:NSUTF8StringEncoding error:nil];
            }
        }
    } else {
        [out addObject:@"0"];
    }
    return out;
}

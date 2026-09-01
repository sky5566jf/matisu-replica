// MatisuAuto — 主界面（设备信息 / 服务控制 / 文件浏览器）
#import <UIKit/UIKit.h>

@interface FileListVC : UIViewController <UITableViewDataSource, UITableViewDelegate>
- (instancetype)initWithDir:(NSString *)dir title:(NSString *)title;
@end

@interface MainVC : UIViewController
@end

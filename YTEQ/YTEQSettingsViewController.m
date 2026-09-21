#import "YTEQSettingsViewController.h"
#import "YTEQAudioEngine.h"

static NSArray *YTEQFreqLabels(void) {
    return @[@"32",@"64",@"125",@"250",@"500",@"1K",@"2K",@"4K",@"8K",@"16K"];
}
static NSArray *YTEQPresets(void) {
    return @[@"Flat",@"Bass Boost",@"Treble Boost",@"Vocal",@"Rock",@"Pop",@"Hip-Hop",@"Electronic",@"Jazz",@"Classical"];
}

@interface YTEQSettingsViewController ()
@property (nonatomic, strong) UISwitch *enableSwitch;
@property (nonatomic, strong) UISlider *preampSlider;
@property (nonatomic, strong) UILabel *preampLabel;
@property (nonatomic, strong) NSMutableArray<UISlider*> *sliders;
@property (nonatomic, strong) NSMutableArray<UILabel*> *valLabels;
@end

@implementation YTEQSettingsViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"YTEQ - EQ + Preamp";
    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone target:self action:@selector(close)];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"Flat" style:UIBarButtonItemStylePlain target:self action:@selector(resetFlat)];
    self.sliders = [NSMutableArray array];
    self.valLabels = [NSMutableArray array];
    self.tableView.keyboardDismissMode = UIScrollViewKeyboardDismissModeOnDrag;
}

- (void)close { [self dismissViewControllerAnimated:YES completion:nil]; }
- (void)resetFlat {
    [[YTEQAudioEngine shared] resetToFlat];
    [self.tableView reloadData];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)t { return 4; }
- (NSInteger)tableView:(UITableView *)t numberOfRowsInSection:(NSInteger)s {
    if (s==0) return 1; // enable
    if (s==1) return 1; // preamp
    if (s==2) return 10; // bands
    return 1; // presets
}
- (NSString*)tableView:(UITableView*)t titleForHeaderInSection:(NSInteger)s {
    if (s==0) return @"Power";
    if (s==1) return @"Preamp (-12dB to +12dB) - prevents clipping, boosts quiet";
    if (s==2) return @"10-Band Graphic EQ (-12dB to +12dB)";
    return @"Presets";
}

- (UITableViewCell*)tableView:(UITableView*)t cellForRowAtIndexPath:(NSIndexPath*)ip {
    YTEQAudioEngine *e = [YTEQAudioEngine shared];
    if (ip.section==0) {
        UITableViewCell *c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"en"];
        c.textLabel.text = @"Enable EQ";
        UISwitch *sw = [[UISwitch alloc] init];
        sw.on = e.enabled;
        [sw addTarget:self action:@selector(toggleEnable:) forControlEvents:UIControlEventValueChanged];
        c.accessoryView = sw;
        c.selectionStyle = UITableViewCellSelectionStyleNone;
        return c;
    }
    if (ip.section==1) {
        UITableViewCell *c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"pre"];
        c.selectionStyle = UITableViewCellSelectionStyleNone;
        UISlider *s = [[UISlider alloc] initWithFrame:CGRectMake(16,44, c.contentView.bounds.size.width-32, 30)];
        s.minimumValue=-12; s.maximumValue=12; s.value=e.preampDB;
        s.autoresizingMask = UIViewAutoresizingFlexibleWidth;
        [s addTarget:self action:@selector(preampChanged:) forControlEvents:UIControlEventValueChanged];
        [c.contentView addSubview:s];
        c.textLabel.text = [NSString stringWithFormat:@"Preamp: %+.1f dB (x%.2f)", e.preampDB, [e preampLinear]];
        c.detailTextLabel.text = @"Raise if EQ cuts make it quiet. Lower if distorted.";
        c.detailTextLabel.numberOfLines=0;
        return c;
    }
    if (ip.section==2) {
        UITableViewCell *c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"band"];
        c.selectionStyle = UITableViewCellSelectionStyleNone;
        NSArray *labels = YTEQFreqLabels();
        float g = [e.bandGains[ip.row] floatValue];
        c.textLabel.text = [NSString stringWithFormat:@"%@ Hz : %+.1f dB", labels[ip.row], g];
        UISlider *s = [[UISlider alloc] init];
        s.minimumValue=-12; s.maximumValue=12; s.value=g; s.tag=ip.row;
        s.translatesAutoresizingMaskIntoConstraints=NO;
        [s addTarget:self action:@selector(bandChanged:) forControlEvents:UIControlEventValueChanged];
        [c.contentView addSubview:s];
        [NSLayoutConstraint activateConstraints:@[
            [s.leadingAnchor constraintEqualToAnchor:c.contentView.leadingAnchor constant:16],
            [s.trailingAnchor constraintEqualToAnchor:c.contentView.trailingAnchor constant:-16],
            [s.topAnchor constraintEqualToAnchor:c.contentView.topAnchor constant:44],
            [s.bottomAnchor constraintEqualToAnchor:c.contentView.bottomAnchor constant:-8],
        ]];
        return c;
    }
    UITableViewCell *c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"pr"];
    c.textLabel.text = @"Presets…";
    c.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    return c;
}

- (void)tableView:(UITableView*)t didSelectRowAtIndexPath:(NSIndexPath*)ip {
    [t deselectRowAtIndexPath:ip animated:YES];
    if (ip.section!=3) return;
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"Preset" message:nil preferredStyle:UIAlertControllerStyleActionSheet];
    for (NSString *name in YTEQPresets()) {
        [a addAction:[UIAlertAction actionWithTitle:name style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *x){
            [[YTEQAudioEngine shared] applyPreset:name];
            [self.tableView reloadData];
        }]];
    }
    [a addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    // iPad popover
    a.popoverPresentationController.sourceView = self.view;
    a.popoverPresentationController.sourceRect = CGRectMake(self.view.bounds.size.width/2, self.view.bounds.size.height/2, 1, 1);
    [self presentViewController:a animated:YES completion:nil];
}

- (CGFloat)tableView:(UITableView*)t heightForRowAtIndexPath:(NSIndexPath*)ip {
    if (ip.section==1) return 110;
    if (ip.section==2) return 90;
    return 44;
}

- (void)toggleEnable:(UISwitch*)sw {
    [YTEQAudioEngine shared].enabled = sw.isOn;
    [[YTEQAudioEngine shared] saveSettings];
}
- (void)preampChanged:(UISlider*)s {
    [YTEQAudioEngine shared].preampDB = s.value;
    [[YTEQAudioEngine shared] saveSettings];
    // live label update without full reload (avoids slider jump)
    NSIndexPath *ip = [NSIndexPath indexPathForRow:0 inSection:1];
    UITableViewCell *c = [self.tableView cellForRowAtIndexPath:ip];
    c.textLabel.text = [NSString stringWithFormat:@"Preamp: %+.1f dB (x%.2f)", s.value, [[YTEQAudioEngine shared] preampLinear]];
}
- (void)bandChanged:(UISlider*)s {
    [YTEQAudioEngine shared].bandGains[s.tag] = @(s.value);
    // recalc happens lazily in processBuffer; force save
    [[YTEQAudioEngine shared] saveSettings];
    NSIndexPath *ip = [NSIndexPath indexPathForRow:s.tag inSection:2];
    UITableViewCell *c = [self.tableView cellForRowAtIndexPath:ip];
    NSArray *labels = YTEQFreqLabels();
    c.textLabel.text = [NSString stringWithFormat:@"%@ Hz : %+.1f dB", labels[s.tag], s.value];
}

@end

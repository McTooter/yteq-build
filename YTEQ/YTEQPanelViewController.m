#import "YTEQPanelViewController.h"
#import "YTEQAudioEngine.h"
#import "YTEQAudioHook.h"
#import "YTEQGraphView.h"

#import <math.h>

// ---------------------------------------------------------------------------
// Log-ish slider mappings
// ---------------------------------------------------------------------------
//
// Frequency spans three decades and Q spans two orders of magnitude, so both are mapped
// through a logarithmic curve onto the slider's 0..1 travel. Doing it this way (rather
// than fighting UISlider's linear track) keeps a constant on-screen distance equal to a
// constant perceptual step.

static double YTEQNormFromLog(double value, double min, double max) {
    if (max <= min) return 0.0;
    double t = (log(value) - log(min)) / (log(max) - log(min));
    return MIN(MAX(t, 0.0), 1.0);
}

static double YTEQLerpFromLog(double t, double min, double max) {
    return exp(log(min) + MIN(MAX(t, 0.0), 1.0) * (log(max) - log(min)));
}

static double YTEQNormLinear(double value, double min, double max) {
    if (max <= min) return 0.0;
    return MIN(MAX((value - min) / (max - min), 0.0), 1.0);
}

static double YTEQLerpLinear(double t, double min, double max) {
    return min + MIN(MAX(t, 0.0), 1.0) * (max - min);
}

static NSString *YTEQFormatHz(double hz) {
    if (hz >= 10000.0) return [NSString stringWithFormat:@"%.1fk", hz / 1000.0];
    if (hz >= 1000.0)  return [NSString stringWithFormat:@"%.2fk", hz / 1000.0];
    if (hz >= 100.0)   return [NSString stringWithFormat:@"%.0f", hz];
    return [NSString stringWithFormat:@"%.1f", hz];
}

static NSString *YTEQFormatDB(double db) {
    return [NSString stringWithFormat:@"%+.1f dB", db];
}

// ---------------------------------------------------------------------------
// Band row: one line in the band list
// ---------------------------------------------------------------------------

@interface YTEQBandRow : UIControl
@property (nonatomic, assign) NSInteger index;
- (void)applyBand:(YTEQBand)band selected:(BOOL)selected;
@end

@implementation YTEQBandRow {
    UILabel *_titleLabel;
    UILabel *_valueLabel;
    UIView  *_swatch;
}

- (instancetype)initWithIndex:(NSInteger)index {
    if ((self = [super initWithFrame:CGRectZero])) {
        _index = index;
        self.backgroundColor = [UIColor colorWithWhite:0.14 alpha:1.0];
        self.layer.cornerRadius = 8.0;

        _swatch = [[UIView alloc] initWithFrame:CGRectZero];
        _swatch.layer.cornerRadius = 3.0;
        [self addSubview:_swatch];

        _titleLabel = [[UILabel alloc] initWithFrame:CGRectZero];
        _titleLabel.font = [UIFont monospacedDigitSystemFontOfSize:13.0 weight:UIFontWeightMedium];
        _titleLabel.textColor = [UIColor whiteColor];
        [self addSubview:_titleLabel];

        _valueLabel = [[UILabel alloc] initWithFrame:CGRectZero];
        _valueLabel.font = [UIFont monospacedDigitSystemFontOfSize:12.0 weight:UIFontWeightRegular];
        _valueLabel.textAlignment = NSTextAlignmentRight;
        _valueLabel.textColor = [UIColor colorWithWhite:0.75 alpha:1.0];
        [self addSubview:_valueLabel];
    }
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGRect b = self.bounds;
    CGFloat pad = 10.0;
    _swatch.frame = CGRectMake(pad, (CGRectGetHeight(b) - 26.0) / 2.0, 4.0, 26.0);
    CGFloat x = pad + 4.0 + 8.0;
    CGFloat valueWidth = 108.0;
    _valueLabel.frame = CGRectMake(CGRectGetMaxX(b) - pad - valueWidth,
                                   (CGRectGetHeight(b) - 16.0) / 2.0, valueWidth, 16.0);
    _titleLabel.frame = CGRectMake(x, (CGRectGetHeight(b) - 16.0) / 2.0,
                                   CGRectGetWidth(b) - x - pad - valueWidth - 6.0, 16.0);
}

- (void)applyBand:(YTEQBand)band selected:(BOOL)selected {
    _titleLabel.text = [NSString stringWithFormat:@"%ld", (long)(self.index + 1)];

    NSString *detail;
    if (!band.enabled) {
        detail = @"off";
    } else if (band.type != YTEQFilterTypeParametric) {
        static NSArray *names;
        if (names == nil) {
            names = @[ @"Peaking", @"Low Shelf", @"High Shelf", @"Low Pass", @"High Pass",
                       @"Band Pass", @"Notch" ];
        }
        NSString *shape = (band.type >= 0 && (NSUInteger)band.type < names.count)
            ? names[(NSUInteger)band.type] : @"Peaking";
        detail = [NSString stringWithFormat:@"%@ · %@", shape, YTEQFormatHz(band.freq)];
    } else {
        detail = [NSString stringWithFormat:@"%@ · Q %.2f", YTEQFormatHz(band.freq), band.q];
    }
    _valueLabel.text = [NSString stringWithFormat:@"%@   %@", YTEQFormatDB(band.gainDB), detail];

    UIColor *tint = selected ? [UIColor colorWithRed:1.0 green:0.45 blue:0.20 alpha:1.0]
                             : [UIColor colorWithRed:0.29 green:0.76 blue:1.0 alpha:0.9];
    _swatch.backgroundColor = band.enabled ? tint : [UIColor colorWithWhite:0.3 alpha:1.0];
    _valueLabel.textColor = band.enabled ? [UIColor colorWithWhite:0.8 alpha:1.0]
                                         : [UIColor colorWithWhite:0.4 alpha:1.0];
    self.backgroundColor = selected ? [UIColor colorWithWhite:0.2 alpha:1.0]
                                    : [UIColor colorWithWhite:0.14 alpha:1.0];
    _titleLabel.textColor = band.enabled ? [UIColor whiteColor]
                                         : [UIColor colorWithWhite:0.45 alpha:1.0];
}

@end

// ---------------------------------------------------------------------------
// Slider row: label + slider + value, used for preamp and the three band params
// ---------------------------------------------------------------------------

@interface YTEQSliderRow : UIView
@property (nonatomic, copy) void (^onChange)(double value);
@property (nonatomic, copy) void (^onCommit)(void);
// min/max are the real value range. `logarithmic` decides how slider travel maps onto
// that range; `formatter` decides how the value is written.
- (void)configureWithTitle:(NSString *)title
                      min:(double)min
                      max:(double)max
              logarithmic:(BOOL)logarithmic
                 formatter:(NSString *(^)(double value))formatter;
- (void)setValue:(double)value;
- (double)value;
@end

@implementation YTEQSliderRow {
    UILabel  *_titleLabel;
    UILabel  *_valueLabel;
    UISlider *_slider;
    double    _min, _max;
    BOOL      _logarithmic;
    NSString *(^_formatter)(double);
}

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        _min = 0.0; _max = 1.0; _logarithmic = NO;
        _formatter = ^NSString *(double v) { return YTEQFormatDB(v); };

        _titleLabel = [[UILabel alloc] initWithFrame:CGRectZero];
        _titleLabel.font = [UIFont systemFontOfSize:12.0];
        _titleLabel.textColor = [UIColor colorWithWhite:0.6 alpha:1.0];
        [self addSubview:_titleLabel];

        _valueLabel = [[UILabel alloc] initWithFrame:CGRectZero];
        _valueLabel.font = [UIFont monospacedDigitSystemFontOfSize:12.0 weight:UIFontWeightMedium];
        _valueLabel.textAlignment = NSTextAlignmentRight;
        _valueLabel.textColor = [UIColor whiteColor];
        [self addSubview:_valueLabel];

        _slider = [[UISlider alloc] initWithFrame:CGRectZero];
        _slider.minimumValue = 0.0;
        _slider.maximumValue = 1.0;
        [_slider addTarget:self action:@selector(sliderChanged:) forControlEvents:UIControlEventValueChanged];
        [_slider addTarget:self action:@selector(sliderReleased:) forControlEvents:UIControlEventTouchUpInside |
                                                                            UIControlEventTouchUpOutside];
        [self addSubview:_slider];
    }
    return self;
}

- (void)configureWithTitle:(NSString *)title
                      min:(double)min
                      max:(double)max
              logarithmic:(BOOL)logarithmic
                 formatter:(NSString *(^)(double))formatter {
    _titleLabel.text = title;
    _min = min;
    _max = max;
    _logarithmic = logarithmic;
    _formatter = formatter ?: (^NSString *(double v) { return YTEQFormatDB(v); });
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGRect b = self.bounds;
    CGFloat labelWidth = 74.0;
    CGFloat valueWidth = 86.0;
    _titleLabel.frame  = CGRectMake(0, 0, labelWidth, 16.0);
    _valueLabel.frame  = CGRectMake(CGRectGetWidth(b) - valueWidth, 0, valueWidth, 16.0);
    _slider.frame      = CGRectMake(0, 17.0, CGRectGetWidth(b), 28.0);
}

- (double)value {
    return _logarithmic ? YTEQLerpFromLog(_slider.value, _min, _max)
                        : YTEQLerpLinear(_slider.value, _min, _max);
}

- (void)setValue:(double)value {
    double t = _logarithmic ? YTEQNormFromLog(value, _min, _max)
                            : YTEQNormLinear(value, _min, _max);
    _slider.value = (float)MIN(MAX(t, 0.0), 1.0);
    _valueLabel.text = _formatter(value);
}

- (void)sliderChanged:(UISlider *)slider {
    double value = _logarithmic ? YTEQLerpFromLog(slider.value, _min, _max)
                                : YTEQLerpLinear(slider.value, _min, _max);
    _valueLabel.text = _formatter(value);
    if (self.onChange) self.onChange(value);
}

- (void)sliderReleased:(UISlider *)slider {
    if (self.onCommit) self.onCommit();
}

@end

// ---------------------------------------------------------------------------
// Panel
// ---------------------------------------------------------------------------

@interface YTEQPanelViewController () <YTEQGraphViewDelegate>
@end

@implementation YTEQPanelViewController {
    UIScrollView       *_scrollView;
    UIStackView       *_stack;
    YTEQGraphView     *_graphView;
    UISwitch          *_enableSwitch;
    UILabel           *_statusLabel;
    UILabel           *_bandTitleLabel;
    YTEQSliderRow     *_preampRow;
    YTEQSliderRow     *_freqRow;
    YTEQSliderRow     *_gainRow;
    YTEQSliderRow     *_qRow;
    UISegmentedControl *_typeControl;
    NSMutableArray<YTEQBandRow *> *_bandRows;
    NSInteger _selectedBand;
}

+ (void)presentFromViewController:(UIViewController *)presenter {
    YTEQPanelViewController *panel = [[self alloc] init];
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:panel];
    nav.modalPresentationStyle = UIModalPresentationFormSheet;
    [presenter presentViewController:nav animated:YES completion:nil];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Equalizer";
    self.view.backgroundColor = [UIColor colorWithWhite:0.05 alpha:1.0];

    _selectedBand = -1;
    _bandRows = [NSMutableArray arrayWithCapacity:YTEQ_NUM_BANDS];

    self.navigationItem.rightBarButtonItem =
        [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone
                                                      target:self
                                                      action:@selector(dismissSelf)];

    [self buildScrollView];
    [self buildSections];
    [self rebuildBandRows];

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(settingsChanged:)
                                                 name:@"YTEQSettingsDidChange"
                                               object:nil];
    [self selectBand:[YTEQAudioEngine shared].selectedBand];
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)dismissSelf {
    [self dismissViewControllerAnimated:YES completion:nil];
}

#pragma mark - Layout

- (void)buildScrollView {
    _scrollView = [[UIScrollView alloc] initWithFrame:CGRectZero];
    _scrollView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _scrollView.alwaysBounceVertical = YES;
    [self.view addSubview:_scrollView];

    _stack = [[UIStackView alloc] initWithFrame:CGRectZero];
    _stack.axis = UILayoutConstraintAxisVertical;
    _stack.spacing = 10.0;
    _stack.translatesAutoresizingMaskIntoConstraints = NO;
    _scrollView.translatesAutoresizingMaskIntoConstraints = NO;
    [_scrollView addSubview:_stack];

    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
    UILayoutGuide *content = _scrollView.contentLayoutGuide;

    [NSLayoutConstraint activateConstraints:@[
        [_scrollView.topAnchor constraintEqualToAnchor:safe.topAnchor],
        [_scrollView.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor],
        [_scrollView.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor],
        [_scrollView.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor],

        [_stack.topAnchor constraintEqualToAnchor:content.topAnchor constant:10.0],
        [_stack.bottomAnchor constraintEqualToAnchor:content.bottomAnchor constant:-24.0],
        [_stack.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:16.0],
        [_stack.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-16.0],
        [_stack.widthAnchor constraintEqualToAnchor:_scrollView.widthAnchor constant:-32.0],
    ]];
}

- (UIView *)sectionContainer {
    UIView *container = [[UIView alloc] initWithFrame:CGRectZero];
    container.backgroundColor = [UIColor colorWithWhite:0.11 alpha:1.0];
    container.layer.cornerRadius = 12.0;
    return container;
}

- (UILabel *)sectionTitle:(NSString *)text {
    UILabel *label = [[UILabel alloc] initWithFrame:CGRectZero];
    label.text = text;
    label.font = [UIFont systemFontOfSize:11.0 weight:UIFontWeightSemibold];
    label.textColor = [UIColor colorWithWhite:0.5 alpha:1.0];
    return label;
}

- (void)buildSections {
    YTEQAudioEngine *engine = [YTEQAudioEngine shared];

    // ---- Power ----
    UIView *power = [self sectionContainer];
    UILabel *powerTitle = [self sectionTitle:@"POWER"];
    powerTitle.translatesAutoresizingMaskIntoConstraints = NO;

    UILabel *powerLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    powerLabel.text = @"Equalizer";
    powerLabel.font = [UIFont systemFontOfSize:16.0 weight:UIFontWeightMedium];
    powerLabel.textColor = [UIColor whiteColor];
    powerLabel.translatesAutoresizingMaskIntoConstraints = NO;

    _enableSwitch = [[UISwitch alloc] initWithFrame:CGRectZero];
    _enableSwitch.on = engine.enabled;
    [_enableSwitch addTarget:self action:@selector(enableChanged:)
            forControlEvents:UIControlEventValueChanged];
    _enableSwitch.translatesAutoresizingMaskIntoConstraints = NO;

    _statusLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _statusLabel.font = [UIFont systemFontOfSize:11.0];
    _statusLabel.textColor = [UIColor colorWithWhite:0.5 alpha:1.0];
    _statusLabel.numberOfLines = 2;
    _statusLabel.translatesAutoresizingMaskIntoConstraints = NO;

    [power addSubview:powerTitle];
    [power addSubview:powerLabel];
    [power addSubview:_enableSwitch];
    [power addSubview:_statusLabel];
    [NSLayoutConstraint activateConstraints:@[
        [powerTitle.topAnchor constraintEqualToAnchor:power.topAnchor constant:10.0],
        [powerTitle.leadingAnchor constraintEqualToAnchor:power.leadingAnchor constant:12.0],

        [powerLabel.topAnchor constraintEqualToAnchor:powerTitle.bottomAnchor constant:6.0],
        [powerLabel.leadingAnchor constraintEqualToAnchor:power.leadingAnchor constant:12.0],

        [_enableSwitch.centerYAnchor constraintEqualToAnchor:powerLabel.centerYAnchor],
        [_enableSwitch.trailingAnchor constraintEqualToAnchor:power.trailingAnchor constant:-12.0],

        [_statusLabel.topAnchor constraintEqualToAnchor:powerLabel.bottomAnchor constant:6.0],
        [_statusLabel.leadingAnchor constraintEqualToAnchor:power.leadingAnchor constant:12.0],
        [_statusLabel.trailingAnchor constraintEqualToAnchor:power.trailingAnchor constant:-12.0],
        [_statusLabel.bottomAnchor constraintEqualToAnchor:power.bottomAnchor constant:-10.0],
    ]];
    [_stack addArrangedSubview:power];
    [self updateStatusLabel];

    // ---- Graph ----
    UIView *graphCard = [self sectionContainer];
    _graphView = [[YTEQGraphView alloc] initWithFrame:CGRectZero];
    _graphView.delegate = self;
    _graphView.translatesAutoresizingMaskIntoConstraints = NO;
    _graphView.layer.cornerRadius = 8.0;
    _graphView.clipsToBounds = YES;
    [graphCard addSubview:_graphView];
    [NSLayoutConstraint activateConstraints:@[
        [_graphView.topAnchor constraintEqualToAnchor:graphCard.topAnchor constant:6.0],
        [_graphView.bottomAnchor constraintEqualToAnchor:graphCard.bottomAnchor constant:-6.0],
        [_graphView.leadingAnchor constraintEqualToAnchor:graphCard.leadingAnchor constant:6.0],
        [_graphView.trailingAnchor constraintEqualToAnchor:graphCard.trailingAnchor constant:-6.0],
        [_graphView.heightAnchor constraintEqualToConstant:210.0],
    ]];
    [_stack addArrangedSubview:graphCard];

    UILabel *graphHint = [[UILabel alloc] initWithFrame:CGRectZero];
    graphHint.text = @"Drag a handle to move it. Horizontal = frequency, vertical = gain.";
    graphHint.font = [UIFont systemFontOfSize:11.0];
    graphHint.textColor = [UIColor colorWithWhite:0.45 alpha:1.0];
    graphHint.numberOfLines = 0;
    [_stack addArrangedSubview:graphHint];

    // ---- Preamp ----
    UIView *preampCard = [self sectionContainer];
    UILabel *preampTitle = [self sectionTitle:@"PREAMP · MASTER OUTPUT LEVEL"];
    preampTitle.translatesAutoresizingMaskIntoConstraints = NO;

    _preampRow = [[YTEQSliderRow alloc] initWithFrame:CGRectZero];
    [_preampRow configureWithTitle:@"Preamp"
                              min:YTEQ_MIN_PREAMP max:YTEQ_MAX_PREAMP
                      logarithmic:NO
                         formatter:^NSString *(double v) { return YTEQFormatDB(v); }];
    [_preampRow setValue:engine.preampDB];
    _preampRow.translatesAutoresizingMaskIntoConstraints = NO;
    __weak typeof(self) weakSelf = self;
    _preampRow.onChange = ^(double value) { [weakSelf preampRowChanged:value]; };
    _preampRow.onCommit = ^{ [weakSelf commitSliderEdits]; };

    [preampCard addSubview:preampTitle];
    [preampCard addSubview:_preampRow];
    [NSLayoutConstraint activateConstraints:@[
        [preampTitle.topAnchor constraintEqualToAnchor:preampCard.topAnchor constant:10.0],
        [preampTitle.leadingAnchor constraintEqualToAnchor:preampCard.leadingAnchor constant:12.0],
        [_preampRow.topAnchor constraintEqualToAnchor:preampTitle.bottomAnchor constant:8.0],
        [_preampRow.leadingAnchor constraintEqualToAnchor:preampCard.leadingAnchor constant:12.0],
        [_preampRow.trailingAnchor constraintEqualToAnchor:preampCard.trailingAnchor constant:-12.0],
        [_preampRow.bottomAnchor constraintEqualToAnchor:preampCard.bottomAnchor constant:-10.0],
    ]];
    [_stack addArrangedSubview:preampCard];

    // ---- Selected band ----
    UIView *bandCard = [self sectionContainer];

    _bandTitleLabel = [self sectionTitle:@"BAND"];
    _bandTitleLabel.translatesAutoresizingMaskIntoConstraints = NO;

    UILabel *typeLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    typeLabel.text = @"Shape";
    typeLabel.font = [UIFont systemFontOfSize:12.0];
    typeLabel.textColor = [UIColor colorWithWhite:0.6 alpha:1.0];
    typeLabel.translatesAutoresizingMaskIntoConstraints = NO;

    _typeControl = [[UISegmentedControl alloc] initWithItems:@[ @"Peak", @"LoShelf", @"HiShelf", @"LoPass", @"HiPass", @"BandPass", @"Notch" ]];
    _typeControl.selectedSegmentIndex = 0;
    _typeControl.apportionsSegmentWidthsByContent = YES;
    [_typeControl addTarget:self action:@selector(typeChanged:)
           forControlEvents:UIControlEventValueChanged];
    _typeControl.translatesAutoresizingMaskIntoConstraints = NO;

    _freqRow = [[YTEQSliderRow alloc] initWithFrame:CGRectZero];
    [_freqRow configureWithTitle:@"Frequency"
                            min:YTEQ_MIN_FREQ max:YTEQ_MAX_FREQ
                    logarithmic:YES
                       formatter:^NSString *(double v) { return YTEQFormatHz(v); }];
    _freqRow.onChange = ^(double value) { [weakSelf freqRowChanged:value]; };
    _freqRow.onCommit = ^{ [weakSelf commitSliderEdits]; };
    _freqRow.translatesAutoresizingMaskIntoConstraints = NO;

    _gainRow = [[YTEQSliderRow alloc] initWithFrame:CGRectZero];
    [_gainRow configureWithTitle:@"Gain"
                            min:YTEQ_MIN_GAIN max:YTEQ_MAX_GAIN
                    logarithmic:NO
                       formatter:^NSString *(double v) { return YTEQFormatDB(v); }];
    _gainRow.onChange = ^(double value) { [weakSelf gainRowChanged:value]; };
    _gainRow.onCommit = ^{ [weakSelf commitSliderEdits]; };
    _gainRow.translatesAutoresizingMaskIntoConstraints = NO;

    // Q is driven through bandwidth-in-octaves so the slider track is perceptually even:
    // a linear Q slider spends most of its travel in a range that sounds identical.
    _qRow = [[YTEQSliderRow alloc] initWithFrame:CGRectZero];
    [_qRow configureWithTitle:@"Q / width"
                         min:YTEQBandwidthOctavesForQ(YTEQ_MAX_Q)
                         max:YTEQBandwidthOctavesForQ(YTEQ_MIN_Q)
                 logarithmic:YES
                    formatter:^NSString *(double octaves) {
                        double q = YTEQQForBandwidthOctaves(octaves);
                        return [NSString stringWithFormat:@"Q %.2f (%.1f oct)", q, octaves];
                    }];
    _qRow.onChange = ^(double value) { [weakSelf qRowChanged:value]; };
    _qRow.onCommit = ^{ [weakSelf commitSliderEdits]; };
    _qRow.translatesAutoresizingMaskIntoConstraints = NO;

    for (UIView *view in @[ _bandTitleLabel, typeLabel, _typeControl,
                            _freqRow, _gainRow, _qRow ]) {
        [bandCard addSubview:view];
    }

    [NSLayoutConstraint activateConstraints:@[
        [_bandTitleLabel.topAnchor constraintEqualToAnchor:bandCard.topAnchor constant:10.0],
        [_bandTitleLabel.leadingAnchor constraintEqualToAnchor:bandCard.leadingAnchor constant:12.0],
        [_bandTitleLabel.trailingAnchor constraintEqualToAnchor:bandCard.trailingAnchor constant:-12.0],

        [typeLabel.topAnchor constraintEqualToAnchor:_bandTitleLabel.bottomAnchor constant:8.0],
        [typeLabel.leadingAnchor constraintEqualToAnchor:bandCard.leadingAnchor constant:12.0],

        [_typeControl.topAnchor constraintEqualToAnchor:typeLabel.bottomAnchor constant:4.0],
        [_typeControl.leadingAnchor constraintEqualToAnchor:bandCard.leadingAnchor constant:12.0],
        [_typeControl.trailingAnchor constraintEqualToAnchor:bandCard.trailingAnchor constant:-12.0],

        [_freqRow.topAnchor constraintEqualToAnchor:_typeControl.bottomAnchor constant:10.0],
        [_freqRow.leadingAnchor constraintEqualToAnchor:bandCard.leadingAnchor constant:12.0],
        [_freqRow.trailingAnchor constraintEqualToAnchor:bandCard.trailingAnchor constant:-12.0],

        [_gainRow.topAnchor constraintEqualToAnchor:_freqRow.bottomAnchor constant:4.0],
        [_gainRow.leadingAnchor constraintEqualToAnchor:_freqRow.leadingAnchor],
        [_gainRow.trailingAnchor constraintEqualToAnchor:_freqRow.trailingAnchor],

        [_qRow.topAnchor constraintEqualToAnchor:_gainRow.bottomAnchor constant:4.0],
        [_qRow.leadingAnchor constraintEqualToAnchor:_freqRow.leadingAnchor],
        [_qRow.trailingAnchor constraintEqualToAnchor:_freqRow.trailingAnchor],
        [_qRow.bottomAnchor constraintEqualToAnchor:bandCard.bottomAnchor constant:-10.0],
    ]];
    [_stack addArrangedSubview:bandCard];

    // ---- Presets ----
    UIView *presetCard = [self sectionContainer];
    UILabel *presetTitle = [self sectionTitle:@"PRESETS"];
    presetTitle.translatesAutoresizingMaskIntoConstraints = NO;

    UIStackView *presetRow = [[UIStackView alloc] initWithFrame:CGRectZero];
    presetRow.axis = UILayoutConstraintAxisHorizontal;
    presetRow.distribution = UIStackViewDistributionFillEqually;
    presetRow.spacing = 6.0;
    presetRow.translatesAutoresizingMaskIntoConstraints = NO;

    for (NSString *name in @[ @"Flat", @"Loudness", @"Bass Boost", @"Vocal" ]) {
        UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
        [button setTitle:name forState:UIControlStateNormal];
        [button setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
        button.titleLabel.font = [UIFont systemFontOfSize:12.0];
        button.backgroundColor = [UIColor colorWithWhite:0.2 alpha:1.0];
        button.layer.cornerRadius = 8.0;
        NSUInteger index = [[YTEQAudioEngine presetNames] indexOfObject:name];
        button.tag = (NSInteger)index;
        [button addTarget:self action:@selector(presetTapped:) forControlEvents:UIControlEventTouchUpInside];
        [presetRow addArrangedSubview:button];
    }

    [presetCard addSubview:presetTitle];
    [presetCard addSubview:presetRow];
    [NSLayoutConstraint activateConstraints:@[
        [presetTitle.topAnchor constraintEqualToAnchor:presetCard.topAnchor constant:10.0],
        [presetTitle.leadingAnchor constraintEqualToAnchor:presetCard.leadingAnchor constant:12.0],
        [presetRow.topAnchor constraintEqualToAnchor:presetTitle.bottomAnchor constant:8.0],
        [presetRow.leadingAnchor constraintEqualToAnchor:presetCard.leadingAnchor constant:12.0],
        [presetRow.trailingAnchor constraintEqualToAnchor:presetCard.trailingAnchor constant:-12.0],
        [presetRow.heightAnchor constraintEqualToConstant:32.0],
        [presetRow.bottomAnchor constraintEqualToAnchor:presetCard.bottomAnchor constant:-10.0],
    ]];
    [_stack addArrangedSubview:presetCard];

    // ---- Band list ----
    UILabel *listTitle = [self sectionTitle:@"BANDS · TAP TO SELECT"];
    [_stack addArrangedSubview:listTitle];
}

- (void)rebuildBandRows {
    for (YTEQBandRow *row in _bandRows) {
        [_stack removeArrangedSubview:row];
        [row removeFromSuperview];
    }
    [_bandRows removeAllObjects];

    for (NSInteger i = 0; i < YTEQ_NUM_BANDS; i++) {
        YTEQBandRow *row = [[YTEQBandRow alloc] initWithIndex:i];
        row.translatesAutoresizingMaskIntoConstraints = NO;
        [row addTarget:self action:@selector(bandRowTapped:) forControlEvents:UIControlEventTouchUpInside];
        [NSLayoutConstraint activateConstraints:@[
            [row.heightAnchor constraintEqualToConstant:38.0],
        ]];
        [_stack addArrangedSubview:row];
        [_bandRows addObject:row];
    }
    [self refreshBandRows];
}

#pragma mark - State <-> UI

- (void)settingsChanged:(NSNotification *)note {
    [self refreshBandRows];
    [_graphView refresh];
    [self updateStatusLabel];
}

- (void)refreshBandRows {
    YTEQAudioEngine *engine = [YTEQAudioEngine shared];
    for (NSInteger i = 0; i < (NSInteger)_bandRows.count; i++) {
        [_bandRows[(NSUInteger)i] applyBand:[engine bandAtIndex:i] selected:(i == _selectedBand)];
    }
}

- (void)selectBand:(NSInteger)index {
    if (index < 0 || index >= YTEQ_NUM_BANDS) return;
    _selectedBand = index;
    [YTEQAudioEngine shared].selectedBand = index;
    _graphView.selectedBand = index;

    YTEQBand band = [[YTEQAudioEngine shared] bandAtIndex:index];
    _bandTitleLabel.text = [NSString stringWithFormat:@"BAND %ld · %.0f Hz", (long)(index + 1), band.freq];

    // Frequency is baked into LowPass / HighPass / BandPass / Notch, so it is hidden for
    // those rather than shown as a control that does nothing.
    BOOL frequencyMatters = (band.type == YTEQFilterTypeParametric ||
                             band.type == YTEQFilterTypeLowShelf ||
                             band.type == YTEQFilterTypeHighShelf);
    _freqRow.hidden = !frequencyMatters;
    // Q only describes how wide a peak is. Shelves and the notched shapes have no peak.
    _qRow.hidden = (band.type != YTEQFilterTypeParametric);

    [_freqRow setValue:band.freq];
    [_gainRow setValue:band.gainDB];
    [_qRow setValue:YTEQBandwidthOctavesForQ(band.q)];
    _typeControl.selectedSegmentIndex = band.type;

    [self refreshBandRows];
    [_graphView refresh];
}

- (void)updateStatusLabel {
    if (_statusLabel == nil) return;

    if ([YTEQAudioHook hasSeenAudio]) {
        _statusLabel.text = [NSString stringWithFormat:@"Audio running · %.0f kHz · %d ch",
                             [YTEQAudioHook observedSampleRate] / 1000.0,
                             [YTEQAudioHook observedChannels]];
        _statusLabel.textColor = [UIColor colorWithRed:0.30 green:0.80 blue:0.45 alpha:1.0];
    } else if ([YTEQAudioHook renderCallbackInstalled]) {
        _statusLabel.text = @"Hooked · play something to activate";
        _statusLabel.textColor = [UIColor colorWithWhite:0.6 alpha:1.0];
    } else {
        _statusLabel.text = @"Waiting for audio output…";
        _statusLabel.textColor = [UIColor colorWithWhite:0.6 alpha:1.0];
    }
}

#pragma mark - Actions

- (void)enableChanged:(UISwitch *)sender {
    [YTEQAudioEngine shared].enabled = sender.isOn;
    [self commitSliderEdits];
}

- (void)preampRowChanged:(double)value {
    [YTEQAudioEngine shared].preampDB = value;
    [_graphView refresh];
}

- (void)freqRowChanged:(double)value {
    YTEQBand band = [[YTEQAudioEngine shared] bandAtIndex:_selectedBand];
    band.freq = value;
    [[YTEQAudioEngine shared] setBand:band atIndex:_selectedBand];
    _bandTitleLabel.text = [NSString stringWithFormat:@"BAND %ld · %.0f Hz",
                            (long)(_selectedBand + 1), value];
    [_graphView refresh];
}

- (void)gainRowChanged:(double)value {
    YTEQBand band = [[YTEQAudioEngine shared] bandAtIndex:_selectedBand];
    band.gainDB = value;
    [[YTEQAudioEngine shared] setBand:band atIndex:_selectedBand];
    [_graphView refresh];
}

- (void)qRowChanged:(double)octaves {
    YTEQBand band = [[YTEQAudioEngine shared] bandAtIndex:_selectedBand];
    band.q = YTEQQForBandwidthOctaves(octaves);
    [[YTEQAudioEngine shared] setBand:band atIndex:_selectedBand];
    [_graphView refresh];
}

- (void)typeChanged:(UISegmentedControl *)sender {
    YTEQBand band = [[YTEQAudioEngine shared] bandAtIndex:_selectedBand];
    band.type = (int)sender.selectedSegmentIndex;
    [[YTEQAudioEngine shared] setBand:band atIndex:_selectedBand];
    [self selectBand:_selectedBand];
}

- (void)bandRowTapped:(YTEQBandRow *)sender {
    [self selectBand:sender.index];
}

- (void)presetTapped:(UIButton *)sender {
    NSArray<NSString *> *names = [YTEQAudioEngine presetNames];
    if (sender.tag < 0 || (NSUInteger)sender.tag >= names.count) return;
    [[YTEQAudioEngine shared] applyPresetNamed:names[(NSUInteger)sender.tag]];
    [self selectBand:_selectedBand];
}

// Slider moves already write through to the engine (so the graph tracks live) and the
// engine deliberately does not persist per tick. This is the one place a drag commits.
- (void)commitSliderEdits {
    [[YTEQAudioEngine shared] save];
    [self refreshBandRows];
    [_graphView refresh];
}

#pragma mark - YTEQGraphViewDelegate

- (void)graphView:(YTEQGraphView *)view didChangeBand:(YTEQBand)band atIndex:(NSInteger)index {
    if (index != _selectedBand) {
        _selectedBand = index;
        view.selectedBand = index;
        [YTEQAudioEngine shared].selectedBand = index;
    }
    [[YTEQAudioEngine shared] setBand:band atIndex:index];

    _bandTitleLabel.text = [NSString stringWithFormat:@"BAND %ld · %.0f Hz",
                            (long)(index + 1), band.freq];
    [_freqRow setValue:band.freq];
    [_gainRow setValue:band.gainDB];
    [_qRow setValue:YTEQBandwidthOctavesForQ(band.q)];
    [self refreshBandRows];
}

- (void)graphView:(YTEQGraphView *)view didSelectBandAtIndex:(NSInteger)index {
    [self selectBand:index];
}

@end

#import "YTEQGraphView.h"
#import <math.h>

static const double kGraphMinFreq = YTEQ_MIN_FREQ;   // 20 Hz
static const double kGraphMaxFreq = YTEQ_MAX_FREQ;   // 20 kHz
static const double kGraphDBRange = 15.0;             // +/- dB shown vertically

static const CGFloat kPlotLeft   = 34.0;
static const CGFloat kPlotRight  = 12.0;
static const CGFloat kPlotTop    = 14.0;
static const CGFloat kPlotBottom = 22.0;

static const CGFloat kHandleRadius = 11.0;
static const CGFloat kTouchSlop    = 30.0;

@implementation YTEQGraphView {
    YTEQBand _bands[YTEQ_NUM_BANDS];
    double   _preampDB;
    double   _sampleRate;
    NSInteger _draggingBand;
    CGPoint  _dragOrigin;      // touch location when the drag started
    YTEQBand _dragStartBand;   // band values when the drag started
}

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.backgroundColor = [UIColor colorWithWhite:0.08 alpha:1.0];
        self.opaque = YES;
        _draggingBand = NSNotFound;
        _selectedBand = -1;
        _editingEnabled = YES;
        [self refresh];
    }
    return self;
}

- (void)setEditingEnabled:(BOOL)editingEnabled {
    if (_editingEnabled == editingEnabled) return;
    _editingEnabled = editingEnabled;
    self.userInteractionEnabled = editingEnabled;
}

- (void)setSelectedBand:(NSInteger)selectedBand {
    if (_selectedBand == selectedBand) return;
    _selectedBand = selectedBand;
    [self setNeedsDisplay];
}

- (void)refresh {
    YTEQAudioEngine *engine = [YTEQAudioEngine shared];
    [engine copyBandsInto:_bands count:YTEQ_NUM_BANDS];
    _preampDB    = engine.preampDB;
    _sampleRate  = engine.graphSampleRate;
    [self setNeedsDisplay];
}

#pragma mark - Geometry

- (CGRect)plotRect {
    CGRect b = self.bounds;
    CGFloat left   = kPlotLeft;
    CGFloat right  = MAX(CGRectGetWidth(b) - kPlotRight, left + 1.0);
    CGFloat top    = kPlotTop;
    CGFloat bottom = MAX(CGRectGetHeight(b) - kPlotBottom, top + 1.0);
    return CGRectMake(left, top, right - left, bottom - top);
}

// Frequency -> x. Logarithmic, which is the only axis on which music EQ looks linear.
- (CGFloat)xForFreq:(double)freq {
    double t = (log10(freq) - log10(kGraphMinFreq)) /
               (log10(kGraphMaxFreq) - log10(kGraphMinFreq));
    CGRect p = self.plotRect;
    return CGRectGetMinX(p) + (CGFloat)t * CGRectGetWidth(p);
}

- (double)freqForX:(CGFloat)x {
    CGRect p = self.plotRect;
    double t = (x - CGRectGetMinX(p)) / MAX(CGRectGetWidth(p), 1.0);
    t = MIN(MAX(t, 0.0), 1.0);
    return pow(10.0, log10(kGraphMinFreq) + t * (log10(kGraphMaxFreq) - log10(kGraphMinFreq)));
}

- (CGFloat)yForDB:(double)db {
    CGRect p = self.plotRect;
    double clamped = MIN(MAX(db, -kGraphDBRange), kGraphDBRange);
    return CGRectGetMidY(p) - (CGFloat)(clamped / kGraphDBRange) * (CGRectGetHeight(p) / 2.0);
}

- (double)dbForY:(CGFloat)y {
    CGRect p = self.plotRect;
    double half = CGRectGetHeight(p) / 2.0;
    if (half <= 0.0) return 0.0;
    return (CGRectGetMidY(p) - y) / half * kGraphDBRange;
}

- (CGPoint)pointForBandAtIndex:(NSInteger)index {
    return CGPointMake(xForFreq(_bands[index].freq),
                       yForDB(_preampDB + _bands[index].gainDB));
}

#pragma mark - Response

// Total chain response in dB at a frequency. Sampled per pixel column, which is plenty:
// the curve is smooth at this width and the math is cheap enough at ~300 points.
- (double)responseDBAt:(double)freq {
    return YTEQResponseDB(_bands, _preampDB, freq, _sampleRate);
}

#pragma mark - Drawing

- (void)drawRect:(CGRect)rect {
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    if (ctx == NULL) return;

    CGRect p = self.plotRect;

    // Background inside the plot.
    CGContextSetFillColorWithColor(ctx, [UIColor colorWithWhite:0.11 alpha:1.0].CGColor);
    CGContextFillRect(ctx, p);

    [self drawGridInContext:ctx plot:p];
    [self drawCurveInContext:ctx plot:p];
    [self drawPreampLineInContext:ctx plot:p];
    [self drawHandlesInContext:ctx plot:p];
    [self drawAxisLabelsInContext:ctx plot:p];
}

- (void)drawGridInContext:(CGContextRef)ctx plot:(CGRect)p {
    CGContextSaveGState(ctx);

    // Horizontal dB grid.
    static const double dBSteps[] = { -15, -10, -5, 0, 5, 10, 15 };
    for (size_t i = 0; i < sizeof(dBSteps) / sizeof(dBSteps[0]); i++) {
        double db = dBSteps[i];
        CGFloat y = round([self yForDB:db]) + 0.5;
        BOOL isZero = (db == 0.0);
        CGContextSetStrokeColorWithColor(ctx, [UIColor colorWithWhite:isZero ? 0.45 : 0.22
                                                                 alpha:1.0].CGColor);
        CGContextSetLineWidth(ctx, isZero ? 1.0 : 0.5);
        CGContextMoveToPoint(ctx, CGRectGetMinX(p), y);
        CGContextAddLineToPoint(ctx, CGRectGetMaxX(p), y);
        CGContextStrokePath(ctx);
    }

    // Vertical octave grid.
    for (int oct = 1; oct <= 10; oct++) {
        double freq = 20.0 * pow(2.0, oct);
        if (freq > kGraphMaxFreq) break;
        CGFloat x = round([self xForFreq:freq]) + 0.5;
        BOOL major = (oct % 2) == 0;
        CGContextSetStrokeColorWithColor(ctx, [UIColor colorWithWhite:major ? 0.24 : 0.16
                                                                 alpha:1.0].CGColor);
        CGContextSetLineWidth(ctx, 0.5);
        CGContextMoveToPoint(ctx, x, CGRectGetMinY(p));
        CGContextAddLineToPoint(ctx, x, CGRectGetMaxY(p));
        CGContextStrokePath(ctx);
    }

    CGContextRestoreGState(ctx);
}

- (void)drawCurveInContext:(CGContextRef)ctx plot:(CGRect)p {
    CGFloat width = CGRectGetWidth(p);
    int steps = (int)MAX(width, 2.0);
    if (steps > 1024) steps = 1024;

    CGMutablePathRef line = CGPathCreateMutable();
    CGPathRef fill = CGPathCreateMutable();

    CGFloat firstX = CGRectGetMinX(p);
    double firstFreq = [self freqForX:firstX];
    double firstDB = [self responseDBAt:firstFreq];
    CGPathMoveToPoint(line, NULL, firstX, [self yForDB:firstDB]);
    CGPathMoveToPoint(fill, NULL, firstX, CGRectGetMaxY(p));
    CGPathAddLineToPoint(fill, NULL, firstX, [self yForDB:firstDB]);

    for (int i = 1; i <= steps; i++) {
        CGFloat x = CGRectGetMinX(p) + (CGFloat)i * (width / (CGFloat)steps);
        if (x > CGRectGetMaxX(p)) x = CGRectGetMaxX(p);
        double freq = [self freqForX:x];
        double db   = [self responseDBAt:freq];
        CGFloat y   = [self yForDB:db];
        CGPathAddLineToPoint(line, NULL, x, y);
        CGPathAddLineToPoint(fill, NULL, x, y);
    }

    CGFloat lastX = CGRectGetMaxX(p);
    CGPathAddLineToPoint(line, NULL, lastX, [self yForDB:[self responseDBAt:kGraphMaxFreq]]);
    CGPathAddLineToPoint(fill, NULL, lastX, CGRectGetMaxY(p));
    CGPathCloseSubpath(fill);

    // Filled area under the curve, clipped to the plot so an over-driven curve does not
    // bleed into the axis labels.
    CGContextSaveGState(ctx);
    CGContextAddRect(ctx, p);
    CGContextClip(ctx);

    CGContextAddPath(ctx, fill);
    CGContextSetFillColorWithColor(ctx, [UIColor colorWithRed:0.20 green:0.62 blue:1.0 alpha:0.22].CGColor);
    CGContextFillPath(ctx);

    CGContextAddPath(ctx, line);
    CGContextSetStrokeColorWithColor(ctx, [UIColor colorWithRed:0.29 green:0.76 blue:1.0 alpha:1.0].CGColor);
    CGContextSetLineWidth(ctx, 2.0);
    CGContextSetLineJoin(ctx, kCGLineJoinRound);
    CGContextStrokePath(ctx);

    CGContextRestoreGState(ctx);

    CGPathRelease(line);
    CGPathRelease(fill);
}

- (void)drawPreampLineInContext:(CGContextRef)ctx plot:(CGRect)p {
    if (fabs(_preampDB) < 0.05) return;
    CGFloat y = round([self yForDB:_preampDB]) + 0.5;
    CGContextSaveGState(ctx);
    CGMutablePathRef dash = CGPathCreateMutable();
    CGPathMoveToPoint(dash, NULL, CGRectGetMinX(p), y);
    CGPathAddLineToPoint(dash, NULL, CGRectGetMaxX(p), y);
    CGContextAddPath(ctx, dash);
    CGContextSetStrokeColorWithColor(ctx, [UIColor colorWithRed:1.0 green:0.72 blue:0.24 alpha:0.65].CGColor);
    CGContextSetLineWidth(ctx, 1.0);
    const CGFloat pattern[] = { 4.0, 3.0 };
    CGContextSetLineDash(ctx, 0.0, pattern, 2);
    CGContextStrokePath(ctx);
    CGContextRestoreGState(ctx);
    CGPathRelease(dash);
}

- (void)drawHandlesInContext:(CGContextRef)ctx plot:(CGRect)p {
    CGContextSaveGState(ctx);
    CGContextAddRect(ctx, p);
    CGContextClip(ctx);

    for (NSInteger i = 0; i < YTEQ_NUM_BANDS; i++) {
        if (!_bands[i].enabled) continue;
        CGPoint point = [self pointForBandAtIndex:i];
        BOOL selected = (i == _selectedBand);

        // Q shown as the band's -3 dB footprint. Without this the graph gives no hint of
        // how wide the band is, which is the one parameter it cannot show on an axis.
        if (_bands[i].type == YTEQFilterTypeParametric) {
            double octaves = YTEQBandwidthOctavesForQ(_bands[i].q) * 0.5;
            double edgeLo = fmax(_bands[i].freq / pow(2.0, octaves), kGraphMinFreq);
            double edgeHi = fmin(_bands[i].freq * pow(2.0, octaves), kGraphMaxFreq);
            CGFloat xLo = [self xForFreq:edgeLo];
            CGFloat xHi = [self xForFreq:edgeHi];
            CGRect foot = CGRectMake(xLo, CGRectGetMinY(p), MAX(xHi - xLo, 1.0),
                                     CGRectGetHeight(p));
            CGContextSetFillColorWithColor(ctx, [UIColor colorWithRed:0.29 green:0.76 blue:1.0
                                                             alpha:selected ? 0.16 : 0.08].CGColor);
            CGContextFillRect(ctx, foot);
        }

        UIColor *fill   = selected ? [UIColor colorWithRed:1.0 green:0.45 blue:0.20 alpha:1.0]
                                   : [UIColor colorWithRed:0.29 green:0.76 blue:1.0 alpha:0.95];
        UIColor *stroke = selected ? [UIColor whiteColor] : [UIColor whiteColor];

        CGRect circle = CGRectMake(point.x - kHandleRadius, point.y - kHandleRadius,
                                   kHandleRadius * 2.0, kHandleRadius * 2.0);
        CGContextSetFillColorWithColor(ctx, fill.CGColor);
        CGContextFillEllipseInRect(ctx, circle);
        CGContextSetStrokeColorWithColor(ctx, stroke.CGColor);
        CGContextSetLineWidth(ctx, selected ? 2.5 : 1.5);
        CGContextStrokeEllipseInRect(ctx, circle);
    }

    CGContextRestoreGState(ctx);
}

- (void)drawAxisLabelsInContext:(CGContextRef)ctx plot:(CGRect)p {
    NSDictionary *small = @{ NSFontAttributeName : [UIFont systemFontOfSize:9.0],
                             NSForegroundColorAttributeName : [UIColor colorWithWhite:0.55 alpha:1.0] };
    NSDictionary *tiny  = @{ NSFontAttributeName : [UIFont systemFontOfSize:8.0],
                             NSForegroundColorAttributeName : [UIColor colorWithWhite:0.40 alpha:1.0] };

    // dB labels down the left edge.
    static const double dBSteps[] = { 15, 10, 5, 0, -5, -10, -15 };
    for (size_t i = 0; i < sizeof(dBSteps) / sizeof(dBSteps[0]); i++) {
        double db = dBSteps[i];
        NSString *text = [NSString stringWithFormat:@"%+d", (int)db];
        CGSize size = [text sizeWithAttributes:small];
        CGFloat y = [self yForDB:db] - size.height / 2.0;
        [text drawAtPoint:CGPointMake(CGRectGetMinX(p) - size.width - 4.0, y)
           withAttributes:small];
    }

    // Frequency labels along the bottom.
    for (int oct = 1; oct <= 10; oct++) {
        double freq = 20.0 * pow(2.0, oct);
        if (freq > kGraphMaxFreq) break;
        BOOL major = (oct % 2) == 0;
        if (!major && CGRectGetWidth(p) < 300.0) continue;

        NSString *text;
        if (freq >= 1000.0) {
            text = [NSString stringWithFormat:@"%gk", (int)round(freq / 1000.0)];
        } else {
            text = [NSString stringWithFormat:@"%d", (int)round(freq)];
        }
        CGSize size = [text sizeWithAttributes:tiny];
        CGFloat x = [self xForFreq:freq] - size.width / 2.0;
        if (x < CGRectGetMinX(p) - 2.0 || x + size.width > CGRectGetMaxX(p) + 2.0) continue;
        [text drawAtPoint:CGPointMake(x, CGRectGetMaxY(p) + 3.0) withAttributes:tiny];
    }

    // Corner label so the horizontal axis is self-describing.
    NSString *hint = @"Hz";
    CGSize hintSize = [hint sizeWithAttributes:tiny];
    [hint drawAtPoint:CGPointMake(CGRectGetMinX(p) - hintSize.width - 4.0,
                                  CGRectGetMaxY(p) + 3.0)
       withAttributes:tiny];
}

#pragma mark - Interaction

- (NSInteger)bandNearestPoint:(CGPoint)point {
    NSInteger best = NSNotFound;
    CGFloat bestDistance = CGFLOAT_MAX;
    for (NSInteger i = 0; i < YTEQ_NUM_BANDS; i++) {
        if (!_bands[i].enabled) continue;
        CGPoint handle = [self pointForBandAtIndex:i];
        CGFloat dx = handle.x - point.x, dy = handle.y - point.y;
        CGFloat distance = sqrt(dx * dx + dy * dy);
        if (distance < bestDistance) { bestDistance = distance; best = i; }
    }
    return bestDistance <= kTouchSlop ? best : NSNotFound;
}

- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    if (!_editingEnabled) { [super touchesBegan:touches withEvent:event]; return; }
    UITouch *touch = touches.anyObject;
    if (touch == nil) return;

    CGPoint point = [touch locationInView:self];
    NSInteger index = [self bandNearestPoint:point];
    if (index == NSNotFound) {
        // Tap on empty space: select the band whose frequency is closest horizontally,
        // which is friendlier than ignoring the tap when handles overlap at low Q.
        NSInteger nearest = NSNotFound;
        CGFloat best = CGFLOAT_MAX;
        for (NSInteger i = 0; i < YTEQ_NUM_BANDS; i++) {
            if (!_bands[i].enabled) continue;
            CGFloat dx = [self xForFreq:_bands[i].freq] - point.x;
            if (fabs(dx) < best) { best = fabs(dx); nearest = i; }
        }
        index = (best <= kTouchSlop * 1.5) ? nearest : NSNotFound;
        if (index == NSNotFound) return;
    }

    _draggingBand = index;
    _dragOrigin = point;
    _dragStartBand = _bands[index];
    _selectedBand = index;
    [self.delegate graphView:self didSelectBandAtIndex:index];
    [self setNeedsDisplay];
}

- (void)touchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    if (_draggingBand == NSNotFound) { [super touchesMoved:touches withEvent:event]; return; }
    UITouch *touch = touches.anyObject;
    if (touch == nil) return;

    CGPoint point = [touch locationInView:self];

    // x -> frequency, y -> gain. The gain is stored relative to preamp so the preamp
    // slider stays an independent master control rather than fighting the bands.
    double freq = [self freqForX:point.x];
    double gain = [self dbForY:point.y] - _preampDB;
    gain = MIN(MAX(gain, YTEQ_MIN_GAIN), YTEQ_MAX_GAIN);

    YTEQBand band = _dragStartBand;
    band.freq   = MIN(MAX(freq, YTEQ_MIN_FREQ), YTEQ_MAX_FREQ);
    band.gainDB = gain;

    _bands[_draggingBand] = band;
    [self.delegate graphView:self didChangeBand:band atIndex:_draggingBand];
    [self setNeedsDisplay];
}

- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    if (_draggingBand == NSNotFound) { [super touchesEnded:touches withEvent:event]; return; }
    _draggingBand = NSNotFound;
}

- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    _draggingBand = NSNotFound;
    [super touchesCancelled:touches withEvent:event];
}

@end

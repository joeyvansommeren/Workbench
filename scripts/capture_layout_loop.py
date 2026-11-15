"""lldb script: when AppKit throws its layout-loop exception, name the views that
are still dirty, then detach. Read-only: it changes nothing in the app.

Usage (attach):  lldb -b -p <pid> -o "command script import scripts/capture_layout_loop.py" -o "capture_loop <report-path>"
"""
import lldb

REPORT = "/tmp/layout-loop-capture.txt"
ANY = False  # test mode ("any" as second argument): capture on any Objective-C exception


def _expr(frame, code):
    options = lldb.SBExpressionOptions()
    options.SetLanguage(lldb.eLanguageTypeObjC)
    options.SetTimeoutInMicroSeconds(5_000_000)
    options.SetIgnoreBreakpoints(True)
    options.SetTryAllThreads(False)
    return frame.EvaluateExpression(code, options)


def _text(frame, code):
    value = _expr(frame, "(const char *)[(NSString *)(%s) UTF8String]" % code)
    summary = value.GetSummary()
    return summary.strip('"') if summary else "<%s>" % value.GetError().GetCString()


# One ObjC expression walks the main window's view tree and reports every view
# whose constraints or layout are still dirty, with its class, frame and depth.
WALK = r'''
({
  NSMutableString *out = [NSMutableString string];
  NSWindow *target = nil;
  for (NSWindow *w in (NSArray *)[(NSApplication *)[NSApplication sharedApplication] windows]) {
    if ([w contentView] != nil && (target == nil || [w frame].size.width > [target frame].size.width)) target = w;
  }
  [out appendFormat:@"window %@ frame %@\n", [target className], NSStringFromRect((NSRect)[target frame])];
  NSView *root = (NSView *)[[target contentView] superview] ?: (NSView *)[target contentView];
  NSMutableArray *stack = [NSMutableArray array];
  if (root != nil) [stack addObject:@[root, @0]];
  int total = 0, dirty = 0;
  while ([stack count] > 0) {
    NSArray *entry = [stack lastObject]; [stack removeLastObject];
    NSView *view = (NSView *)entry[0]; int depth = (int)[(NSNumber *)entry[1] intValue]; total++;
    BOOL c = (BOOL)[view needsUpdateConstraints]; BOOL l = (BOOL)[view needsLayout];
    if (c || l) {
      dirty++;
      [out appendFormat:@"%@%@ depth=%d %@ frame=%@ parent=%@\n", c ? @"C" : @"-", l ? @"L" : @"-", depth,
        [view className], NSStringFromRect((NSRect)[view frame]), [[view superview] className]];
    }
    for (NSView *sub in (NSArray *)[view subviews]) [stack addObject:@[sub, @(depth + 1)]];
  }
  [out appendFormat:@"views=%d dirty=%d\n", total, dirty];
  out;
})
'''


def on_throw(frame, location, extra_args, internal_dict):
    thread = frame.GetThread()
    process = thread.GetProcess()
    names = [thread.GetFrameAtIndex(i).GetFunctionName() or "?" for i in range(min(thread.GetNumFrames(), 40))]
    if not ANY and not any("_postWindowNeedsUpdateConstraints" in name for name in names):
        return False  # another exception: keep running
    lines = ["=== layout-loop capture ===", "backtrace:"] + ["  %2d %s" % (i, n[:110]) for i, n in enumerate(names)]
    lines.append("dirty views (C = constraints, L = layout):")
    # The walk must not re-enter this callback if AppKit throws again.
    target = process.GetTarget()
    for index in range(target.GetNumBreakpoints()):
        target.GetBreakpointAtIndex(index).SetEnabled(False)
    _expr(frame, "@import AppKit;")
    lines.append(_text(frame, WALK).replace("\\n", "\n"))
    report = "\n".join(lines)
    with open(REPORT, "w") as handle:
        handle.write(report + "\n")
    print(report)
    process.Detach()
    return False


def capture_loop(debugger, command, result, internal_dict):
    global REPORT, ANY
    parts = command.split()
    if parts:
        REPORT = parts[0]
    ANY = len(parts) > 1 and parts[1] == "any"
    target = debugger.GetSelectedTarget()
    breakpoint = target.BreakpointCreateByName("objc_exception_throw")
    breakpoint.SetScriptCallbackFunction("capture_layout_loop.on_throw")
    breakpoint.SetAutoContinue(False)
    print("capture armed; report -> %s" % REPORT)


def __lldb_init_module(debugger, internal_dict):
    debugger.HandleCommand("command script add -f capture_layout_loop.capture_loop capture_loop")

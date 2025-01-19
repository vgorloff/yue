// Copyright 2016 Cheng Zhao. All rights reserved.
// Copyright 2016 The Chromium Authors. All rights reserved.
// Use of this source code is governed by the license that can be found in the
// LICENSE file.

#include "nativeui/mac/nu_view.h"

#include "base/strings/sys_string_conversions.h"
#include "base/apple/foundation_util.h"
#include "base/apple/scoped_cftyperef.h"
#include "nativeui/browser.h"
#include "nativeui/container.h"
#include "nativeui/cursor.h"
#include "nativeui/gfx/font.h"
#include "nativeui/gfx/geometry/point_conversions.h"
#include "nativeui/gfx/geometry/rect_conversions.h"
#include "nativeui/gfx/mac/coordinate_conversion.h"
#include "nativeui/gfx/mac/painter_mac.h"
#include "nativeui/mac/drag_drop/data_provider.h"
#include "nativeui/mac/drag_drop/nested_run_loop.h"
#include "nativeui/mac/events_handler.h"
#include "nativeui/mac/legacy_bridging.h"
#include "nativeui/mac/nu_private.h"
#include "nativeui/mac/nu_responder.h"
#include "nativeui/window.h"

namespace nu {

namespace {

// It's much more convenient to return an NSString than a
// base::apple::ScopedCFTypeRef<CFStringRef>, since the methods on NSPasteboardItem
// require an NSString*.
NSString* UTIFromPboardType(NSString* type) {
  // Some PboardType are already valid UTI strings.
  if ([type rangeOfString:@"public."].location == 0)
    return type;
  return [CFToNSCast(UTTypeCreatePreferredIdentifierForTag(
      kUTTagClassNSPboardType, NSToCFCast(type), kUTTypeData)) autorelease];
}

}  // namespace

void View::PlatformDestroy() {
  if (IsNUResponder(view_)) {
    // Release all hooks before destroying the view.
    [view_ disableTracking];
    CancelDrag();
    ReleaseCapture();
    // The view may be referenced after this class gets destroyed.
    NUViewPrivate* priv = [view_ nuPrivate];
    priv->shell = nullptr;
  }
  [view_ release];
}

void View::TakeOverView(NativeView view) {
  InitResponder(view_ = view, Type::View);

  [view_ setClipsToBounds:YES]; // See why we need to clip to bounds: https://stackoverflow.com/q/77375566/1418981

  if (!IsNUResponder(view))
    return;

  // Install events handle for the view's class.
  InstallNUViewMethods([view class]);

  // Initialize private bits of the view.
  NUViewPrivate* priv = [view nuPrivate];
  priv->shell = this;

  // Set the |focusable| property to the parent class's default one.
  SEL cmd = @selector(acceptsFirstResponder);
  auto super_impl = reinterpret_cast<BOOL (*)(NSView*, SEL)>(
      [[view superclass] instanceMethodForSelector:cmd]);
  priv->focusable = super_impl(view, cmd);

  // Set the |draggable| property to the parent class's default one.
  cmd = @selector(mouseDownCanMoveWindow);
  super_impl = reinterpret_cast<BOOL (*)(NSView*, SEL)>(
      [[view superclass] instanceMethodForSelector:cmd]);
  priv->draggable = super_impl(view, cmd);
}

void View::SetBounds(const RectF& bounds) {
  NSRect frame = bounds.ToCGRect();
  [view_ setFrame:frame];
  // Calling setFrame manually does not trigger resizeSubviewsWithOldSize.
  [view_ resizeSubviewsWithOldSize:frame.size];
}

Vector2dF View::OffsetFromView(const View* from) const {
  NSPoint point = [view_ convertPoint:NSZeroPoint toView:from->view_];
  return Vector2dF(point.x, point.y);
}

Vector2dF View::OffsetFromWindow() const {
  NSWindow* window = [view_ window];
  if (!window)
    return Vector2dF();
  NSPoint point = [view_ convertPoint:NSZeroPoint toView:nil];
  if ([view_ isFlipped])
    return Vector2dF(point.x, NSHeight([window frame]) - point.y);
  NSRect frame = [window contentRectForFrameRect:[window frame]];
  return Vector2dF(point.x + NSWidth([window frame]) - NSWidth(frame),
                   point.y + NSHeight([window frame]) - NSHeight(frame));
}

RectF View::GetBounds() const {
  return RectF([view_ frame]);
}

RectF View::GetBoundsInScreen() const {
  NSWindow* window = [view_ window];
  if (!window)
    return GetBounds();
  NSRect bounds = [view_ convertRect:[view_ bounds] toView:nil];
  return ScreenRectFromNSRect([window convertRectToScreen:bounds]);
}

void View::SetPixelBounds(const Rect& bounds) {
  SetBounds(RectF(bounds));
}

Rect View::GetPixelBounds() const {
  return ToNearestRect(GetBounds());
}

void View::SchedulePaint() {
  [view_ setNeedsDisplay:YES];
}

void View::SchedulePaintRect(const RectF& rect) {
  [view_ setNeedsDisplayInRect:rect.ToCGRect()];
}

void View::PlatformSetVisible(bool visible) {
  [view_ setHidden:!visible];
}

bool View::IsVisible() const {
  return ![view_ isHidden];
}

bool View::IsVisibleInHierarchy() const {
  return ![view_ isHiddenOrHasHiddenAncestor];
}

void View::SetEnabled(bool enable) {
  [view_ setNUEnabled:enable];
}

bool View::IsEnabled() const {
  return [view_ isNUEnabled];
}

void View::Focus() {
  if (view_.window && IsFocusable())
    [view_.window makeFirstResponder:view_];
}

bool View::HasFocus() const {
  if (view_.window)
    return view_.window.firstResponder == view_;
  else
    return false;
}

void View::SetFocusable(bool focusable) {
  NUViewPrivate* priv = [view_ nuPrivate];
  priv->focusable = focusable;
}

bool View::IsFocusable() const {
  return [view_ acceptsFirstResponder];
}

void View::SetMouseDownCanMoveWindow(bool yes) {
  NUViewPrivate* priv = [view_ nuPrivate];
  priv->draggable = yes;

  // AppKit will not update its cache of mouseDownCanMoveWindow unless something
  // changes.
  [[view_ window] setMovableByWindowBackground:NO];
  [[view_ window] setMovableByWindowBackground:YES];
}

bool View::IsMouseDownCanMoveWindow() const {
  return [view_ mouseDownCanMoveWindow];
}

int View::DoDragWithOptions(std::vector<Clipboard::Data> data,
                            int operations,
                            const DragOptions& options) {
  // Cocoa throws exception without data in drag session.
  if (data.empty())
    return DRAG_OPERATION_NONE;

  NUViewPrivate* priv = [view_ nuPrivate];
  priv->supported_drag_operation = operations;
  priv->data_source.reset([[DataProvider alloc] initWithData:std::move(data)]);

  // Release capture before beginning the dragging session. Capture may have
  // been acquired on the mouseDown, but capture is not required during the
  // dragging session and the mouseUp that would release it will be suppressed.
  ReleaseCapture();

  // Synthesize an event for dragging, since we can't be sure that
  // [NSApp currentEvent] will return a valid dragging event.
  NSWindow* window = [view_ window];
  NSPoint position = [window mouseLocationOutsideOfEventStream];
  NSTimeInterval event_time = [[NSApp currentEvent] timestamp];
  NSEvent* event = [NSEvent mouseEventWithType:NSEventTypeLeftMouseDragged
                                      location:position
                                 modifierFlags:NSEventMaskLeftMouseDragged
                                     timestamp:event_time
                                  windowNumber:[window windowNumber]
                                       context:nil
                                   eventNumber:0
                                    clickCount:1
                                      pressure:1.0];

  // The drag pasteboard only accepts UTI type strings.
  NSArray* types = [[priv->data_source.get() pasteboard] types];
  NSMutableArray* newTypes = [NSMutableArray array];
  for (NSString* type in types)
    [newTypes addObject:UTIFromPboardType(type)];

  base::apple::scoped_nsobject<NSPasteboardItem> item([[NSPasteboardItem alloc] init]);
  [item.get() setDataProvider:priv->data_source.get()
                     forTypes:newTypes];

  base::apple::scoped_nsobject<NSDraggingItem> drag_item(
      [[NSDraggingItem alloc] initWithPasteboardWriter:item.get()]);

  // Set drag image.
  if (options.image) {
    NSImage* image = options.image->GetNative();
    NSRect dragging_frame = NSMakeRect([event locationInWindow].x, 0,
                                       [image size].width, [image size].height);
    [drag_item.get() setDraggingFrame:dragging_frame contents:image];
  } else {
    [drag_item.get() setDraggingFrame:NSMakeRect(0, 0, 100, 100) contents:nil];
  }

  [view_ beginDraggingSessionWithItems:@[drag_item.get()]
                                 event:event
                                source:(id<NSDraggingSource>)view_];

  // Since Drag and drop is asynchronous on Mac, we need to spin a nested run
  // loop for consistency with other platforms.
  NestedRunLoop run_loop;
  priv->quit_dragging = [&run_loop, &priv]() {
    run_loop.Quit();
    priv->quit_dragging = nullptr;
  };
  run_loop.Run();
  return priv->drag_result;
}

void View::CancelDrag() {
  NUViewPrivate* priv = [view_ nuPrivate];
  if (priv->quit_dragging)
    priv->quit_dragging();
}

bool View::IsDragging() const {
  return !![view_ nuPrivate]->quit_dragging;
}

void View::RegisterDraggedTypes(std::set<Clipboard::Data::Type> types) {
  NSMutableArray* newTypes = [NSMutableArray array];
  for (auto type : types) {
    switch (type) {
      case Clipboard::Data::Type::Text:
        [newTypes addObject:NSPasteboardTypeString];
        break;
      case Clipboard::Data::Type::HTML:
        [newTypes addObject:NSPasteboardTypeHTML];
        [newTypes addObject:NSPasteboardTypeRTF];
        break;
      case Clipboard::Data::Type::Image:
        [newTypes addObject:NSPasteboardTypeTIFF];
        break;
      case Clipboard::Data::Type::FilePaths:
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        [newTypes addObject:NSFilenamesPboardType];
#pragma clang diagnostic pop
        break;
      default:
        break;
    }
  }
  [view_ registerForDraggedTypes:newTypes];
  AddDragDropHandler(view_);
}

void View::PlatformSetCursor(Cursor* cursor) {
  if (IsNUResponder(view_)) {
    if (cursor)
      [view_ nuPrivate]->cursor.reset([cursor->GetNative() retain]);
    else
      [view_ nuPrivate]->cursor.reset();
  }
}

void View::PlatformSetTooltip(const std::string& tooltip) {
  [view_ setToolTip:base::SysUTF8ToNSString(tooltip)];
}

int View::PlatformAddTooltipForRect(const std::string& tooltip, RectF rect) {
  base::apple::scoped_nsobject<NSString> str(
      [base::SysUTF8ToNSString(tooltip) retain]);
  int tag = [view_ addToolTipRect:rect.ToCGRect() owner:str.get() userData:nil];
  // The method only takes a weak ref of passed object.
  [view_ nuPrivate]->tooltips[tag] = std::move(str);
  return tag;
}

void View::PlatformRemoveTooltip(int tag) {
  [view_ removeToolTip:tag];
  [view_ nuPrivate]->tooltips.erase(tag);
}

void View::PlatformSetFont(Font* font) {
  if (IsNUResponder(view_))
    [view_ setNUFont:font];
}

void View::SetColor(Color color) {
  if (IsNUResponder(view_))
    [view_ setNUColor:color];
}

void View::SetBackgroundColor(Color color) {
  if (IsNUResponder(view_))
    [view_ setNUBackgroundColor:color];
}

void View::SetWantsLayer(bool wants) {
  [view_ nuPrivate]->wants_layer = wants;
  [view_ setWantsLayer:wants];
}

bool View::WantsLayer() const {
  return [view_ wantsLayer];
}

Window* View::GetWindow() const {
  return Window::FromNative([view_ window]);
}

}  // namespace nu

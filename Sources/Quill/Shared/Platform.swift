// The few AppKit/UIKit types the shared code touches, under one name per platform.
#if os(macOS)
import AppKit
typealias PlatformFont = NSFont
typealias PlatformColor = NSColor
typealias TextEditActions = NSTextStorageEditActions
#else
import UIKit
typealias PlatformFont = UIFont
typealias PlatformColor = UIColor
typealias TextEditActions = NSTextStorage.EditActions
#endif

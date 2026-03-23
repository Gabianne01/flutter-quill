import 'dart:math' as math;

import 'package:flutter/services.dart' show ClipboardData, Clipboard;
import 'package:flutter/widgets.dart';
import 'package:meta/meta.dart';
import '../document/nodes/node.dart';
import '../../quill_delta.dart';
import '../common/structs/image_url.dart';
import '../common/structs/offset_value.dart';
import '../common/utils/embeds.dart';
import '../delta/delta_diff.dart';
import '../document/attribute.dart';
import '../document/document.dart';
import '../document/nodes/embeddable.dart';
import '../document/nodes/leaf.dart';
import '../document/nodes/block.dart';
import '../document/nodes/line.dart';
import '../document/structs/doc_change.dart';
import '../document/style.dart';
import '../editor/config/editor_config.dart';
import '../editor/raw_editor/raw_editor_state.dart';
import '../editor_toolbar_controller_shared/clipboard/clipboard_service_provider.dart';
import 'clipboard/quill_controller_paste.dart';
import 'clipboard/quill_controller_rich_paste.dart';
import 'quill_controller_config.dart';

typedef ReplaceTextCallback = bool Function(int index, int len, Object? data);
typedef DeleteCallback = void Function(int cursorPosition, bool forward);

class QuillController extends ChangeNotifier {
  QuillController({
    required Document document,
    required TextSelection selection,
    this.config = const QuillControllerConfig(),
    this.keepStyleOnNewLine = true,
    this.onReplaceText,
    this.onDelete,
    this.onSelectionCompleted,
    this.onSelectionChanged,
    this.readOnly = false,
  })  : _document = document,
        _selection = selection;

  factory QuillController.basic({
    QuillControllerConfig config = const QuillControllerConfig(),
  }) =>
      QuillController(
        config: config,
        document: Document(),
        selection: const TextSelection.collapsed(offset: 0),
      );

  final QuillControllerConfig config;

  /// Document managed by this controller.
  Document _document;

  Document get document => _document;

  // Store editor config to pass them to the document to
  // support search within embed objects https://github.com/singerdmx/flutter-quill/pull/2090.
  // For internal use only, should not be exposed as a public API.
  QuillEditorConfig? _editorConfig;

  @visibleForTesting
  @internal
  QuillEditorConfig? get editorConfig => _editorConfig;
  @internal
  set editorConfig(QuillEditorConfig? value) {
    _editorConfig = value;
    _setDocumentSearchProperties();
  }

  // Pass required editor config to the document
  // to support search within embed objects https://github.com/singerdmx/flutter-quill/pull/2090
  void _setDocumentSearchProperties() {
    _document
      ..searchConfig = _editorConfig?.searchConfig
      ..embedBuilders = _editorConfig?.embedBuilders
      ..unknownEmbedBuilder = _editorConfig?.unknownEmbedBuilder;
  }

  set document(Document doc) {
    _document = doc;
    _setDocumentSearchProperties();

    // Prevent the selection from
    _selection = const TextSelection(baseOffset: 0, extentOffset: 0);

    notifyListeners();
  }

  /// Tells whether to keep or reset the [toggledStyle]
  /// when user adds a new line.
  final bool keepStyleOnNewLine;

  /// Currently selected text within the [document].
  TextSelection get selection => _selection;
  TextSelection _selection;

  /// Custom [replaceText] handler
  /// Return false to ignore the event
  ReplaceTextCallback? onReplaceText;

  /// Custom delete handler
  DeleteCallback? onDelete;

  void Function()? onSelectionCompleted;
  void Function(TextSelection textSelection)? onSelectionChanged;

  /// Store any styles attribute that got toggled by the tap of a button
  /// and that has not been applied yet.
  /// It gets reset after each format action within the [document].
  Style toggledStyle = const Style();
  final Style _paragraphDefaults = Style.attr({
  Attribute.font.key: Attribute.fromKeyValue(Attribute.font.key, 'Bornia')!,
  Attribute.size.key: Attribute.fromKeyValue(Attribute.size.key, '18')!,
});

bool _caretOnEmptyParagraphAfterHeader = false;
Style _afterHeaderPendingStyle = const Style();
bool _isNormalizing = false;

  /// [raw_editor_actions] handling of backspace event may need to force the style displayed in the toolbar
  void forceToggledStyle(Style style) {
    toggledStyle = style;
    notifyListeners();
  }

  bool ignoreFocusOnTextChange = false;

  /// Skip the keyboard request in [QuillRawEditorState.requestKeyboard].
  ///
  /// See also: [QuillRawEditorState._didChangeTextEditingValue]
  bool skipRequestKeyboard = false;

  /// True when this [QuillController] instance has been disposed.
  ///
  /// A safety mechanism to ensure that listeners don't crash when adding,
  /// removing or listeners to this instance.
  bool _isDisposed = false;

  Stream<DocChange> get changes => document.changes;

  TextEditingValue get plainTextEditingValue => TextEditingValue(
        text: document.toPlainText(),
        selection: selection,
      );

  /// Only attributes applied to all characters within this range are
  /// included in the result.
 Style getSelectionStyle() {
  if (_caretOnEmptyParagraphAfterHeader) {
    return _paragraphDefaults.mergeAll(_afterHeaderPendingStyle);
  }

  return document
      .collectStyle(selection.start, selection.end - selection.start)
      .mergeAll(toggledStyle);
}

  // Increases or decreases the indent of the current selection by 1.
  void indentSelection(bool isIncrease) {
    if (selection.isCollapsed) {
      _indentSelectionFormat(isIncrease);
    } else {
      _indentSelectionEachLine(isIncrease);
    }
  }

  void _indentSelectionFormat(bool isIncrease) {
    final indent = getSelectionStyle().attributes[Attribute.indent.key];
    if (indent == null) {
      if (isIncrease) {
        formatSelection(Attribute.indentL1);
      }
      return;
    }
    if (indent.value == 1 && !isIncrease) {
      formatSelection(Attribute.clone(Attribute.indentL1, null));
      return;
    }
    if (isIncrease) {
      if (indent.value < 5) {
        formatSelection(Attribute.getIndentLevel(indent.value + 1));
      }
      return;
    }
    formatSelection(Attribute.getIndentLevel(indent.value - 1));
  }

  void _indentSelectionEachLine(bool isIncrease) {
    final styles = document.collectAllStylesWithOffset(
      selection.start,
      selection.end - selection.start,
    );
    for (final style in styles) {
      final indent = style.value.attributes[Attribute.indent.key];
      final formatIndex = math.max(style.offset, selection.start);
      final formatLength = math.min(
            style.offset + (style.length ?? 0),
            selection.end,
          ) -
          style.offset;
      Attribute? formatAttribute;
      if (indent == null) {
        if (isIncrease) {
          formatAttribute = Attribute.indentL1;
        }
      } else if (indent.value == 1 && !isIncrease) {
        formatAttribute = Attribute.clone(Attribute.indentL1, null);
      } else if (isIncrease) {
        if (indent.value < 5) {
          formatAttribute = Attribute.getIndentLevel(indent.value + 1);
        }
      } else {
        formatAttribute = Attribute.getIndentLevel(indent.value - 1);
      }
      if (formatAttribute != null) {
        document.format(formatIndex, formatLength, formatAttribute);
      }
    }
    notifyListeners();
  }

  /// Returns all styles and Embed for each node within selection
  List<OffsetValue> getAllIndividualSelectionStylesAndEmbed() {
    final stylesAndEmbed = document.collectAllIndividualStyleAndEmbed(
        selection.start, selection.end - selection.start);
    return stylesAndEmbed;
  }

  /// Returns plain text for each node within selection
  String getPlainText() {
    final text =
        document.getPlainText(selection.start, selection.end - selection.start);
    return text;
  }

  /// Returns all styles for any character within the specified text range.
  List<Style> getAllSelectionStyles() {
    final styles = document.collectAllStyles(
        selection.start, selection.end - selection.start)
      ..add(toggledStyle);
    return styles;
  }

  void undo() {
    final result = document.undo();
    if (result.changed) {
      _handleHistoryChange(result.len);
    }
  }

  void _handleHistoryChange(int len) {
    updateSelection(
      TextSelection.collapsed(
        offset: len,
      ),
      ChangeSource.local,
    );
  }

  void redo() {
    final result = document.redo();
    if (result.changed) {
      _handleHistoryChange(result.len);
    }
  }

  bool get hasUndo => document.hasUndo;

  bool get hasRedo => document.hasRedo;

  /// clear editor
  void clear() {
    replaceText(0, plainTextEditingValue.text.length - 1, '',
        const TextSelection.collapsed(offset: 0));
  }

Style _inlineOnly(Style style) {
   final attrs = <String, Attribute>{};

  final font = style.attributes[Attribute.font.key];
  final size = style.attributes[Attribute.size.key];

  if (font != null) attrs[Attribute.font.key] = font;
  if (size != null) attrs[Attribute.size.key] = size;

  return Style.attr(attrs);
}

Attribute? _headerAttrForLine(Line line) {
  final direct = line.style.attributes[Attribute.header.key];
  if (direct != null) return direct;

  final parent = line.parent;
  if (parent is Block) {
    return parent.style.attributes[Attribute.header.key];
  }

  return null;
}

void _normalizeLineToStyle(Line line, Style inlineStyle) {
  final start = line.documentOffset;
  final textLength = line.length - 1; // 🔴 exclude newline

  if (textLength <= 0) return;

  for (final attr in inlineStyle.values) {
    formatText(
      start,
      textLength,
      attr,
      shouldNotifyListeners: false,
    );
  }
}

  void _normalizeLinesBetween(int a, int b) {
  final start = math.min(a, b);
  final end   = math.max(a, b);

  int probe = math.max(0, math.min(start, document.length - 2));

  while (probe <= end && probe < document.length - 1) {
    final line = document.querySegmentLeafNode(probe).line;
    if (line == null) break;

    _normalizeIfMixed(line);

    probe = line.documentOffset + line.length;
  }
}

void _normalizeIfMixed(Line line) {
  if (line.length <= 1) return;

  final start = line.documentOffset;
  final end   = start + line.length - 1;

  Style base = _inlineOnly(document.collectStyle(start + 1, 0));

  // 🔧 Fallback if no inline style exists
  final hasFont = base.attributes.containsKey(Attribute.font.key);
final hasSize = base.attributes.containsKey(Attribute.size.key);

if (!hasFont || !hasSize) {
    final header =
    _headerAttrForLine(line)?.value as int?;

    double size;
    switch (header) {
      case 1:
        size = 36;
        break;
      case 2:
        size = 26;
        break;
      default:
        size = 18;
    }

    base = Style.attr({
      Attribute.font.key:
          Attribute.fromKeyValue(Attribute.font.key, 'Bornia')!,
      Attribute.size.key:
          Attribute.fromKeyValue(Attribute.size.key, size.toString())!,
    });
  }

  for (int i = start + 1; i < end; i++) {
    final s = _inlineOnly(document.collectStyle(i, 0));

    if (s != base) {
      _normalizeLineToStyle(line, base);
      return;
    }
  }
}

  void replaceText(
    int index,
    int len,
    Object? data,
    TextSelection? textSelection, {
    bool ignoreFocus = false,
    @experimental bool shouldNotifyListeners = true,
  }) {
    assert(data is String || data is Embeddable || data is Delta);
    final editStart = index;

    if (onReplaceText != null && !onReplaceText!(index, len, data)) {
      return;
    }

    Delta? delta;
   Style? style;
   final anchorLine =
    document.querySegmentLeafNode(index).line;

final anchorHeader =
    anchorLine != null ? _headerAttrForLine(anchorLine) : null;

final isEmptyLine =
    anchorLine?.isEmpty ?? false;

final anchorInline = isEmptyLine
    ? _inlineOnly(
        _caretOnEmptyParagraphAfterHeader
            ? _paragraphDefaults.mergeAll(_afterHeaderPendingStyle)
            : toggledStyle,
      )
    : _inlineOnly(document.collectStyle(index, 0));
   
if (len > 0 || data is! String || data.isNotEmpty) {
  delta = document.replace(index, len, data);

  final sourceStyle = _caretOnEmptyParagraphAfterHeader
    ? _paragraphDefaults.mergeAll(_afterHeaderPendingStyle)
    : toggledStyle;
    final isMultiline =
    data is String &&
    data.contains('\n') &&
    data.length > 1;

if (isMultiline) {
  final firstLine =
      document.querySegmentLeafNode(index).line;

  final endOffset =
      index + (data is String ? data.length : 1);

  Line? line = firstLine;

  while (line != null &&
         line.documentOffset <= endOffset) {

    // 🔴 Remove ANY existing header (including the one Quill moved)
    final existingHeader = _headerAttrForLine(line);

    if (existingHeader != null) {
      formatText(
        line.documentOffset,
        0,
        Attribute.clone(existingHeader, null),
        shouldNotifyListeners: false,
      );
    }

    // ✅ Apply header ONLY to first line
    if (line == firstLine && anchorHeader != null) {
      formatText(
        line.documentOffset,
        0,
        anchorHeader,
        shouldNotifyListeners: false,
      );
    }

   final isFirst = line == firstLine;

if (isFirst) {
  // keep header styling
  _normalizeLineToStyle(line, anchorInline);
} else {
  // force paragraph defaults
  _normalizeLineToStyle(line, _paragraphDefaults);
}

    final nextOffset = line.documentOffset + line.length;
    if (nextOffset >= document.length) break;

    line = document.querySegmentLeafNode(nextOffset).line;
  }
}

  style = Style.attr(Map<String, Attribute>.fromEntries(
    sourceStyle.attributes.entries.where(
      (a) => a.value.scope != AttributeScope.block,
    ),
  ));

      var shouldRetainDelta = style.isNotEmpty &&
          delta.isNotEmpty &&
          delta.length <= 2 &&
          delta.last.isInsert;
      if (data is String && data.contains('\n') && data.length > 1) {
  shouldRetainDelta = false;
}    
      if (shouldRetainDelta &&
          style.isNotEmpty &&
          delta.length == 2 &&
          delta.last.data == '\n') {
        // if all attributes are inline, shouldRetainDelta should be false
        final anyAttributeNotInline =
            style.values.any((attr) => !attr.isInline);
        if (!anyAttributeNotInline) {
          shouldRetainDelta = false;
        }
      }
      if (shouldRetainDelta) {
        final retainDelta = Delta()
          ..retain(index)
          ..retain(data is String ? data.length : 1, style.toJson());
        document.compose(retainDelta, ChangeSource.local);
      }
      // 👇 ADD THIS
  if (_caretOnEmptyParagraphAfterHeader &&
      data is String &&
      data.isNotEmpty &&
      !data.contains('\n')) {
    _afterHeaderPendingStyle = const Style();
  }
    }

    if (textSelection != null) {
      if (delta == null || delta.isEmpty) {
        _updateSelection(textSelection);
      } else {
        final user = Delta()
          ..retain(index)
          ..insert(data)
          ..delete(len);
        final positionDelta = getPositionDelta(user, delta);
       _updateSelection(
  textSelection.copyWith(
    baseOffset: textSelection.baseOffset + positionDelta,
    extentOffset: textSelection.extentOffset + positionDelta,
  ),
  insertNewline: data == '\n',
);
      }
    }

    if (ignoreFocus) {
      ignoreFocusOnTextChange = true;
    }
int insertedLength = 1;

if (data is String) {
  insertedLength = data.length;
} else if (data is Embeddable) {
  insertedLength = 1;
}

final editEnd = index + math.max(len, insertedLength);

final int normalizeStart =
    editStart > 0 ? editStart - 1 : 0;

final int normalizeEnd =
    ((editEnd + 1).toInt() < document.length)
        ? (editEnd + 1).toInt()
        : document.length - 1;

final isMultiline =
    data is String &&
    data.contains('\n') &&
    data.length > 1;

if (!_isNormalizing && !isMultiline) {
  _isNormalizing = true;
  _normalizeLinesBetween(normalizeStart, normalizeEnd);
  _isNormalizing = false;
}

if (shouldNotifyListeners) {
  notifyListeners();
}
    ignoreFocusOnTextChange = false;
 
 final isDelete = data is String && data.isEmpty && len > 0;

if (isDelete) {
  WidgetsBinding.instance.addPostFrameCallback((_) {
    if (_isDisposed) return;

    final sel = selection;

    updateSelection(
      TextSelection.collapsed(offset: sel.baseOffset),
      ChangeSource.local,
    );
  });
}
  }

  /// Called in two cases:
  /// forward == false && textBefore.isEmpty
  /// forward == true && textAfter.isEmpty
  /// Android only
  /// see https://github.com/singerdmx/flutter-quill/discussions/514
  void handleDelete(int cursorPosition, bool forward) =>
      onDelete?.call(cursorPosition, forward);

  void formatTextStyle(int index, int len, Style style) {
    style.attributes.forEach((key, attr) {
      formatText(index, len, attr);
    });
  }

  void formatText(
  int index,
  int len,
  Attribute? attribute, {
  @experimental bool shouldNotifyListeners = true,
}) {
  if (len == 0 && attribute != null && attribute.key != Attribute.link.key) {
    if (_caretOnEmptyParagraphAfterHeader && attribute.isInline) {
      _afterHeaderPendingStyle = _afterHeaderPendingStyle.put(attribute);
      if (shouldNotifyListeners) {
        notifyListeners();
      }
      return;
    }

    toggledStyle = toggledStyle.put(attribute);
  }

  final change = document.format(index, len, attribute);

  final adjustedSelection = selection.copyWith(
    baseOffset: change.transformPosition(selection.baseOffset),
    extentOffset: change.transformPosition(selection.extentOffset),
  );

  if (selection != adjustedSelection) {
    _updateSelection(adjustedSelection);
  }

  if (shouldNotifyListeners) {
    notifyListeners();
  }
}

  void formatSelection(Attribute? attribute,
      {@experimental bool shouldNotifyListeners = true}) {
    formatText(
      selection.start,
      selection.end - selection.start,
      attribute,
      shouldNotifyListeners: shouldNotifyListeners,
    );
  }

  void moveCursorToStart() {
    updateSelection(
      const TextSelection.collapsed(offset: 0),
      ChangeSource.local,
    );
  }

  void moveCursorToPosition(int position) {
    updateSelection(
      TextSelection.collapsed(offset: position),
      ChangeSource.local,
    );
  }

  void moveCursorToEnd() {
    updateSelection(
      TextSelection.collapsed(offset: plainTextEditingValue.text.length),
      ChangeSource.local,
    );
  }

  void updateSelection(TextSelection textSelection, ChangeSource source) {
    _updateSelection(textSelection);
    notifyListeners();
  }

  void compose(Delta delta, TextSelection textSelection, ChangeSource source) {
    if (delta.isNotEmpty) {
      document.compose(delta, source);
    }

    textSelection = selection.copyWith(
      baseOffset: delta.transformPosition(selection.baseOffset, force: false),
      extentOffset: delta.transformPosition(
        selection.extentOffset,
        force: false,
      ),
    );
    if (selection != textSelection) {
      _updateSelection(textSelection);
    }

    notifyListeners();
  }

  @override
  void addListener(VoidCallback listener) {
    // By using `_isDisposed`, make sure that `addListener` won't be called on a
    // disposed `ChangeListener`
    if (!_isDisposed) {
      super.addListener(listener);
    }
  }

  @override
  void removeListener(VoidCallback listener) {
    // By using `_isDisposed`, make sure that `removeListener` won't be called
    // on a disposed `ChangeListener`
    if (!_isDisposed) {
      super.removeListener(listener);
    }
  }

  @override
  void dispose() {
    if (!_isDisposed) {
      document.close();
    }

    _isDisposed = true;
    super.dispose();
  }

  void _updateSelection(TextSelection textSelection, {bool insertNewline = false}) {
  _selection = textSelection;
  final end = document.length - 1;
  _selection = selection.copyWith(
    baseOffset: math.min(selection.baseOffset, end),
    extentOffset: math.min(selection.extentOffset, end),
  );

  bool emptyParagraphAfterHeader = false;

  final segment = document.querySegmentLeafNode(selection.start);
  final line = segment.line;

  if (line != null && line.isEmpty) {

Node? probe = line.previous;

/// Walk upward until we hit a non-empty Line
while (probe != null) {
  if (probe is Line) {
    if (!probe.isEmpty) {
      break; // found meaningful line
    }
  }

  probe = probe.previous;
}

if (probe is Line) {
  final prevIsHeader =
      probe.style.attributes.containsKey(Attribute.header.key) ||
      (probe.parent is Block &&
          (probe.parent as Block)
              .style
              .attributes
              .containsKey(Attribute.header.key));

  emptyParagraphAfterHeader = prevIsHeader;
}
  }

if (!emptyParagraphAfterHeader) {
  _afterHeaderPendingStyle = const Style();
}

  _caretOnEmptyParagraphAfterHeader = emptyParagraphAfterHeader;

 if (emptyParagraphAfterHeader) {
  final prevStyle = document.collectStyle(
      selection.start > 0 ? selection.start - 1 : 0,
      0,
    );

    Style preserved = const Style();

    final allowedKeys = {
      Attribute.bold.key,
      Attribute.italic.key,
      Attribute.underline.key,
      Attribute.strikeThrough.key,
      Attribute.color.key,
      Attribute.background.key,
    };

    for (final attr in prevStyle.attributes.values) {
      if (allowedKeys.contains(attr.key)) {
        preserved = preserved.put(attr);
      }
    }

    _afterHeaderPendingStyle = preserved;
  

  // Keep typing state clean; getSelectionStyle() will merge
  // paragraph defaults + _afterHeaderPendingStyle.
  toggledStyle = const Style();

  onSelectionChanged?.call(textSelection);
  return;
}

  if (keepStyleOnNewLine) {
  if (insertNewline) {
    final segment = document.querySegmentLeafNode(selection.start);
    final currentLine = segment.line;

    Style style = const Style();

    final atStartOfNonEmptyLine =
        selection.isCollapsed &&
        currentLine != null &&
        selection.start == currentLine.documentOffset &&
        !currentLine.isEmpty;

    if (atStartOfNonEmptyLine) {
      // Special case:
      // Enter pressed at the start of a styled line, or split produced a
      // non-empty right-side line and the caret is now at its beginning.
      //
      // In this case, sample style from the current line, not the left side.
      final probeOffset = math.min(
        selection.start,
        document.length - 2,
      );

      style = document.collectStyle(probeOffset, 0);
    } else if (selection.start > 0) {
      // Normal Enter behavior:
      // inherit from the character/line immediately before the caret.
      style = document.collectStyle(selection.start - 1, 0);
    }

    final ignoredStyles = style.attributes.values.where(
      (s) => !s.isInline || s.key == Attribute.link.key,
    );

    toggledStyle = style.removeAll(ignoredStyles.toSet());
  } else {
    toggledStyle = const Style();
  }
} else {
  toggledStyle = const Style();
}

  onSelectionChanged?.call(textSelection);
}

  /// Given offset, find its leaf node in document
  Leaf? queryNode(int offset) {
    return document.querySegmentLeafNode(offset).leaf;
  }

  // Notify toolbar buttons directly with attributes
  Map<String, Attribute> toolbarButtonToggler = const {};

  /// Clipboard caches last copy to allow paste with styles. Static to allow paste between multiple instances of editor.
  static String _pastePlainText = '';
  static Delta _pasteDelta = Delta();
  static List<OffsetValue> _pasteStyleAndEmbed = <OffsetValue>[];

  String get pastePlainText => _pastePlainText;
  Delta get pasteDelta => _pasteDelta;
  List<OffsetValue> get pasteStyleAndEmbed => _pasteStyleAndEmbed;

  /// Whether the text can be changed.
  ///
  /// When this is set to `true`, the text cannot be modified
  /// by any shortcut or keyboard operation. The text is still selectable.
  ///
  /// Defaults to `false`.
  bool readOnly;

  ImageUrl? _copiedImageUrl;
  ImageUrl? get copiedImageUrl => _copiedImageUrl;

  set copiedImageUrl(ImageUrl? value) {
    _copiedImageUrl = value;
    Clipboard.setData(const ClipboardData(text: ''));
  }

  @experimental
  bool clipboardSelection(bool copy) {
    copiedImageUrl = null;

    /// Get the text for the selected region and expand the content of Embedded objects.
    _pastePlainText = document.getPlainText(
      selection.start,
      selection.end - selection.start,
      includeEmbeds: true,
    );

    /// Get the internal representation so it can be pasted into a QuillEditor with style retained.
    _pasteStyleAndEmbed = getAllIndividualSelectionStylesAndEmbed();

    /// Get the deltas for the selection so they can be pasted into a QuillEditor with styles and embeds retained.
    _pasteDelta = document.toDelta().slice(selection.start, selection.end);

    if (!selection.isCollapsed) {
      Clipboard.setData(ClipboardData(text: _pastePlainText));
      if (!copy) {
        if (readOnly) return false;
        final sel = selection;
        replaceText(sel.start, sel.end - sel.start, '',
            TextSelection.collapsed(offset: sel.start));
      }
      return true;
    }
    return false;
  }

  /// Returns whether paste operation was handled here.
  /// [updateEditor] is called if paste operation was successful.
  @experimental
  Future<bool> clipboardPaste({void Function()? updateEditor}) async {
    if (readOnly || !selection.isValid) return true;

    final clipboardConfig = config.clipboardConfig;

    if (await clipboardConfig?.onClipboardPaste?.call() == true) {
      updateEditor?.call();
      return true;
    }

    final pasteInternalImageSuccess = await _pasteInternalImage();
    if (pasteInternalImageSuccess) {
      updateEditor?.call();
      return true;
    }

    const enableExternalRichPasteDefault = true;
    if (clipboardConfig?.enableExternalRichPaste ??
        enableExternalRichPasteDefault) {
      final pasteHtmlSuccess = await pasteHTML();
      if (pasteHtmlSuccess) {
        updateEditor?.call();
        return true;
      }

      final pasteMarkdownSuccess = await pasteMarkdown();
      if (pasteMarkdownSuccess) {
        updateEditor?.call();
        return true;
      }
    }

    final clipboardService = ClipboardServiceProvider.instance;

    final onImagePaste = clipboardConfig?.onImagePaste;
    if (onImagePaste != null) {
      final imageBytes = await clipboardService.getImageFile();

      if (imageBytes != null) {
        final imageUrl = await onImagePaste(imageBytes);
        if (imageUrl != null) {
          replaceText(
            plainTextEditingValue.selection.end,
            0,
            BlockEmbed.image(imageUrl),
            null,
          );
          updateEditor?.call();
          return true;
        }
      }
    }

    final onGifPaste = clipboardConfig?.onGifPaste;
    if (onGifPaste != null) {
      final gifBytes = await clipboardService.getGifFile();
      if (gifBytes != null) {
        final gifUrl = await onGifPaste(gifBytes);
        if (gifUrl != null) {
          replaceText(
            plainTextEditingValue.selection.end,
            0,
            BlockEmbed.image(gifUrl),
            null,
          );
          updateEditor?.call();
          return true;
        }
      }
    }

    // Only process plain text if no image/gif was pasted.
    // Snapshot the input before using `await`.
    // See https://github.com/flutter/flutter/issues/11427
    final plainText = (await Clipboard.getData(Clipboard.kTextPlain))?.text;
final isCollapsed = selection.isCollapsed;

final currentLine =
    document.querySegmentLeafNode(selection.start).line;

final isEmptyLine =
    currentLine?.isEmpty ?? false;

final allowRichPaste = isCollapsed && isEmptyLine;
    if (plainText != null) {
  final plainTextToPaste = await getTextToPaste(plainText);

  if (allowRichPaste) {
    // ✅ keep current behavior (rich paste)
    if (pastePlainTextOrDelta(
      plainTextToPaste,
      pastePlainText: _pastePlainText,
      pasteDelta: _pasteDelta,
    )) {
      updateEditor?.call();
      return true;
    }
  } else {
    // 🔴 FORCE your pipeline
    replaceText(
      selection.start,
      selection.end - selection.start,
      plainTextToPaste,
      TextSelection.collapsed(
        offset: selection.start + plainTextToPaste.length,
      ),
    );

    updateEditor?.call();
    return true;
  }
}

    final onUnprocessedPaste = clipboardConfig?.onUnprocessedPaste;
    if (onUnprocessedPaste != null) {
      if (await onUnprocessedPaste()) {
        updateEditor?.call();
        return true;
      }
    }

    return false;
  }

  /// Return `true` if can paste an internal image
  Future<bool> _pasteInternalImage() async {
    final copiedImageUrl = _copiedImageUrl;
    if (copiedImageUrl != null) {
      final index = selection.baseOffset;
      final length = selection.extentOffset - index;
      replaceText(
        index,
        length,
        BlockEmbed.image(copiedImageUrl.url),
        null,
      );
      if (copiedImageUrl.styleString.isNotEmpty) {
        formatText(
          getEmbedNode(this, index + 1).offset,
          1,
          StyleAttribute(copiedImageUrl.styleString),
        );
      }
      _copiedImageUrl = null;
      await Clipboard.setData(
        const ClipboardData(text: ''),
      );
      return true;
    }
    return false;
  }

  void replaceTextWithEmbeds(
    int index,
    int len,
    String insertedText,
    TextSelection? textSelection, {
    bool ignoreFocus = false,
    @experimental bool shouldNotifyListeners = true,
  }) {
    final containsEmbed =
        insertedText.codeUnits.contains(Embed.kObjectReplacementInt);
    insertedText =
        containsEmbed ? _adjustInsertedText(insertedText) : insertedText;

    replaceText(index, len, insertedText, textSelection,
        ignoreFocus: ignoreFocus, shouldNotifyListeners: shouldNotifyListeners);

    _applyPasteStyleAndEmbed(insertedText, index, containsEmbed);
  }

  void _applyPasteStyleAndEmbed(
      String insertedText, int start, bool containsEmbed) {
    if (insertedText == pastePlainText && pastePlainText != '' ||
        containsEmbed) {
      final pos = start;
      for (final p in pasteStyleAndEmbed) {
        final offset = p.offset;
        final styleAndEmbed = p.value;

        final local = pos + offset;
        if (styleAndEmbed is Embeddable) {
          replaceText(local, 0, styleAndEmbed, null);
        } else {
          final style = styleAndEmbed as Style;
          if (style.isInline) {
            formatTextStyle(local, p.length!, style);
          } else if (style.isBlock) {
            final node = document.queryChild(local).node;
            if (node != null && p.length == node.length - 1) {
              for (final attribute in style.values) {
                document.format(local, 0, attribute);
              }
            }
          }
        }
      }
    }
  }

  String _adjustInsertedText(String text) {
    final sb = StringBuffer();
    for (var i = 0; i < text.length; i++) {
      if (text.codeUnitAt(i) == Embed.kObjectReplacementInt) {
        continue;
      }
      sb.write(text[i]);
    }
    return sb.toString();
  }
}
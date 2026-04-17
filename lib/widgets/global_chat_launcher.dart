import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'dart:typed_data';
import 'package:file_picker/file_picker.dart';
import '../services/ai_service.dart';

class GlobalChatLauncher extends StatelessWidget {
  final BuildContext navigatorContext;

  const GlobalChatLauncher({super.key, required this.navigatorContext});

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      ignoring: false,
      child: SafeArea(
        child: Align(
          alignment: Alignment.bottomRight,
          child: Padding
              (padding: const EdgeInsets.only(right: 16, bottom: 16),
            child: GestureDetector(
              onTap: () {
                showModalBottomSheet(
                  context: navigatorContext,
                  isScrollControlled: true,
                  backgroundColor: Colors.transparent,
                  builder: (_) => const _GlobalChatSheet(),
                );
              },
              child: Container(
                width: 52,
                height: 52,
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.primary,
                  shape: BoxShape.circle,
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withOpacity(0.18),
                      blurRadius: 10,
                      offset: const Offset(0, 4),
                    ),
                  ],
                ),
                child: const Icon(Icons.chat_bubble_outline, color: Colors.white),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _GlobalChatSheet extends StatefulWidget {
  const _GlobalChatSheet();

  @override
  State<_GlobalChatSheet> createState() => _GlobalChatSheetState();
}

class _GlobalChatSheetState extends State<_GlobalChatSheet> {
  final TextEditingController _controller = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  final List<_ChatMessage> _messages = [];
  bool _sending = false;
  List<_ChatAttachment> _pendingAttachments = [];
  late AIService _ai;

  @override
  void initState() {
    super.initState();
    _ai = AIService.fromEnv();
    _messages.add(
      const _ChatMessage(
        role: 'assistant',
        content:
            "Hi! I'm your LearnEase assistant. Ask any question about your courses or concepts.",
      ),
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _pickAttachment({required bool imageOnly}) async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: imageOnly ? FileType.image : FileType.any,
        allowMultiple: false,
        withData: true,
      );
      if (result == null || result.files.isEmpty) return;

      final file = result.files.first;
      setState(() {
        _pendingAttachments = [
          ..._pendingAttachments,
          _ChatAttachment(
            name: file.name,
            path: file.path,
            kind: imageOnly ? 'image' : 'file',
            bytes: file.bytes,
          ),
        ];
      });
    } catch (_) {
      // ignore picker errors for now
    }
  }

  Future<void> _send() async {
    final text = _controller.text.trim();
    if ((text.isEmpty && _pendingAttachments.isEmpty) || _sending) return;

    final attachmentsToSend = List<_ChatAttachment>.from(_pendingAttachments);

    setState(() {
      _sending = true;
      _messages.add(
        _ChatMessage(
          role: 'user',
          content: text.isEmpty ? '(Sent attachments)' : text,
          attachments: attachmentsToSend,
        ),
      );
      _controller.clear();
      _pendingAttachments = [];
    });

    try {
      _ai = AIService.fromEnv();

      final transcript = _messages
          .take(12)
          .map((m) {
            final speaker = m.role == 'user' ? 'Student' : 'Assistant';
            var line = '$speaker: ${m.content}';
            if (m.attachments.isNotEmpty) {
              final attList = m.attachments
                  .map((a) => '${a.kind}:${a.name}')
                  .join(', ');
              line += ' [Attachments: $attList]';
            }
            return line;
          })
          .join('\n');

      final prompt = [
        'You are a helpful tutor for the LearnEase app. Answer clearly and concisely.',
        'Conversation so far:',
        transcript,
        '',
        'Now answer the student\'s last message.',
      ].join('\n');

      final reply = await _ai.sendMessage(prompt);
      if (!mounted) return;
      setState(() {
        _messages.add(_ChatMessage(role: 'assistant', content: reply));
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _messages.add(_ChatMessage(
          role: 'assistant',
          content:
              'Sorry, I had trouble reaching the AI just now. Please try again in a moment.',
        ));
      });
    } finally {
      if (!mounted) return;
      setState(() {
        _sending = false;
      });
      await Future<void>.delayed(const Duration(milliseconds: 40));
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeOut,
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final colorScheme = theme.colorScheme;

    return DraggableScrollableSheet(
      initialChildSize: 0.35,
      minChildSize: 0.25,
      maxChildSize: 0.8,
      builder: (context, scrollableController) {
        return Container(
          decoration: BoxDecoration(
            color: isDark ? const Color(0xFF111827) : Colors.white,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(0.18),
                blurRadius: 20,
                offset: const Offset(0, -4),
              ),
            ],
          ),
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
          child: Column(
            children: [
              Container(
                width: 40,
                height: 4,
                margin: const EdgeInsets.only(bottom: 12),
                decoration: BoxDecoration(
                  color: isDark ? Colors.white24 : Colors.grey.shade300,
                  borderRadius: BorderRadius.circular(999),
                ),
              ),
              Row(
                children: [
                  Icon(Icons.chat_bubble_outline, color: colorScheme.primary),
                  const SizedBox(width: 8),
                  const Expanded(
                    child: Text(
                      'Ask LearnEase',
                      style: TextStyle(fontWeight: FontWeight.w600, fontSize: 16),
                    ),
                  ),
                  if (_sending)
                    SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        valueColor: AlwaysStoppedAnimation<Color>(colorScheme.primary),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 8),

              if (_pendingAttachments.isNotEmpty) ...[
                Wrap(
                  spacing: 6,
                  runSpacing: 4,
                  children: _pendingAttachments
                      .map(
                        (a) => Container(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                          decoration: BoxDecoration(
                            color: isDark ? Colors.white10 : const Color(0xFFE5E7EB),
                            borderRadius: BorderRadius.circular(999),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              if (a.kind == 'image' && a.bytes != null) ...[
                                ClipRRect(
                                  borderRadius: BorderRadius.circular(6),
                                  child: Image.memory(
                                    a.bytes!,
                                    width: 28,
                                    height: 28,
                                    fit: BoxFit.cover,
                                  ),
                                ),
                                const SizedBox(width: 6),
                              ] else ...[
                                Icon(
                                  a.kind == 'image'
                                      ? Icons.image_outlined
                                      : Icons.insert_drive_file_outlined,
                                  size: 14,
                                  color: isDark ? Colors.white70 : const Color(0xFF4B5563),
                                ),
                                const SizedBox(width: 4),
                              ],
                              Flexible(
                                child: Text(
                                  a.name,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: 11,
                                    color: isDark ? Colors.white70 : const Color(0xFF4B5563),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      )
                      .toList(),
                ),
                const SizedBox(height: 8),
              ],
              Expanded(
                child: ListView.builder(
                  controller: _scrollController,
                  itemCount: _messages.length,
                  itemBuilder: (context, index) {
                    final m = _messages[index];
                    final isUser = m.role == 'user';
                    final bubbleColor = isUser
                        ? colorScheme.primary.withOpacity(isDark ? 0.45 : 0.12)
                        : (isDark ? Colors.white12 : const Color(0xFFF3F4F6));
                    final textColor = isDark ? Colors.white : const Color(0xFF111827);

                    return Align(
                      alignment:
                          isUser ? Alignment.centerRight : Alignment.centerLeft,
                      child: Container(
                        margin: const EdgeInsets.only(bottom: 8),
                        padding: const EdgeInsets.symmetric(
                            horizontal: 12, vertical: 8),
                        constraints: const BoxConstraints(maxWidth: 480),
                        decoration: BoxDecoration(
                          color: bubbleColor,
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Column(
                          crossAxisAlignment:
                              isUser ? CrossAxisAlignment.end : CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (isUser)
                              Text(
                                m.content,
                                style: TextStyle(
                                  color: textColor,
                                  fontSize: 13.5,
                                  height: 1.4,
                                ),
                              )
                            else
                              MarkdownBody(
                                data: m.content,
                                styleSheet: MarkdownStyleSheet(
                                  p: TextStyle(
                                    fontSize: 13.5,
                                    height: 1.6,
                                    color: textColor,
                                  ),
                                  strong: TextStyle(
                                    fontWeight: FontWeight.w600,
                                    color: textColor,
                                  ),
                                  listBullet: TextStyle(
                                    fontSize: 16,
                                    color: textColor,
                                  ),
                                ),
                              ),
                            if (m.attachments.isNotEmpty) ...[
                              const SizedBox(height: 6),
                              Wrap(
                                spacing: 4,
                                runSpacing: 2,
                                children: m.attachments
                                    .map(
                                      (a) => Container(
                                        padding: const EdgeInsets.symmetric(
                                            horizontal: 6, vertical: 4),
                                        decoration: BoxDecoration(
                                          color: isUser
                                              ? Colors.black.withOpacity(0.04)
                                              : Colors.black.withOpacity(0.03),
                                          borderRadius: BorderRadius.circular(8),
                                        ),
                                        child: Row(
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            if (a.kind == 'image' && a.bytes != null) ...[
                                              ClipRRect(
                                                borderRadius: BorderRadius.circular(6),
                                                child: Image.memory(
                                                  a.bytes!,
                                                  width: 32,
                                                  height: 32,
                                                  fit: BoxFit.cover,
                                                ),
                                              ),
                                              const SizedBox(width: 6),
                                            ] else ...[
                                              Icon(
                                                a.kind == 'image'
                                                    ? Icons.image_outlined
                                                    : Icons.insert_drive_file_outlined,
                                                size: 16,
                                                color: textColor.withOpacity(0.85),
                                              ),
                                              const SizedBox(width: 4),
                                            ],
                                            Flexible(
                                              child: Text(
                                                a.name,
                                                overflow: TextOverflow.ellipsis,
                                                style: TextStyle(
                                                  fontSize: 11,
                                                  color: textColor.withOpacity(0.85),
                                                ),
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                    )
                                    .toList(),
                              ),
                            ],
                          ],
                        ),
                      ),
                    );
                  },
                ),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  IconButton(
                    icon: Icon(Icons.image_outlined,
                        color: isDark ? Colors.white70 : const Color(0xFF6B7280)),
                    tooltip: 'Attach image',
                    onPressed: _sending
                        ? null
                        : () => _pickAttachment(imageOnly: true),
                  ),
                  IconButton(
                    icon: Icon(Icons.attach_file,
                        color: isDark ? Colors.white70 : const Color(0xFF6B7280)),
                    tooltip: 'Attach file',
                    onPressed: _sending
                        ? null
                        : () => _pickAttachment(imageOnly: false),
                  ),
                  const SizedBox(width: 4),
                  Expanded(
                    child: TextField(
                      controller: _controller,
                      minLines: 1,
                      maxLines: 3,
                      textInputAction: TextInputAction.send,
                      onSubmitted: (_) => _send(),
                      decoration: InputDecoration(
                        hintText: 'Type your question…',
                        isDense: true,
                        filled: true,
                        fillColor:
                            isDark ? Colors.white10 : const Color(0xFFF9FAFB),
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 9,
                        ),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide: BorderSide(
                            color: isDark
                                ? Colors.white24
                                : Colors.grey.shade300,
                          ),
                        ),
                        enabledBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide: BorderSide(
                            color: isDark
                                ? Colors.white24
                                : Colors.grey.shade300,
                          ),
                        ),
                        focusedBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide: BorderSide(color: colorScheme.primary),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  SizedBox(
                    height: 40,
                    child: ElevatedButton(
                      onPressed: _sending ? null : _send,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: colorScheme.primary,
                        foregroundColor: Colors.white,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                        padding:
                            const EdgeInsets.symmetric(horizontal: 14),
                      ),
                      child: const Icon(Icons.send, size: 18),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                'AI answers may be inaccurate. Always cross-check important concepts.',
                style: TextStyle(
                  fontSize: 10.5,
                  color: isDark
                      ? Colors.white60
                      : const Color(0xFF6B7280),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _ChatMessage {
  final String role; // 'user' | 'assistant'
  final String content;
   final List<_ChatAttachment> attachments;

  const _ChatMessage({
    required this.role,
    required this.content,
    this.attachments = const [],
  });
}

class _ChatAttachment {
  final String name;
  final String? path;
  final String kind; // 'image' | 'file'
  final Uint8List? bytes;

  const _ChatAttachment({
    required this.name,
    required this.kind,
    this.path,
    this.bytes,
  });
}

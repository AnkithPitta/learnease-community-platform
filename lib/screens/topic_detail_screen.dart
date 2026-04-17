import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:flutter/foundation.dart';
import 'dart:typed_data';
import '../models/course.dart';
import 'quiz_screen.dart';
import '../utils/app_theme.dart';
import '../services/ai_service.dart';
import 'package:file_picker/file_picker.dart';

class TopicDetailScreen extends StatefulWidget {
  final Topic topic;

  const TopicDetailScreen({super.key, required this.topic});

  @override
  State<TopicDetailScreen> createState() => _TopicDetailScreenState();
}

class _TopicDetailScreenState extends State<TopicDetailScreen> with TickerProviderStateMixin {
  late ScrollController _scrollController;
  late AnimationController _fadeController;
  final List<Animation<double>> _cardAnimations = [];
  bool _showScrollToTop = false;
  double _scrollProgress = 0.0;

  final _chatController = TextEditingController();
  final _chatScrollController = ScrollController();
  final List<_ChatMessage> _messages = [];
  bool _sending = false;
  List<_ChatAttachment> _pendingAttachments = [];
  late AIService _ai;

  @override
  void initState() {
    super.initState();
    _scrollController = ScrollController();
    _scrollController.addListener(_onScroll);
    
    _fadeController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1500),
    );
    
    // Setup staggered animations for cards
    final sectionCount = 3 + (widget.topic.conceptSections?.length ?? 0) + 1;
    for (int i = 0; i < sectionCount; i++) {
      final start = i * 0.1;
      final end = start + 0.5;
      _cardAnimations.add(
        Tween<double>(begin: 0.0, end: 1.0).animate(
          CurvedAnimation(
            parent: _fadeController,
            curve: Interval(start.clamp(0.0, 1.0), end.clamp(0.0, 1.0), curve: Curves.easeOut),
          ),
        ),
      );
    }
    
    _fadeController.forward();

    _ai = AIService.fromEnv();
    _messages.add(
      _ChatMessage.assistant(
        "Hi! I'm your doubt-clarifying assistant for this lesson. Ask me anything from this topic.",
      ),
    );
  }

  @override
  void dispose() {
    _scrollController.dispose();
    _fadeController.dispose();
    _chatController.dispose();
    _chatScrollController.dispose();
    super.dispose();
  }

  String _lessonContextForAI() {
    final title = widget.topic.title.replaceFirst(RegExp(r'^\d+\.\s*'), '').trim();
    final explanation = widget.topic.explanation.trim();
    final keyPoints = widget.topic.revisionPoints.take(8).map((e) => '- $e').join('\n');
    return [
      'Lesson title: $title',
      if (explanation.isNotEmpty) 'Explanation:\n$explanation',
      if (keyPoints.isNotEmpty) 'Key points:\n$keyPoints',
    ].join('\n\n');
  }

  Future<void> _sendChat() async {
    final text = _chatController.text.trim();
    if ((text.isEmpty && _pendingAttachments.isEmpty) || _sending) return;

    final attachmentsToSend = List<_ChatAttachment>.from(_pendingAttachments);

    setState(() {
      _sending = true;
      _messages.add(
        _ChatMessage.user(
          text.isEmpty ? '(Sent attachments)' : text,
          attachments: attachmentsToSend,
        ),
      );
      _chatController.clear();
      _pendingAttachments = [];
    });

    try {
      // Re-create on each send so hot reloads can't keep a stale baseUrl
      // (e.g. old env override pointing to http://127.0.0.1:8080).
      _ai = AIService.fromEnv();

      final transcript = _messages
          .where((m) => m.role == 'user' || m.role == 'assistant')
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
        'You are a helpful doubt-clarifying tutor. Explain clearly and keep answers concise.',
        'If the question is unrelated to the lesson, ask one clarifying question.',
        '',
        _lessonContextForAI(),
        '',
        'Conversation so far:',
        transcript,
        '',
        'Now answer the student\'s last message.'
      ].join('\n');

      final assistant = await _ai.sendMessage(prompt);

      if (!mounted) return;
      setState(() {
        _messages.add(_ChatMessage.assistant(assistant));
      });
    } catch (e) {
      if (kDebugMode) {
        debugPrint('[LessonChat] AI error: $e');
      }
      if (!mounted) return;
      setState(() {
        _messages.add(
          _ChatMessage.assistant(
            kDebugMode
                ? 'AI error: $e'
                : 'Sorry — I had trouble reaching the AI right now. Please try again.',
          ),
        );
      });
    } finally {
      if (!mounted) return;
      setState(() {
        _sending = false;
      });
      await Future<void>.delayed(const Duration(milliseconds: 40));
      if (_chatScrollController.hasClients) {
        _chatScrollController.animateTo(
          _chatScrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeOut,
        );
      }
    }
  }

  void _onScroll() {
    final maxScroll = _scrollController.position.maxScrollExtent;
    final currentScroll = _scrollController.position.pixels;
    
    setState(() {
      _scrollProgress = maxScroll > 0 ? (currentScroll / maxScroll).clamp(0.0, 1.0) : 0.0;
      _showScrollToTop = currentScroll > 300;
    });
  }

  void _scrollToTop() {
    _scrollController.animateTo(
      0,
      duration: const Duration(milliseconds: 500),
      curve: Curves.easeInOut,
    );
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
    } catch (e) {
      if (kDebugMode) {
        debugPrint('[LessonChat] Attachment pick error: $e');
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    const primaryColor = Color(0xFF5C6BC0);
    const accentColor = Color(0xFF7E57C2);
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final colorScheme = Theme.of(context).colorScheme;
    final textColor = isDark ? Colors.white : Color(0xFF374151);
    final cardBgColor = isDark ? Color(0xFF2A2A3E) : Colors.white;
    final surfaceColor = isDark ? Color(0xFF1E1E2E) : Color(0xFFF9FAFB);
    
    return Scaffold(
      extendBodyBehindAppBar: false,
      appBar: PreferredSize(
        preferredSize: const Size.fromHeight(70),
        child: Container(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: [colorScheme.primary, colorScheme.secondary],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
            boxShadow: [
              BoxShadow(
                color: colorScheme.primary.withOpacity(0.3),
                blurRadius: 12,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: AppBar(
            backgroundColor: Colors.transparent,
            elevation: 0,
            leading: Material(
              color: Colors.transparent,
              child: InkWell(
                borderRadius: BorderRadius.circular(24),
                onTap: () => Navigator.pop(context),
                child: const Icon(Icons.arrow_back, color: Colors.white),
              ),
            ),
            title: Text(
              widget.topic.title.replaceFirst(RegExp(r'^\d+\.\s*'), ''),
              style: const TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.bold,
                color: Colors.white,
                letterSpacing: 0.5,
              ),
            ),
            bottom: PreferredSize(
              preferredSize: const Size.fromHeight(4),
              child: LinearProgressIndicator(
                value: _scrollProgress,
                backgroundColor: Colors.white.withOpacity(0.2),
                valueColor: const AlwaysStoppedAnimation<Color>(Colors.white),
                minHeight: 3,
              ),
            ),
          ),
        ),
      ),
      body: Stack(
        children: [
          // Background gradient
          Container(
            decoration: BoxDecoration(
              color: isDark ? Color(0xFF1A1A2E) : Color(0xFFF9FAFB),
              gradient: isDark 
                ? LinearGradient(
                    colors: [
                      Color(0xFF1A1A2E),
                      Color(0xFF16213E).withOpacity(0.5),
                    ],
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                  )
                : LinearGradient(
                    colors: [
                      Color(0xFFF9FAFB),
                      Colors.indigo.shade50.withOpacity(0.3),
                      Colors.purple.shade50.withOpacity(0.2),
                    ],
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                  ),
            ),
          ),
          
          // Content
          SingleChildScrollView(
            controller: _scrollController,
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 120),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Explanation Section
                if (widget.topic.explanation.isNotEmpty)
                  _buildAnimatedCard(
                    0,
                    _buildSectionCard(
                      'Explanation',
                      Icons.description,
                      widget.topic.explanation,
                      context,
                      cardBgColor,
                      textColor,
                      isDark,
                    ),
                  ),

                // Concept Sections
                if (widget.topic.conceptSections != null)
                  ...widget.topic.conceptSections!.asMap().entries.map((entry) {
                    final index = entry.key + 1;
                    final concept = entry.value;
                    return _buildAnimatedCard(
                      index,
                      _buildConceptCard(concept, context, cardBgColor, textColor, isDark),
                    );
                  }),

                // Revision Points
                _buildAnimatedCard(
                  _cardAnimations.length - 2,
                  _buildRevisionCard(widget.topic.revisionPoints, context, cardBgColor, textColor, isDark),
                ),

                const SizedBox(height: 16),

                // Action Buttons
                _buildAnimatedCard(
                  _cardAnimations.length - 1,
                  _buildActionButtons(context),
                ),
              ],
            ),
          ),

          // Scroll to top button
          if (_showScrollToTop)
            Positioned(
              bottom: 140,
              right: 20,
              child: Material(
                elevation: 8,
                borderRadius: BorderRadius.circular(30),
                color: colorScheme.primary,
                child: InkWell(
                  borderRadius: BorderRadius.circular(30),
                  onTap: _scrollToTop,
                  child: Container(
                    width: 56,
                    height: 56,
                    padding: const EdgeInsets.all(14),
                    child: const Icon(Icons.arrow_upward, color: Colors.white, size: 28),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }



  Widget _buildAnimatedCard(int index, Widget child) {
    final animation = index < _cardAnimations.length
        ? _cardAnimations[index]
        : const AlwaysStoppedAnimation(1.0);
    
    return AnimatedBuilder(
      animation: animation,
      builder: (context, _) {
        return Transform.translate(
          offset: Offset(0, 20 * (1 - animation.value)),
          child: Opacity(
            opacity: animation.value,
            child: child,
          ),
        );
      },
    );
  }

  Widget _buildSectionCard(String title, IconData icon, String content, BuildContext context, Color cardBgColor, Color textColor, bool isDark) {
    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      child: Card(
        elevation: isDark ? 2 : 4,
        shadowColor: const Color(0xFF5C6BC0).withOpacity(0.2),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        color: cardBgColor,
        child: Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(20),
            gradient: LinearGradient(
              colors: isDark
                ? [Color(0xFF2A2A3E), Color(0xFF3A3A52).withOpacity(0.5)]
                : [Colors.white, Colors.indigo.shade50.withOpacity(0.2)],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
          ),
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      gradient: const LinearGradient(
                        colors: [Color(0xFF5C6BC0), Color(0xFF7E57C2)],
                      ),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Icon(icon, color: Colors.white, size: 24),
                  ),
                  const SizedBox(width: 12),
                  Text(
                    title,
                    style: const TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.w700,
                      color: Color(0xFF5C6BC0),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              MarkdownBody(
                data: content,
                styleSheet: _buildMarkdownStyleSheet(context, cardBgColor, textColor, isDark),
                selectable: true,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildConceptCard(dynamic concept, BuildContext context, Color cardBgColor, Color textColor, bool isDark) {
    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      child: Card(
        elevation: isDark ? 2 : 4,
        shadowColor: const Color(0xFF7E57C2).withOpacity(0.2),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        color: cardBgColor,
        child: Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(20),
            gradient: LinearGradient(
              colors: isDark
                ? [Color(0xFF2A2A3E), Color(0xFF3A3A52).withOpacity(0.5)]
                : [Colors.white, Colors.purple.shade50.withOpacity(0.2)],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
          ),
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                decoration: BoxDecoration(
                  gradient: const LinearGradient(
                    colors: [Color(0xFF7E57C2), Color(0xFF9C27B0)],
                  ),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text(
                  concept.heading,
                  style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w600,
                    color: Colors.white,
                  ),
                ),
              ),
              const SizedBox(height: 16),
              MarkdownBody(
                data: concept.explanation,
                styleSheet: _buildMarkdownStyleSheet(context, cardBgColor, textColor, isDark),
              ),
              if (concept.codeSnippet.isNotEmpty) ...[
                const SizedBox(height: 16),
                Row(
                  children: [
                    Icon(Icons.code, color: Colors.purple.shade700, size: 20),
                    const SizedBox(width: 8),
                    const Text(
                      'Code Example',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                        color: Color(0xFF7E57C2),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: const Color(0xFF1E1E2E),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: Colors.purple.shade200, width: 1.5),
                  ),
                  child: Text(
                    concept.codeSnippet,
                    style: const TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 13,
                      color: Color(0xFF7DD3FC),
                      height: 1.5,
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildRevisionCard(List<String> points, BuildContext context, Color cardBgColor, Color textColor, bool isDark) {
    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      child: Card(
        elevation: isDark ? 2 : 4,
        shadowColor: Colors.amber.withOpacity(0.3),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        color: cardBgColor,
        child: Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(20),
            gradient: LinearGradient(
              colors: isDark
                ? [Color(0xFF2A2A3E), Color(0xFF3A3A52).withOpacity(0.5)]
                : [Colors.white, Colors.amber.shade50.withOpacity(0.3)],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
          ),
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        colors: [Colors.amber.shade600, Colors.orange.shade600],
                      ),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: const Icon(Icons.stars, color: Colors.white, size: 24),
                  ),
                  const SizedBox(width: 12),
                  const Text(
                    'Key Points to Remember',
                    style: TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.w700,
                      color: Color(0xFFD97706),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              ...points.asMap().entries.map((entry) {
                final index = entry.key;
                final point = entry.value;
                return Container(
                  margin: const EdgeInsets.only(bottom: 12),
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: isDark ? Color(0xFF3A3A52) : Colors.amber.shade50,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: isDark ? Colors.amber.shade900 : Colors.amber.shade200,
                      width: 1.5,
                    ),
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Container(
                        width: 28,
                        height: 28,
                        decoration: BoxDecoration(
                          color: Colors.amber.shade600,
                          shape: BoxShape.circle,
                        ),
                        child: Center(
                          child: Text(
                            '${index + 1}',
                            style: const TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.bold,
                              fontSize: 13,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          point,
                          style: TextStyle(
                            fontSize: 15,
                            height: 1.5,
                            color: isDark ? Colors.white70 : Color(0xFF374151),
                          ),
                        ),
                      ),
                    ],
                  ),
                );
              }),
            ],
          ),
        ),
      ),
    );
  }

  MarkdownStyleSheet _buildMarkdownStyleSheet(BuildContext context, Color cardBgColor, Color textColor, bool isDark) {
    return MarkdownStyleSheet(
      p: TextStyle(
        fontSize: 15,
        height: 1.6,
        color: isDark ? Colors.white70 : Color(0xFF374151),
      ),
      h1: TextStyle(
        fontSize: 22,
        fontWeight: FontWeight.bold,
        color: isDark ? Colors.white : Color(0xFF1A237E),
      ),
      h2: TextStyle(
        fontSize: 18,
        fontWeight: FontWeight.w600,
        color: isDark ? Colors.white : Color(0xFF5C6BC0),
      ),
      h3: TextStyle(
        fontSize: 16,
        fontWeight: FontWeight.w500,
        color: isDark ? Colors.white70 : Color(0xFF374151),
      ),
      strong: TextStyle(
        fontWeight: FontWeight.bold,
        color: isDark ? Colors.white : Color(0xFF1A237E),
      ),
      listBullet: TextStyle(
        fontSize: 18,
        color: isDark ? Colors.white : Color(0xFF5C6BC0),
      ),
      code: TextStyle(
        backgroundColor: isDark ? Color(0xFF2A2A3E) : Colors.indigo.shade50,
        color: isDark ? Color(0xFF7DD3FC) : Color(0xFF1A237E),
        fontFamily: 'monospace',
        fontSize: 14,
      ),
      codeblockDecoration: BoxDecoration(
        color: isDark ? Color(0xFF1E1E2E) : Color(0xFFF3F4F6),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: isDark ? Colors.purple.shade200 : Colors.indigo.shade100,
          width: 1.5,
        ),
      ),
      codeblockPadding: const EdgeInsets.all(16),
    );
  }

  Widget _buildActionButtons(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: Container(
            height: 56,
            decoration: BoxDecoration(
              gradient: const LinearGradient(
                colors: [Color(0xFF5C6BC0), Color(0xFF7E57C2)],
              ),
              borderRadius: BorderRadius.circular(16),
              boxShadow: [
                BoxShadow(
                  color: const Color(0xFF5C6BC0).withOpacity(0.4),
                  blurRadius: 12,
                  offset: const Offset(0, 6),
                ),
              ],
            ),
            child: Material(
              color: Colors.transparent,
              child: InkWell(
                borderRadius: BorderRadius.circular(16),
                onTap: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (context) => QuizScreen(topic: widget.topic),
                    ),
                  );
                },
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: const [
                    Icon(Icons.quiz, color: Colors.white, size: 24),
                    SizedBox(width: 12),
                    Text(
                      'Take Quiz',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                        color: Colors.white,
                        letterSpacing: 0.5,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
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

class _ChatMessage {
  final String role; // 'user' | 'assistant'
  final String content;
  final DateTime at;
  final List<_ChatAttachment> attachments;

  _ChatMessage._(this.role, this.content, this.at, [List<_ChatAttachment>? attachments])
      : attachments = attachments ?? const [];

  factory _ChatMessage.user(String content, {List<_ChatAttachment> attachments = const []}) =>
      _ChatMessage._('user', content, DateTime.now(), attachments);

  factory _ChatMessage.assistant(String content) =>
      _ChatMessage._('assistant', content, DateTime.now());
}

class _ChatPanel extends StatelessWidget {
  final bool isDark;
  final ColorScheme colorScheme;
  final List<_ChatMessage> messages;
  final bool sending;
  final TextEditingController controller;
  final ScrollController scrollController;
  final List<_ChatAttachment> pendingAttachments;
  final VoidCallback onSend;
  final VoidCallback onPickImage;
  final VoidCallback onPickFile;

  const _ChatPanel({
    required this.isDark,
    required this.colorScheme,
    required this.messages,
    required this.sending,
    required this.controller,
    required this.scrollController,
    required this.pendingAttachments,
    required this.onSend,
    required this.onPickImage,
    required this.onPickFile,
  });

  @override
  Widget build(BuildContext context) {
    final bg = isDark ? const Color(0xFF2A2A3E) : Colors.white;
    final border = isDark ? Colors.white12 : Colors.black12;

    return Material(
      elevation: isDark ? 2 : 8,
      borderRadius: BorderRadius.circular(18),
      color: bg,
      child: Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: border),
        ),
        padding: const EdgeInsets.all(12),
        height: 320,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.smart_toy, color: colorScheme.primary),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Doubt Clarifier',
                    style: TextStyle(
                      fontWeight: FontWeight.w700,
                      color: isDark ? Colors.white : const Color(0xFF111827),
                    ),
                  ),
                ),
                if (sending)
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

            // Quick-start topic chips (predefined prompts)
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  _QuickPromptChip(
                    label: 'Explain inheritance',
                    onTap: () {
                      controller.text = 'Explain inheritance with a simple example.';
                      onSend();
                    },
                  ),
                  _QuickPromptChip(
                    label: 'What is 3NF?',
                    onTap: () {
                      controller.text = 'Explain 3NF in database normalization.';
                      onSend();
                    },
                  ),
                  _QuickPromptChip(
                    label: 'INNER vs LEFT JOIN',
                    onTap: () {
                      controller.text = 'Difference between INNER JOIN and LEFT JOIN.';
                      onSend();
                    },
                  ),
                  _QuickPromptChip(
                    label: 'Method overriding',
                    onTap: () {
                      controller.text = 'What is method overriding? Give a Java example.';
                      onSend();
                    },
                  ),
                ],
              ),
            ),
            const SizedBox(height: 10),

            // Pending attachments preview (for current input)
            if (pendingAttachments.isNotEmpty) ...[
              Wrap(
                spacing: 6,
                runSpacing: 4,
                children: pendingAttachments
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
              child: ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: ListView.builder(
                  controller: scrollController,
                  itemCount: messages.length,
                  itemBuilder: (context, i) {
                    final m = messages[i];
                    final isUser = m.role == 'user';
                    final bubble = isUser
                        ? colorScheme.primary.withOpacity(isDark ? 0.35 : 0.12)
                        : (isDark ? Colors.white12 : const Color(0xFFF3F4F6));
                    final textColor = isDark ? Colors.white : const Color(0xFF111827);

                    return Align(
                      alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
                      child: Container(
                        margin: const EdgeInsets.only(bottom: 8),
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                        constraints: const BoxConstraints(maxWidth: 520),
                        decoration: BoxDecoration(
                          color: bubble,
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
                                  height: 1.4,
                                  fontSize: 14,
                                  fontWeight: FontWeight.w500,
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
                                  code: TextStyle(
                                    fontFamily: 'monospace',
                                    fontSize: 12.5,
                                    color: isDark ? const Color(0xFFBBDEFB) : const Color(0xFF1E3A8A),
                                    backgroundColor: isDark
                                        ? Colors.white10
                                        : const Color(0xFFE5E7EB),
                                  ),
                                  codeblockDecoration: BoxDecoration(
                                    color: isDark
                                        ? const Color(0xFF111827)
                                        : const Color(0xFFF3F4F6),
                                    borderRadius: BorderRadius.circular(8),
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
                                        padding:
                                            const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
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
                                                  width: 40,
                                                  height: 40,
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
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                // Attach image
                IconButton(
                  icon: Icon(Icons.image_outlined,
                      color: isDark ? Colors.white70 : const Color(0xFF6B7280)),
                  tooltip: 'Attach image',
                  onPressed: sending ? null : onPickImage,
                ),
                // Attach file
                IconButton(
                  icon: Icon(Icons.attach_file,
                      color: isDark ? Colors.white70 : const Color(0xFF6B7280)),
                  tooltip: 'Attach file',
                  onPressed: sending ? null : onPickFile,
                ),
                const SizedBox(width: 4),
                Expanded(
                  child: TextField(
                    controller: controller,
                    minLines: 1,
                    maxLines: 3,
                    textInputAction: TextInputAction.send,
                    onSubmitted: (_) => onSend(),
                    decoration: InputDecoration(
                      hintText: 'Type your doubt…',
                      isDense: true,
                      filled: true,
                      fillColor: isDark ? Colors.white10 : const Color(0xFFF9FAFB),
                      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: BorderSide(color: border),
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: BorderSide(color: border),
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: BorderSide(color: colorScheme.primary),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                SizedBox(
                  height: 42,
                  child: ElevatedButton(
                    onPressed: sending ? null : onSend,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: colorScheme.primary,
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                      padding: const EdgeInsets.symmetric(horizontal: 14),
                    ),
                    child: const Icon(Icons.send, size: 18),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              'AI answers may be inaccurate. Always verify with your course notes.',
              style: TextStyle(
                fontSize: 11,
                color: isDark ? Colors.white54 : const Color(0xFF6B7280),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _QuickPromptChip extends StatelessWidget {
  final String label;
  final VoidCallback onTap;

  const _QuickPromptChip({required this.label, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(right: 8.0),
      child: ActionChip(
        label: Text(
          label,
          style: const TextStyle(fontSize: 11.5),
        ),
        backgroundColor: const Color(0xFF1F2937).withOpacity(0.04),
        onPressed: onTap,
      ),
    );
  }
}

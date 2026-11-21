import 'package:flutter/material.dart';
import '../services/chat_service.dart';
import '../services/device_service.dart';
import '../services/time_sync_service.dart';
import '../utils/constants.dart';
import '../widgets/connection_status_badge.dart';
import '../widgets/message_bubble.dart';
import '../widgets/server_config_dialog.dart';
import 'join_class_screen.dart';

class ChatScreen extends StatefulWidget {
  const ChatScreen({super.key});

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final _textController = TextEditingController();
  final _scrollController = ScrollController();
  final _chatService = ChatService();
  final _deviceService = DeviceService();
  final _timeService = TimeSyncService();

  bool _isSending = false;

  @override
  void initState() {
    super.initState();
    _chatService.start();
  }

  @override
  void dispose() {
    _chatService.stop();
    _textController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  void _scrollToBottom() {
    if (_scrollController.hasClients) {
      _scrollController.animateTo(
        _scrollController.position.maxScrollExtent + 120,
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeOut,
      );
    }
  }

  Future<void> _handleSend() async {
    final text = _textController.text.trim();
    if (text.isEmpty || _isSending) return;

    setState(() => _isSending = true);
    _textController.clear();

    final success = await _chatService.sendMessage(text);
    if (!mounted) return;

    setState(() => _isSending = false);
    _scrollToBottom();

    if (!success && _chatService.lastSendError != null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Message enqueued locally (${_chatService.lastSendError})',
            style: const TextStyle(fontSize: 12),
          ),
          backgroundColor: Colors.orange.shade800,
          duration: const Duration(seconds: 2),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        titleSpacing: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          tooltip: 'Leave Class',
          onPressed: () {
            Navigator.of(context).pushReplacement(
              MaterialPageRoute(
                builder: (context) => const JoinClassScreen(),
              ),
            );
          },
        ),
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(
                  AppConstants.defaultRoomName,
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(width: 8),
                const ConnectionStatusBadge(compact: true, showLabel: false),
              ],
            ),
            ListenableBuilder(
              listenable: _deviceService,
              builder: (context, _) {
                return Text(
                  '${_deviceService.displayName} • ${_deviceService.shortDeviceId}',
                  style: TextStyle(
                    fontSize: 11,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                );
              },
            ),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Reconnect to relay',
            onPressed: _chatService.reconnectRelay,
          ),
          PopupMenuButton<String>(
            tooltip: 'Options',
            onSelected: (value) {
              switch (value) {
                case 'server':
                  showDialog(
                    context: context,
                    builder: (ctx) => const ServerConfigDialog(),
                  );
                  break;
                case 'clear':
                  _chatService.clearAllMessages();
                  break;
              }
            },
            itemBuilder: (context) => [
              const PopupMenuItem(
                value: 'server',
                child: Row(
                  children: [
                    Icon(Icons.dns_outlined, size: 18),
                    SizedBox(width: 8),
                    Text('Relay Settings'),
                  ],
                ),
              ),
              const PopupMenuDivider(),
              const PopupMenuItem(
                value: 'clear',
                child: Row(
                  children: [
                    Icon(Icons.delete_sweep_outlined, size: 18),
                    SizedBox(width: 8),
                    Text('Clear Active Messages'),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            // Synchronized TTL Notification Banner
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
              color: theme.colorScheme.primary.withValues(alpha: 0.08),
              child: Row(
                children: [
                  Icon(
                    Icons.auto_delete_outlined,
                    size: 15,
                    color: theme.colorScheme.primary,
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: ListenableBuilder(
                      listenable: _timeService,
                      builder: (context, _) {
                        final offset = _timeService.serverClockOffset.inMilliseconds;
                        final syncText = _timeService.hasSynced
                            ? 'Clock synced (${offset >= 0 ? '+' : ''}${offset}ms)'
                            : 'Local clock fallback';
                        return Text(
                          'Messages expire 30s after relay send time • $syncText',
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w500,
                            color: theme.colorScheme.primary,
                          ),
                        );
                      },
                    ),
                  ),
                ],
              ),
            ),

            // Point 12: PRESENCE Banner & Member Chip Strip
            ListenableBuilder(
              listenable: _chatService,
              builder: (context, _) {
                final count = _chatService.presenceCount;
                final members = _chatService.presenceMembers;
                final myName = _deviceService.displayName.trim();

                if (count == 0 && members.isEmpty) {
                  return const SizedBox.shrink();
                }

                return Container(
                  width: double.infinity,
                  decoration: BoxDecoration(
                    color: theme.colorScheme.surfaceContainerLow,
                    border: Border(
                      bottom: BorderSide(
                        color: theme.colorScheme.outlineVariant.withValues(alpha: 0.35),
                        width: 0.5,
                      ),
                    ),
                  ),
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 2),
                        child: Row(
                          children: [
                            Icon(
                              Icons.people_alt_outlined,
                              size: 15,
                              color: theme.colorScheme.primary,
                            ),
                            const SizedBox(width: 6),
                            Text(
                              '$count student${count == 1 ? '' : 's'} joined',
                              style: TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.bold,
                                color: theme.colorScheme.primary,
                              ),
                            ),
                            const SizedBox(width: 6),
                            Text(
                              '• in join order',
                              style: TextStyle(
                                fontSize: 10,
                                color: theme.colorScheme.outline,
                              ),
                            ),
                          ],
                        ),
                      ),
                      SizedBox(
                        height: 32,
                        child: ListView.separated(
                          scrollDirection: Axis.horizontal,
                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
                          itemCount: members.length,
                          separatorBuilder: (_, _) => const SizedBox(width: 6),
                          itemBuilder: (context, index) {
                            final memberName = members[index];
                            final isMe = memberName == myName ||
                                (myName.isEmpty && memberName == 'Student');

                            return Container(
                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                              decoration: BoxDecoration(
                                color: isMe
                                    ? theme.colorScheme.primaryContainer
                                    : theme.colorScheme.surfaceContainerHighest,
                                borderRadius: BorderRadius.circular(12),
                                border: Border.all(
                                  color: isMe
                                      ? theme.colorScheme.primary.withValues(alpha: 0.5)
                                      : theme.colorScheme.outlineVariant.withValues(alpha: 0.4),
                                  width: 0.8,
                                ),
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  CircleAvatar(
                                    radius: 7,
                                    backgroundColor: isMe
                                        ? theme.colorScheme.primary
                                        : theme.colorScheme.secondary,
                                    child: Text(
                                      '${index + 1}',
                                      style: const TextStyle(
                                        fontSize: 8,
                                        fontWeight: FontWeight.bold,
                                        color: Colors.white,
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 5),
                                  Text(
                                    isMe ? '$memberName (You)' : memberName,
                                    style: TextStyle(
                                      fontSize: 11,
                                      fontWeight: isMe ? FontWeight.bold : FontWeight.w500,
                                      color: isMe
                                          ? theme.colorScheme.onPrimaryContainer
                                          : theme.colorScheme.onSurface,
                                    ),
                                  ),
                                ],
                              ),
                            );
                          },
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),

            // Offline Queue Alert if items are pending
            ListenableBuilder(
              listenable: _chatService,
              builder: (context, _) {
                final queueCount = _chatService.offlineQueue.length;
                if (queueCount == 0) return const SizedBox.shrink();
                return Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
                  color: Colors.orange.shade100,
                  child: Row(
                    children: [
                      Icon(Icons.cloud_upload_outlined,
                          size: 14, color: Colors.orange.shade900),
                      const SizedBox(width: 6),
                      Text(
                        '$queueCount pending offline message${queueCount > 1 ? 's' : ''} (will discard if expired after 30s)',
                        style: TextStyle(
                          fontSize: 11,
                          color: Colors.orange.shade900,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),

            // Message List
            Expanded(
              child: ListenableBuilder(
                listenable: _chatService,
                builder: (context, _) {
                  final messages = _chatService.messages;

                  if (messages.isEmpty) {
                    return Center(
                      child: SingleChildScrollView(
                        padding: const EdgeInsets.all(24),
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Container(
                              padding: const EdgeInsets.all(16),
                              decoration: BoxDecoration(
                                color: theme.colorScheme.surfaceContainerHighest,
                                shape: BoxShape.circle,
                              ),
                              child: Icon(
                                Icons.chat_bubble_outline,
                                size: 40,
                                color: theme.colorScheme.outline,
                              ),
                            ),
                            const SizedBox(height: 16),
                            Text(
                              'No Active Messages',
                              style: theme.textTheme.titleMedium?.copyWith(
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            const SizedBox(height: 6),
                            ConstrainedBox(
                              constraints: const BoxConstraints(maxWidth: 320),
                              child: Text(
                                'Send a message below. The relay assigns its expiry time, and the message vanishes 30 seconds after sending.',
                                textAlign: TextAlign.center,
                                style: theme.textTheme.bodySmall?.copyWith(
                                  color: theme.colorScheme.outline,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    );
                  }

                  return ListView.builder(
                    controller: _scrollController,
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    itemCount: messages.length,
                    itemBuilder: (context, index) {
                      final message = messages[index];
                      return MessageBubble(
                        key: ValueKey(message.id),
                        message: message,
                      );
                    },
                  );
                },
              ),
            ),

            // Input Bar
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              decoration: BoxDecoration(
                color: theme.colorScheme.surface,
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.05),
                    blurRadius: 4,
                    offset: const Offset(0, -2),
                  ),
                ],
              ),
              child: SafeArea(
                top: false,
                child: Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _textController,
                        maxLength: AppConstants.maxMessageLength,
                        textInputAction: TextInputAction.send,
                        onSubmitted: (_) => _handleSend(),
                        decoration: InputDecoration(
                          hintText: 'Transmit vanishing message...',
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 10,
                          ),
                          filled: true,
                          fillColor: theme.colorScheme.surfaceContainerHighest,
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(24),
                            borderSide: BorderSide.none,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    FilledButton(
                      onPressed: _isSending ? null : _handleSend,
                      style: FilledButton.styleFrom(
                        shape: const CircleBorder(),
                        padding: const EdgeInsets.all(12),
                      ),
                      child: _isSending
                          ? const SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Colors.white,
                              ),
                            )
                          : const Icon(Icons.send, size: 20),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

import '../chat_models.dart';

/// A message submitted from the composer.
class ComposerMessage {
  const ComposerMessage({
    required this.text,
    this.mentions = const [],
    this.sessionMentions = const [],
    this.images = const [],
  });

  final String text;
  final List<String> mentions;

  /// Explicit @session picker selections, qualified by kernel and session ID.
  /// Plain text references do not authorize access to another conversation.
  final List<String> sessionMentions;
  final List<ImageAttachment> images;

  bool get isEmpty => text.trim().isEmpty && mentions.isEmpty && images.isEmpty;
}

/// Where the user writes to an agent from: told it, unseen, as that
/// changes (on send), for its replies to suit the screen
/// they are read on. Not its system prompt, which would break its cache.
enum UserPlace {
  /// The BaoCode app on their phone: replies read as chat bubbles.
  phone,

  /// The desktop app's composer.
  computer;

  /// What the agent is told when the user comes to write from here.
  String get note => switch (this) {
    phone =>
      '<system-reminder>The user is now writing to you from the BaoCode '
          'app on their phone, and reads your replies there as chat bubbles '
          'on a small screen. Reply as in a chat: plain, conversational text '
          'in short paragraphs, the outcome first. A little formatting is '
          'fine (bold, links, inline code, a short list); no headings, '
          'tables, long code blocks or wide layouts unless they ask for '
          'them. This holds until you are told they are back at their '
          'computer.</system-reminder>',
    computer =>
      '<system-reminder>The user is back at their computer, in the BaoCode '
          'desktop app: reply as you normally would there, Markdown and '
          'all.</system-reminder>',
  };

  /// What the agent is told with each message after the first from the
  /// phone: a word, that the way it replies there holds however long
  /// the conversation, whatever the model.
  static const stillOnPhone =
      '<system-reminder>Still on their phone: reply as in a chat, short, '
      'little formatting.</system-reminder>';
}

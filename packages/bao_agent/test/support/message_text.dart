/// The decoded string values of a request/message, not its JSON encoding.
/// Paths must retain their actual backslashes, quotes and spaces in assertions.
String messageText(Object? value) => switch (value) {
  final String text => text,
  final List items => items.map(messageText).join('\n'),
  final Map fields => fields.values.map(messageText).join('\n'),
  _ => '',
};

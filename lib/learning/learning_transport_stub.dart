import '../models/model_provider.dart';
import 'learning_models.dart';

Future<String> sendLearningRequest(
  ModelProvider provider,
  ProviderModel model,
  Map<String, Object?> body,
  LearningCancellation cancellation,
) => Future.error(UnsupportedError('Learning models need the desktop app.'));

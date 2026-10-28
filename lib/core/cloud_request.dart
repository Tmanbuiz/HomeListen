import 'dart:async';

import 'package:http/http.dart' as http;

/// The deadline covers headers AND body. Abort stalled requests so publishing
/// can resume after a network change instead of blocking the state queue.
Future<http.Response> sendCloudRequest(
  http.Client client,
  String method,
  Uri uri, {
  required Map<String, String> headers,
  String? body,
  Duration timeout = const Duration(seconds: 15),
}) async {
  final abort = Completer<void>();
  final request = http.AbortableRequest(method, uri, abortTrigger: abort.future)
    ..headers.addAll(headers);
  if (body != null) request.body = body;
  try {
    return await (() async {
      final response = await client.send(request);
      return http.Response.fromStream(response);
    })().timeout(timeout);
  } finally {
    if (!abort.isCompleted) abort.complete();
  }
}

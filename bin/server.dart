import 'dart:convert';
import 'dart:io';

Future<void> main() async {
  final server = await HttpServer.bind(InternetAddress.anyIPv4, 8080);
  print('Dart server running on port 8080');

  await for (final request in server) {
    if (request.uri.path == '/ws') {
      // WebSocket endpoint
      final socket = await WebSocketTransformer.upgrade(request);
      print('Client connected');

      socket.listen((data) {
        print('Received: $data');
        socket.add(jsonEncode({'type': 'echo', 'payload': data}));
      }, onDone: () => print('Client disconnected'));
    } else {
      // HTTP endpoint
      request.response
        ..statusCode = 200
        ..headers.contentType = ContentType.html
        ..write('<h1>Dart server is alive</h1>')
        ..close();
    }
  }
}

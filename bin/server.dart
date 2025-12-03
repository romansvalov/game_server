import 'dart:convert';
import 'dart:io';

import 'package:uuid/uuid.dart';
import 'package:game_server/models.dart' show
  GameInstance,
  GameEvent,
  PlayerState,
  PlayerStatus,
  ClientRole,
  generateId;

final Uuid _uuid = Uuid();

class ClientConnection {
  final String id;
  final WebSocket socket;
  String? gameId;
  ClientRole? role;
  String? playerId; // если это участница

  ClientConnection({
    required this.id,
    required this.socket,
  });
}

// Хранилище в памяти
final Map<String, GameInstance> games = {};   // gameId -> GameInstance
final Map<String, ClientConnection> clients = {}; // clientId -> ClientConnection

Future<void> main(List<String> args) async {
  final portEnv = Platform.environment['PORT'];
  final port = portEnv != null ? int.tryParse(portEnv) ?? 8080 : 8080;

  final server = await HttpServer.bind(InternetAddress.anyIPv4, port);
  print('Game server running on port $port');

  await for (final request in server) {
    if (request.uri.path == '/ws') {
      final socket = await WebSocketTransformer.upgrade(request);
      final clientId = _uuid.v4();
      final client = ClientConnection(id: clientId, socket: socket);
      clients[clientId] = client;

      print('Client connected: $clientId');

      socket.listen(
        (data) => _handleMessage(client, data),
        onDone: () => _handleDisconnect(client),
        onError: (err, st) {
          print('Socket error for client $clientId: $err');
          _handleDisconnect(client);
        },
      );
    } else {
      // Простая проверка, что сервер жив
      request.response
        ..statusCode = 200
        ..headers.contentType = ContentType.html
        ..write('<h1>Game server is alive</h1>')
        ..close();
    }
  }
}

/// Разбор входящих сообщений
void _handleMessage(ClientConnection client, dynamic data) {
  try {
    final raw = data is String ? data : utf8.decode(data as List<int>);
    final msg = jsonDecode(raw) as Map<String, dynamic>;
    final type = msg['type'] as String?;
    final payload = (msg['payload'] as Map?)?.cast<String, dynamic>() ?? {};

    if (type == null) {
      _sendError(client, 'Missing message type');
      return;
    }

    switch (type) {
      case 'ping':
        _send(client, {'type': 'pong', 'payload': {}});
        break;

      case 'create_game':
        _handleCreateGame(client, payload);
        break;

      case 'join_as_host':
        _handleJoinAsHost(client, payload);
        break;

      case 'join_as_player':
        _handleJoinAsPlayer(client, payload);
        break;

      case 'join_as_screen':
        _handleJoinAsScreen(client, payload);
        break;

      case 'start_game':
        _handleStartGame(client, payload);
        break;

      case 'roll_dice_auto':
        _handleRollDice(client, auto: true, payload: payload);
        break;

      case 'roll_dice_manual':
        _handleRollDice(client, auto: false, payload: payload);
        break;

      case 'next_turn':
        _handleNextTurn(client, payload);
        break;

      case 'add_comment':
        _handleAddComment(client, payload);
        break;

      default:
        _sendError(client, 'Unknown message type: $type');
    }
  } catch (e, st) {
    print('Error handling message: $e\n$st');
    _sendError(client, 'Invalid message format');
  }
}

GameInstance _getGameOrThrow(ClientConnection client) {
  final gameId = client.gameId;
  if (gameId == null || !games.containsKey(gameId)) {
    throw StateError('Game not found for client');
  }
  return games[gameId]!;
}

void _handleCreateGame(ClientConnection client, Map<String, dynamic> payload) {
  final templateId = payload['templateId'] as String? ?? 'default_template';

  final gameId = generateId();
  final code = gameId.substring(0, 6).toUpperCase();

  final game = GameInstance(
    id: gameId,
    templateId: templateId,
    code: code,
  );
  games[gameId] = game;

  client.gameId = gameId;
  client.role = ClientRole.host;
  game.hostClientId = client.id;

  print('Game created: $gameId / code=$code');

  _send(client, {
    'type': 'game_created',
    'payload': {
      'gameId': gameId,
      'code': code,
      'templateId': templateId,
    },
  });

  _sendRoomStateTo(client);
}

void _handleJoinAsHost(
  ClientConnection client,
  Map<String, dynamic> payload,
) {
  final code = (payload['code'] as String? ?? '').toUpperCase();
  final game = games.values.firstWhere(
    (g) => g.code == code,
    orElse: () => throw StateError('Game with code $code not found'),
  );

  client.gameId = game.id;
  client.role = ClientRole.host;
  game.hostClientId = client.id;

  print('Client ${client.id} joined as host to game ${game.id}');

  _sendRoomStateTo(client);
}

void _handleJoinAsPlayer(
  ClientConnection client,
  Map<String, dynamic> payload,
) {
  final code = (payload['code'] as String? ?? '').toUpperCase();
  final name = (payload['name'] as String? ?? 'Участница').trim();
  if (code.isEmpty) {
    _sendError(client, 'Missing game code');
    return;
  }
  final game = games.values.firstWhere(
    (g) => g.code == code,
    orElse: () => throw StateError('Game with code $code not found'),
  );

  client.gameId = game.id;
  client.role = ClientRole.player;

  final player = game.addPlayer(name);
  client.playerId = player.id;

  game.addEvent(
    GameEvent(
      id: generateId(),
      timestamp: DateTime.now(),
      type: 'player_joined',
      actorRole: 'player',
      actorId: player.id,
      payload: {'name': player.name},
    ),
  );

  print(
      'Client ${client.id} joined as player ${player.id} (${player.name}) to game ${game.id}');

  _broadcastRoomState(game);
}

void _handleJoinAsScreen(
  ClientConnection client,
  Map<String, dynamic> payload,
) {
  final code = (payload['code'] as String? ?? '').toUpperCase();
  final game = games.values.firstWhere(
    (g) => g.code == code,
    orElse: () => throw StateError('Game with code $code not found'),
  );

  client.gameId = game.id;
  client.role = ClientRole.screen;
  game.screenClientIds.add(client.id);

  print('Client ${client.id} joined as screen to game ${game.id}');

  _sendRoomStateTo(client);
}

void _handleStartGame(
  ClientConnection client,
  Map<String, dynamic> payload,
) {
  final game = _getGameOrThrow(client);
  if (client.role != ClientRole.host) {
    _sendError(client, 'Only host can start the game');
    return;
  }
  if (game.players.isEmpty) {
    _sendError(client, 'No players in game');
    return;
  }

  game.startedAt = DateTime.now();
  game.turnNumber = 1;

  final next = game.nextTurnPlayer();
  if (next == null) {
    _sendError(client, 'No available players to start');
    return;
  }

  game.currentPlayerId = next.id;
  next.status = PlayerStatus.active;

  game.addEvent(
    GameEvent(
      id: generateId(),
      timestamp: DateTime.now(),
      type: 'game_started',
      actorRole: 'host',
      actorId: null,
      payload: {},
    ),
  );

  _broadcastRoomState(game);
}

void _handleRollDice(
  ClientConnection client, {
  required bool auto,
  required Map<String, dynamic> payload,
}) {
  final game = _getGameOrThrow(client);
  if (game.currentPlayerId == null) {
    _sendError(client, 'Game has not started yet');
    return;
  }

  final currentPlayer = game.currentPlayer;
  if (currentPlayer == null) {
    _sendError(client, 'No current player');
    return;
  }

  final isHost = client.role == ClientRole.host;
  final isActivePlayer = client.role == ClientRole.player &&
      client.playerId == currentPlayer.id &&
      currentPlayer.status == PlayerStatus.active;

  if (!isHost && !isActivePlayer) {
    _sendError(client, 'Only host or active player can roll dice');
    return;
  }

  int roll;
  if (auto) {
    roll = (Random().nextInt(6) + 1);
  } else {
    final value = payload['value'] as int? ?? 1;
    roll = value.clamp(1, 6);
  }

  final oldPos = currentPlayer.position;
  final newPos = oldPos + roll; // пока без поля: просто двигаем вперёд

  currentPlayer.position = newPos;
  game.selectedCellId = newPos;
  game.lastDiceValue = roll;

  game.addEvent(
    GameEvent(
      id: generateId(),
      timestamp: DateTime.now(),
      type: 'dice_rolled',
      actorRole: isHost ? 'host' : 'player',
      actorId: isHost ? null : currentPlayer.id,
      payload: {
        'roll': roll,
        'from': oldPos,
        'to': newPos,
      },
    ),
  );

  _broadcastRoomState(game);
}

void _handleNextTurn(
  ClientConnection client,
  Map<String, dynamic> payload,
) {
  final game = _getGameOrThrow(client);
  if (game.currentPlayerId == null) {
    _sendError(client, 'Game has not started');
    return;
  }

  final currentPlayer = game.currentPlayer;
  if (currentPlayer == null) {
    _sendError(client, 'No current player');
    return;
  }

  final isHost = client.role == ClientRole.host;
  final isActivePlayer = client.role == ClientRole.player &&
      client.playerId == currentPlayer.id &&
      currentPlayer.status == PlayerStatus.active;

  if (!isHost && !isActivePlayer) {
    _sendError(client, 'Only host or active player can end the turn');
    return;
  }

  // Здесь можно вставить логику: если дошла до последней клетки -> finished
  // Пока просто переводим в waiting
  if (currentPlayer.status == PlayerStatus.active) {
    currentPlayer.status = PlayerStatus.waiting;
  }

  final next = game.nextTurnPlayer();
  if (next == null) {
    // Все, кто мог ходить, закончились -> считаем игру завершённой
    game.status = 'finished';
    game.finishedAt = DateTime.now();

    game.addEvent(
      GameEvent(
        id: generateId(),
        timestamp: DateTime.now(),
        type: 'game_finished',
        actorRole: isHost ? 'host' : 'player',
        actorId: isHost ? null : currentPlayer.id,
        payload: {},
      ),
    );
    _broadcastRoomState(game);
    return;
  }

  game.turnNumber += 1;
  game.currentPlayerId = next.id;
  next.status = PlayerStatus.active;

  game.addEvent(
    GameEvent(
      id: generateId(),
      timestamp: DateTime.now(),
      type: 'turn_changed',
      actorRole: isHost ? 'host' : 'player',
      actorId: isHost ? null : currentPlayer.id,
      payload: {
        'fromPlayerId': currentPlayer.id,
        'toPlayerId': next.id,
        'turnNumber': game.turnNumber,
      },
    ),
  );

  _broadcastRoomState(game);
}

void _handleAddComment(
  ClientConnection client,
  Map<String, dynamic> payload,
) {
  final game = _getGameOrThrow(client);
  final text = (payload['text'] as String? ?? '').trim();
  if (text.isEmpty) {
    _sendError(client, 'Comment text is empty');
    return;
  }

  String? actorRole;
  String? actorId;

  switch (client.role) {
    case ClientRole.host:
      actorRole = 'host';
      break;
    case ClientRole.player:
      actorRole = 'player';
      actorId = client.playerId;
      break;
    case ClientRole.screen:
      actorRole = 'screen';
      break;
    default:
      actorRole = 'unknown';
  }

  game.addEvent(
    GameEvent(
      id: generateId(),
      timestamp: DateTime.now(),
      type: 'comment_added',
      actorRole: actorRole,
      actorId: actorId,
      payload: {'text': text},
    ),
  );

  _broadcastRoomState(game);
}

/// Рассылка состояния комнаты
void _broadcastRoomState(GameInstance game) {
  final payload = game.toJson();
  final message = jsonEncode({
    'type': 'room_state',
    'payload': payload,
  });

  for (final c in clients.values) {
    if (c.gameId == game.id) {
      c.socket.add(message);
    }
  }
}

/// Отправить состояние конкретному клиенту
void _sendRoomStateTo(ClientConnection client) {
  final game = _getGameOrThrow(client);
  final payload = game.toJson();
  _send(client, {
    'type': 'room_state',
    'payload': payload,
  });
}

void _send(ClientConnection client, Map<String, dynamic> msg) {
  try {
    client.socket.add(jsonEncode(msg));
  } catch (e) {
    print('Error sending to client ${client.id}: $e');
  }
}

void _sendError(ClientConnection client, String message) {
  _send(client, {
    'type': 'error',
    'payload': {'message': message},
  });
}

void _handleDisconnect(ClientConnection client) {
  print('Client disconnected: ${client.id}');
  final gameId = client.gameId;
  final role = client.role;

  if (gameId != null && games.containsKey(gameId)) {
    final game = games[gameId]!;
    if (role == ClientRole.screen) {
      game.screenClientIds.remove(client.id);
    } else if (role == ClientRole.host) {
      if (game.hostClientId == client.id) {
        game.hostClientId = null;
      }
    }
    // игроков пока не удаляем, считаем, что они могут переподключиться
  }

  clients.remove(client.id);
}

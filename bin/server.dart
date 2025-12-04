import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

/// Запуск:
/// dart run bin/server.dart
///
/// WebSocket endpoint: ws://0.0.0.0:8080/ws

final _rnd = Random();

/// Максимальный номер клетки (длина поля)
const int kBoardMaxCell = 43;

/// ===== МОДЕЛИ ДАННЫХ =====

class Host {
  String id;          // 6-символьный код A-Z0-9
  String name;
  String status;      // 'active' / 'locked'
  int gamesCount;

  Host({
    required this.id,
    required this.name,
    required this.status,
    required this.gamesCount,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'status': status,
        'gamesCount': gamesCount,
      };
}

class PlayerState {
  String id;           // строковый id игрока внутри игры
  String name;
  int position;        // номер клетки
  int pearls;          // Жемчужины
  int amulets;         // Амулеты
  String status;       // 'active', 'waiting', 'finished', 'sleeping'

  PlayerState({
    required this.id,
    required this.name,
    required this.position,
    required this.pearls,
    required this.amulets,
    required this.status,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'position': position,
        'pearls': pearls,
        'amulets': amulets,
        'status': status,
      };
}

class GameRoom {
  String id;             // внутренний ID (uuid-like или счётчик)
  String code;           // читаемый код игры (для ведущего/участниц)
  String templateId;     // 'happy_from_proper'
  String? hostId;        // id ведущего
  String status;         // 'active' / 'finished'
  int turnNumber;
  String? currentPlayerId;
  DateTime startedAt;
  DateTime? finishedAt;

  final List<PlayerState> players = [];

  GameRoom({
    required this.id,
    required this.code,
    required this.templateId,
    required this.status,
    required this.turnNumber,
    required this.startedAt,
    this.hostId,
    this.currentPlayerId,
    this.finishedAt,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'code': code,
        'templateId': templateId,
        'hostId': hostId,
        'status': status,
        'turnNumber': turnNumber,
        'currentPlayerId': currentPlayerId,
        'startedAt': startedAt.toUtc().toIso8601String(),
        'finishedAt': finishedAt?.toUtc().toIso8601String(),
        'players': players.map((p) => p.toJson()).toList(),
      };
}

class ClientSession {
  final int id;
  final WebSocket socket;

  /// 'creator' | 'host' | 'player' | 'screen' (на будущее)
  String role;

  String? hostId;      // если ведущий или связанный экран
  String? gameCode;    // код игры, к которой привязан клиент
  String? playerId;    // если клиент — участник конкретной игры

  ClientSession({
    required this.id,
    required this.socket,
    required this.role,
    this.hostId,
    this.gameCode,
    this.playerId,
  });
}

/// ===== ГЛОБАЛЬНОЕ СОСТОЯНИЕ СЕРВЕРА (в памяти) =====

final Map<String, Host> _hosts = {};           // hostId -> Host
final Map<String, GameRoom> _gamesByCode = {}; // gameCode -> GameRoom
final Map<String, GameRoom> _gamesById = {};   // gameId   -> GameRoom
final Map<int, ClientSession> _sessions = {};  // sessionId -> ClientSession

int _nextSessionId = 1;
int _nextGameId = 1;
int _nextPlayerIdx = 1;

/// время последнего входа Создателя (общая)
DateTime? _creatorLastLogin;

/// ===== УТИЛИТЫ =====

String _randomCode(int length) {
  const chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789';
  return List.generate(length, (_) => chars[_rnd.nextInt(chars.length)]).join();
}

String _newGameId() => 'G${_nextGameId++}';

String _newPlayerId() => 'P${_nextPlayerIdx++}';

ClientSession _registerSession(WebSocket socket) {
  final session = ClientSession(
    id: _nextSessionId++,
    socket: socket,
    role: 'guest',
  );
  _sessions[session.id] = session;
  print('[SESSION ${session.id}] connected');
  return session;
}

void _removeSession(ClientSession session) {
  _sessions.remove(session.id);
  print('[SESSION ${session.id}] disconnected');
}

/// Отправка сообщения одному клиенту
void _sendToSession(ClientSession session, String type, Map<String, dynamic> payload) {
  final msg = jsonEncode({
    'type': type,
    'payload': payload,
  });
  session.socket.add(msg);
}

/// Широковещательный room_state всем клиентам, привязанным к этой игре
void _broadcastRoomState(GameRoom room) {
  final msg = jsonEncode({
    'type': 'room_state',
    'payload': room.toJson(),
  });

  for (final s in _sessions.values) {
    if (s.gameCode == room.code) {
      s.socket.add(msg);
    }
  }
}

/// Шлем всем создателям актуальное состояние ведущих
void _broadcastCreatorState() {
  final payload = {
    'hosts': _hosts.values.map((h) => h.toJson()).toList(),
    'lastLogin': _creatorLastLogin?.toUtc().toIso8601String(),
  };

  final msg = jsonEncode({
    'type': 'creator_state',
    'payload': payload,
  });

  for (final s in _sessions.values) {
    if (s.role == 'creator') {
      s.socket.add(msg);
    }
  }
}

/// Отправляем конкретному ведущему список его игр
void _sendHostGames(ClientSession session, String hostId) {
  final active = <Map<String, dynamic>>[];
  final finished = <Map<String, dynamic>>[];

  for (final room in _gamesByCode.values) {
    if (room.hostId != hostId) continue;

    final base = {
      'id': room.id,
      'code': room.code,
      'playerCount': room.players.length,
      'startedAt': room.startedAt.toUtc().toIso8601String(),
      'finishedAt': room.finishedAt?.toUtc().toIso8601String(),
    };

    if (room.status == 'active') {
      active.add(base);
    } else {
      finished.add(base);
    }
  }

  _sendToSession(session, 'host_games', {
    'active': active,
    'finished': finished,
  });
}

/// ===== ОБРАБОТЧИКИ КОМАНД =====

void _handleLoginCreator(ClientSession session, Map<String, dynamic> payload) {
  session.role = 'creator';
  _creatorLastLogin = DateTime.now().toUtc();

  _sendToSession(session, 'creator_state', {
    'hosts': _hosts.values.map((h) => h.toJson()).toList(),
    'lastLogin': _creatorLastLogin!.toIso8601String(),
  });
}

void _handleListHosts(ClientSession session, Map<String, dynamic> payload) {
  _sendToSession(session, 'creator_state', {
    'hosts': _hosts.values.map((h) => h.toJson()).toList(),
    'lastLogin': _creatorLastLogin?.toIso8601String(),
  });
}

/// Создание нового ведущего
void _handleCreateHost(ClientSession session, Map<String, dynamic> payload) {
  final id = (payload['id'] ?? '').toString().toUpperCase();
  final name = (payload['name'] ?? '').toString().trim();

  if (id.isEmpty || name.isEmpty) {
    _sendError(session, 'id и name обязательны для create_host');
    return;
  }

  if (_hosts.containsKey(id)) {
    _sendError(session, 'Ведущий с таким id уже существует: $id');
    return;
  }

  final host = Host(
    id: id,
    name: name,
    status: 'active',
    gamesCount: 0,
  );
  _hosts[id] = host;

  print('[CREATOR] created host $id ($name)');
  _broadcastCreatorState();
}

/// Обновление ведущего (статус и т.п.)
void _handleUpdateHost(ClientSession session, Map<String, dynamic> payload) {
  final id = (payload['id'] ?? '').toString().toUpperCase();
  final host = _hosts[id];
  if (host == null) {
    _sendError(session, 'Нет ведущего с id=$id');
    return;
  }

  final status = payload['status']?.toString();
  if (status != null && (status == 'active' || status == 'locked')) {
    host.status = status;
  }

  print('[CREATOR] update host $id: status=${host.status}');
  _broadcastCreatorState();
}

/// Удаление ведущего
void _handleDeleteHost(ClientSession session, Map<String, dynamic> payload) {
  final id = (payload['id'] ?? '').toString().toUpperCase();
  if (!_hosts.containsKey(id)) {
    _sendError(session, 'Нет ведущего с id=$id');
    return;
  }

  _hosts.remove(id);
  print('[CREATOR] delete host $id');
  _broadcastCreatorState();
}

/// Логин ведущего
void _handleLoginHost(ClientSession session, Map<String, dynamic> payload) {
  final hostId = (payload['hostId'] ?? '').toString().toUpperCase();
  final host = _hosts[hostId];

  if (host == null) {
    _sendError(session, 'Ведущий с id=$hostId не найден');
    return;
  }
  if (host.status != 'active') {
    _sendError(session, 'Ведущий $hostId заблокирован (status=${host.status})');
    return;
  }

  session.role = 'host';
  session.hostId = hostId;
  print('[HOST ${session.id}] logged in as $hostId');

  _sendHostGames(session, hostId);
}

/// Список игр ведущего
void _handleHostGamesRequest(ClientSession session, Map<String, dynamic> payload) {
  final hostId = (payload['hostId'] ?? '').toString().toUpperCase();
  if (hostId.isEmpty) {
    _sendError(session, 'hostId обязателен для host_games');
    return;
  }
  _sendHostGames(session, hostId);
}

/// Создание игры
void _handleCreateGame(ClientSession session, Map<String, dynamic> payload) {
  final templateId = (payload['templateId'] ?? '').toString();
  final hostId = (payload['hostId'] ?? '').toString().toUpperCase();

  if (templateId.isEmpty) {
    _sendError(session, 'templateId обязателен для create_game');
    return;
  }

  Host? host;
  if (hostId.isNotEmpty) {
    host = _hosts[hostId];
    if (host == null) {
      _sendError(session, 'Ведущий с id=$hostId не найден');
      return;
    }
    if (host.status != 'active') {
      _sendError(session, 'Ведущий $hostId заблокирован');
      return;
    }
  }

  // генерим уникальный код игры
  String code;
  do {
    code = _randomCode(6);
  } while (_gamesByCode.containsKey(code));

  final gameId = _newGameId();
  final room = GameRoom(
    id: gameId,
    code: code,
    templateId: templateId,
    status: 'active',
    turnNumber: 0,
    startedAt: DateTime.now().toUtc(),
    hostId: hostId.isEmpty ? null : hostId,
  );

  _gamesByCode[code] = room;
  _gamesById[gameId] = room;

  if (host != null) {
    host.gamesCount += 1;
    _broadcastCreatorState(); // обновим статистику ведущих
  }

  print('[GAME] created $code (id=$gameId, hostId=${room.hostId})');

  _sendToSession(session, 'game_created', {
    'id': gameId,
    'code': code,
    'hostId': room.hostId,
  });
}

/// Ведущий подключается к игре
void _handleJoinAsHost(ClientSession session, Map<String, dynamic> payload) {
  final code = (payload['code'] ?? '').toString().toUpperCase();
  if (code.isEmpty) {
    _sendError(session, 'code обязателен для join_as_host');
    return;
  }
  final room = _gamesByCode[code];
  if (room == null) {
    _sendError(session, 'Игра с кодом $code не найдена');
    return;
  }

  final hostId = (payload['hostId'] ?? '').toString().toUpperCase();
  if (room.hostId != null && hostId.isNotEmpty && room.hostId != hostId) {
    _sendError(session, 'Эта игра закреплена за другим ведущим (hostId=${room.hostId})');
    return;
  }

  session.role = 'host';
  session.hostId = hostId.isNotEmpty ? hostId : room.hostId;
  session.gameCode = code;

  print('[HOST ${session.id}] joined game $code');

  _broadcastRoomState(room);
}

/// Участница подключается к игре
void _handleJoinAsPlayer(ClientSession session, Map<String, dynamic> payload) {
  final code = (payload['code'] ?? '').toString().toUpperCase();
  final name = (payload['name'] ?? '').toString().trim().isEmpty
      ? 'Участница'
      : (payload['name'] ?? '').toString().trim();

  final room = _gamesByCode[code];
  if (room == null) {
    _sendError(session, 'Игра с кодом $code не найдена');
    return;
  }
  if (room.status != 'active') {
    _sendError(session, 'Игра $code уже завершена');
    return;
  }

  final playerId = _newPlayerId();
  final player = PlayerState(
    id: playerId,
    name: name,
    position: 1,
    pearls: 0,
    amulets: 0,
    status: 'waiting',
  );
  room.players.add(player);

  // Если не было активного игрока — делаем первую участницу активной
  room.currentPlayerId ??= player.id;

  session.role = 'player';
  session.gameCode = code;
  session.playerId = playerId;

  print('[PLAYER ${session.id}] "$name" joined game $code as $playerId');

  _broadcastRoomState(room);
}

/// Завершение игры ведущим
void _handleFinishGame(ClientSession session, Map<String, dynamic> payload) {
  final code = (payload['code'] ?? '').toString().toUpperCase();
  if (code.isEmpty) {
    _sendError(session, 'code обязателен для finish_game');
    return;
  }
  final room = _gamesByCode[code];
  if (room == null) {
    _sendError(session, 'Игра с кодом $code не найдена');
    return;
  }

  room.status = 'finished';
  room.finishedAt = DateTime.now().toUtc();

  print('[GAME] finished $code');

  _broadcastRoomState(room);
}

/// Переход хода
void _handleNextTurn(ClientSession session, Map<String, dynamic> payload) {
  final code = session.gameCode;
  if (code == null) {
    _sendError(session, 'Сессия не привязана к игре (next_turn)');
    return;
  }
  final room = _gamesByCode[code];
  if (room == null) {
    _sendError(session, 'Игра с кодом $code не найдена');
    return;
  }
  if (room.players.isEmpty) {
    _sendError(session, 'В игре $code пока нет участников');
    return;
  }

  // текущий индекс
  int idx = 0;
  if (room.currentPlayerId != null) {
    final currentIndex = room.players.indexWhere((p) => p.id == room.currentPlayerId);
    idx = currentIndex < 0 ? 0 : currentIndex;
  }

  // ищем следующего игрока (по кругу)
  int attempts = 0;
  do {
    idx = (idx + 1) % room.players.length;
    attempts++;
    if (attempts > room.players.length + 2) break;
  } while (room.players[idx].status == 'finished');

  room.currentPlayerId = room.players[idx].id;
  room.turnNumber += 1;

  print('[GAME $code] next_turn => player=${room.currentPlayerId}');

  _broadcastRoomState(room);
}

/// Авто-бросок кубика
void _handleRollDiceAuto(ClientSession session, Map<String, dynamic> payload) {
  final value = _rnd.nextInt(6) + 1;
  _advanceCurrentPlayer(session, value, source: 'auto');
}

/// Ручной бросок кубика
void _handleRollDiceManual(ClientSession session, Map<String, dynamic> payload) {
  final v = payload['value'];
  final value = v is int ? v : int.tryParse(v?.toString() ?? '');
  if (value == null || value < 1 || value > 6) {
    _sendError(session, 'Некорректное значение кубика: $v');
    return;
  }
  _advanceCurrentPlayer(session, value, source: 'manual');
}

/// Движение текущей участницы вперёд на value
void _advanceCurrentPlayer(ClientSession session, int value, {required String source}) {
  final code = session.gameCode;
  if (code == null) {
    _sendError(session, 'Сессия не привязана к игре (roll_dice_$source)');
    return;
  }
  final room = _gamesByCode[code];
  if (room == null) {
    _sendError(session, 'Игра с кодом $code не найдена');
    return;
  }
  if (room.currentPlayerId == null) {
    _sendError(session, 'В игре $code нет активной участницы');
    return;
  }

  final player = room.players.firstWhere(
    (p) => p.id == room.currentPlayerId,
    orElse: () => room.players.first,
  );

  final oldPos = player.position;
  var newPos = oldPos + value;
  if (newPos > kBoardMaxCell) newPos = kBoardMaxCell;
  player.position = newPos;

  if (newPos >= kBoardMaxCell) {
    player.status = 'finished';
  }

  print('[GAME $code] $source dice: player=${player.id} $oldPos -> $newPos');

  _broadcastRoomState(room);
}

/// Добавление текстового комментария (лог) — пока просто печатаем в консоль
void _handleAddComment(ClientSession session, Map<String, dynamic> payload) {
  final text = (payload['text'] ?? '').toString();
  final code = session.gameCode ?? 'NO_GAME';

  print('[COMMENT][$code] $text');
}

/// ===== ОТПРАВКА ОШИБОК =====

void _sendError(ClientSession session, String message) {
  final payload = {
    'message': message,
  };
  final msg = jsonEncode({
    'type': 'error',
    'payload': payload,
  });
  session.socket.add(msg);
  print('[ERROR to session ${session.id}] $message');
}

/// ===== WS-ОБРАБОТЧИК =====

void _handleWsClient(WebSocket socket) {
  final session = _registerSession(socket);

  socket.listen(
    (data) {
      try {
        final decoded = jsonDecode(data as String);
        if (decoded is! Map) return;
        final type = decoded['type']?.toString();
        final payload =
            decoded['payload'] is Map ? Map<String, dynamic>.from(decoded['payload']) : <String, dynamic>{};

        if (type == null) return;

        switch (type) {
          case 'login_creator':
            _handleLoginCreator(session, payload);
            break;
          case 'list_hosts':
            _handleListHosts(session, payload);
            break;
          case 'create_host':
            _handleCreateHost(session, payload);
            break;
          case 'update_host':
            _handleUpdateHost(session, payload);
            break;
          case 'delete_host':
            _handleDeleteHost(session, payload);
            break;
          case 'login_host':
            _handleLoginHost(session, payload);
            break;
          case 'host_games':
            _handleHostGamesRequest(session, payload);
            break;
          case 'create_game':
            _handleCreateGame(session, payload);
            break;
          case 'join_as_host':
            _handleJoinAsHost(session, payload);
            break;
          case 'join_as_player':
            _handleJoinAsPlayer(session, payload);
            break;
          case 'finish_game':
            _handleFinishGame(session, payload);
            break;
          case 'next_turn':
            _handleNextTurn(session, payload);
            break;
          case 'roll_dice_auto':
            _handleRollDiceAuto(session, payload);
            break;
          case 'roll_dice_manual':
            _handleRollDiceManual(session, payload);
            break;
          case 'add_comment':
            _handleAddComment(session, payload);
            break;
          default:
            _sendError(session, 'Неизвестный тип сообщения: $type');
        }
      } catch (e, st) {
        print('[SESSION ${session.id}] json error: $e\n$st');
        _sendError(session, 'Ошибка парсинга сообщения: $e');
      }
    },
    onDone: () {
      _removeSession(session);
    },
    onError: (err) {
      print('[SESSION ${session.id}] socket error: $err');
      _removeSession(session);
    },
  );
}

/// ===== MAIN =====

Future<void> main(List<String> args) async {
  final port = args.isNotEmpty ? int.tryParse(args.first) ?? 8080 : 8080;

  final server = await HttpServer.bind(
    InternetAddress.anyIPv4,
    port,
  );

  print('Game WS server listening on ws://0.0.0.0:$port/ws');

  await for (final HttpRequest req in server) {
    if (req.uri.path == '/ws') {
      try {
        final socket = await WebSocketTransformer.upgrade(req);
        _handleWsClient(socket);
      } catch (e, st) {
        print('WebSocket upgrade error: $e\n$st');
        req.response
          ..statusCode = HttpStatus.internalServerError
          ..write('WebSocket upgrade error')
          ..close();
      }
    } else {
      req.response
        ..statusCode = HttpStatus.ok
        ..headers.set('Content-Type', 'text/plain; charset=utf-8')
        ..write('Game server is running.\nUse WebSocket at /ws.')
        ..close();
    }
  }
}

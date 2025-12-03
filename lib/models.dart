import 'dart:math';
import 'package:uuid/uuid.dart';

final Uuid _uuid = Uuid();
final Random _rng = Random();

String generateId() => _uuid.v4();

enum ClientRole { host, player, screen }

enum PlayerStatus {
  active,    // сейчас ходит
  waiting,   // в очереди, ждёт хода
  finished,  // дошла до финала
  sleeping,  // в паузе, пропускает ходы
}

class PlayerState {
  final String id;
  String name;
  int position;
  int pearls;
  int amulets;
  PlayerStatus status;
  DateTime joinedAt;
  DateTime? finishedAt;

  PlayerState({
    required this.id,
    required this.name,
    this.position = 1,
    this.pearls = 5,
    this.amulets = 0,
    this.status = PlayerStatus.waiting,
    DateTime? joinedAt,
    this.finishedAt,
  }) : joinedAt = joinedAt ?? DateTime.now();

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'name': name,
      'position': position,
      'pearls': pearls,
      'amulets': amulets,
      'status': status.name,
      'joinedAt': joinedAt.toIso8601String(),
      'finishedAt': finishedAt?.toIso8601String(),
    };
  }
}

class GameEvent {
  final String id;
  final DateTime timestamp;
  final String type;
  final String? actorRole;
  final String? actorId;
  final Map<String, dynamic> payload;

  GameEvent({
    required this.id,
    required this.timestamp,
    required this.type,
    this.actorRole,
    this.actorId,
    Map<String, dynamic>? payload,
  }) : payload = payload ?? {};

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'timestamp': timestamp.toIso8601String(),
      'type': type,
      'actorRole': actorRole,
      'actorId': actorId,
      'payload': payload,
    };
  }
}

class GameInstance {
  final String id;
  final String templateId; // пока просто строка, потом подвяжем реальные шаблоны
  final String code;       // короткий код для входа (6 символов)
  String status;           // "active" | "finished" | "archived"

  DateTime createdAt;
  DateTime? startedAt;
  DateTime? finishedAt;

  String? hostClientId;
  final Set<String> screenClientIds = {};
  final Map<String, PlayerState> players = {};
  final List<String> playerOrder = [];

  String? currentPlayerId;
  int turnNumber = 0;
  int? selectedCellId; // позже: реальное поле
  int? lastDiceValue;

  final List<GameEvent> log = [];

  GameInstance({
    required this.id,
    required this.templateId,
    required this.code,
  })  : status = 'active',
        createdAt = DateTime.now();

  PlayerState? get currentPlayer =>
      currentPlayerId != null ? players[currentPlayerId] : null;

  /// Добавить игрока
  PlayerState addPlayer(String name) {
    final playerId = generateId();
    final player = PlayerState(
      id: playerId,
      name: name,
      position: 1,
      status: PlayerStatus.waiting,
    );
    players[playerId] = player;
    playerOrder.add(playerId);
    return player;
  }

  /// Найти следующего игрока по очереди, учитывая статус
  PlayerState? nextTurnPlayer() {
    if (playerOrder.isEmpty) return null;
    if (currentPlayerId == null) {
      // первый ход
      return players[playerOrder.firstWhere(
        (id) => players[id]?.status == PlayerStatus.waiting,
        orElse: () => playerOrder.first,
      )];
    }

    final idx = playerOrder.indexOf(currentPlayerId!);
    if (idx == -1) return null;

    for (var i = 1; i <= playerOrder.length; i++) {
      final nextIndex = (idx + i) % playerOrder.length;
      final candidateId = playerOrder[nextIndex];
      final candidate = players[candidateId];
      if (candidate == null) continue;

      if (candidate.status == PlayerStatus.waiting ||
          candidate.status == PlayerStatus.active) {
        return candidate;
      }
    }
    return null;
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'templateId': templateId,
      'code': code,
      'status': status,
      'createdAt': createdAt.toIso8601String(),
      'startedAt': startedAt?.toIso8601String(),
      'finishedAt': finishedAt?.toIso8601String(),
      'turnNumber': turnNumber,
      'currentPlayerId': currentPlayerId,
      'selectedCellId': selectedCellId,
      'lastDiceValue': lastDiceValue,
      'players': players.values.map((p) => p.toJson()).toList(),
      'screenClients': screenClientIds.toList(),
      'log': log.map((e) => e.toJson()).toList(),
    };
  }

  void addEvent(GameEvent event) {
    log.add(event);
    if (log.length > 500) {
      log.removeRange(0, log.length - 500);
    }
  }
}

class ClientConnection {
  final String id;
  final WebSocket socket;
  String? gameId;
  ClientRole? role;
  String? playerId;

  ClientConnection({
    required this.id,
    required this.socket,
  });
}

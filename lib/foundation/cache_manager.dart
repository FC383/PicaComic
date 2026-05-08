import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:pica_comic/foundation/app.dart';
import 'package:pica_comic/tools/io_extensions.dart';
import 'package:sqlite3/sqlite3.dart';

class CacheManager {
  static String get cachePath => '${App.cachePath}/cache';

  static CacheManager? instance;

  late Database _db;

  int? _currentSize;

  /// size in bytes
  int get currentSize => _currentSize ?? 0;

  int dir = 0;

  int _limitSize = 2 * 1024 * 1024 * 1024;

  int get limitSize => _limitSize;

  /// 修改 2：延迟初始化标记，避免在构造函数中执行重量级 IO
  bool _sizeInitialized = false;
  bool _needCheckAfterInit = false;

  CacheManager._create(){
    Directory(cachePath).createSync(recursive: true);
    _db = sqlite3.open('${App.dataPath}/cache.db');
    _db.execute('''
      CREATE TABLE IF NOT EXISTS cache (
        key TEXT PRIMARY KEY NOT NULL,
        dir TEXT NOT NULL,
        name TEXT NOT NULL,
        expires INTEGER NOT NULL,
        type TEXT
      )
    ''');
    // 旧版本的表中没有type字段，需要添加
    try {
      _db.execute('''
        ALTER TABLE cache ADD COLUMN type TEXT
      ''');
    } catch (e) {
      // ignore
    }
    // 延迟初始化目录大小：避免在构造函数中执行重量级 IO（修改 2）
    _initCurrentSize();
  }

  factory CacheManager() => instance ??= CacheManager._create();

  /// 修改 2：异步初始化目录大小，使用安全的 _calcDirSize 避免 isolate OOM
  Future<void> _initCurrentSize() async {
    try {
      _currentSize = await _calcDirSize(cachePath);
    } catch (e) {
      // 初始化失败回退为 0，避免 _sizeInitialized 为 true 但 _currentSize 为 null 时空指针
      _currentSize = 0;
    } finally {
      _sizeInitialized = true;
      if (_needCheckAfterInit) {
        _needCheckAfterInit = false;
        await checkCache();
      }
    }
  }

  /// set cache size limit in MB
  /// 修改 4：缩小限制时立即触发清理
  void setLimitSize(int size){
    _limitSize = size * 1024 * 1024;
    // 如果当前缓存已超过新限制，触发清理
    if (_sizeInitialized && _currentSize! > _limitSize) {
      checkCache();
    }
  }

  void setType(String key, String? type){
    _db.execute('''
      UPDATE cache
      SET type = ?
      WHERE key = ?
    ''', [type, key]);
  }

  String? getType(String key){
    var res = _db.select('''
      SELECT type FROM cache
      WHERE key = ?
    ''', [key]);
    if(res.isEmpty){
      return null;
    }
    return res.first[0];
  }

  /// 修改 3：使用 _sizeInitialized 替代 _currentSize != null，新增 _needCheckAfterInit 分支
  Future<void> writeCache(String key, Uint8List data, [int duration = 7 * 24 * 60 * 60 * 1000]) async{
  this.dir++;
  this.dir %= 100;
  var dir = this.dir;
  var name = md5.convert(Uint8List.fromList(key.codeUnits)).toString();
  var file = File('$cachePath/$dir/$name');
  while(await file.exists()){
    name = md5.convert(Uint8List.fromList(name.codeUnits)).toString();
    file = File('$cachePath/$dir/$name');
  }

  // 先写入 DB 记录，再写文件：确保 DB 是文件的权威来源
  var expires = DateTime.now().millisecondsSinceEpoch + duration;
  _db.execute('''
    INSERT OR REPLACE INTO cache (key, dir, name, expires) VALUES (?, ?, ?, ?)
  ''', [key, dir.toString(), name, expires]);

  try {
    await file.create(recursive: true);
    await file.writeAsBytes(data);
  } catch (e) {
    // 文件写入失败，回滚 DB 记录，防止 DB 中存在无对应文件的记录
    _db.execute('DELETE FROM cache WHERE key = ?', [key]);
    rethrow;
  }

  if (_sizeInitialized) {
    _currentSize = (_currentSize ?? 0) + data.length;
    if ((_currentSize ?? 0) > _limitSize) {
      await checkCache();
    }
  } else {
    _needCheckAfterInit = true;
  }
}

  Future<CachingFile> openWrite(String key) async{
    this.dir++;
    this.dir %= 100;
    var dir = this.dir;
    var name = md5.convert(Uint8List.fromList(key.codeUnits)).toString();
    var file = File('$cachePath/$dir/$name');
    while(await file.exists()){
      name = md5.convert(Uint8List.fromList(name.codeUnits)).toString();
      file = File('$cachePath/$dir/$name');
    }
    await file.create(recursive: true);
    return CachingFile._(key, dir.toString(), name, file);
  }

  Future<String?> findCache(String key) async{
    var res = _db.select('''
      SELECT * FROM cache
      WHERE key = ?
    ''', [key]);
    if(res.isEmpty){
      return null;
    }
    try {
      var row = res.first;
      var dir = row[1] as String;
      var name = row[2] as String;
      var file = File('$cachePath/$dir/$name');
      if(await file.exists()){
        return file.path;
      }
    } catch (_) {
      // 权限不足或文件系统异常时返回 null
    }
    return null;
  }

  bool _isChecking = false;

  /// 修改 1：移除 compute，使用 _calcDirSize 避免 isolate OOM；加 try-finally 防止 _isChecking 锁死；
  /// 添加 anyDeleted 防止空转死循环
  Future<void> checkCache() async{
    if(_isChecking){
      return;
    }
    _isChecking = true;
    try {
      // 第一步：清理已过期的缓存条目
      var res = _db.select('''
        SELECT * FROM cache
        WHERE expires < ?
      ''', [DateTime.now().millisecondsSinceEpoch]);
      for(var row in res){
        try {
          var dir = row[1] as String;
          var name = row[2] as String;
          var file = File('$cachePath/$dir/$name');
          if(await file.exists()){
            await file.delete();
          }
        } catch (_) {
          // 权限不足或文件被外部删除时跳过
        }
      }
      _db.execute('''
        DELETE FROM cache
        WHERE expires < ?
      ''', [DateTime.now().millisecondsSinceEpoch]);

      // 第二步：获取当前条目数
      int count = 0;
      var res2 = _db.select('SELECT COUNT(*) FROM cache');
      if(res2.isNotEmpty){
        count = res2.first[0] as int;
      }

      // 第三步：在主 isolate 中直接计算目录大小（移除 compute，避免 isolate OOM）
      _currentSize = await _calcDirSize(cachePath);

      // 第四步：循环清理直到满足限制
      while (_currentSize! > _limitSize || count > 2000) {
        var res3 = _db.select('''
          SELECT * FROM cache
          ORDER BY expires ASC
          LIMIT 10
        ''');
        bool anyDeleted = false;
        for(var row in res3){
          try {
            var key = row[0] as String;
            var dir = row[1] as String;
            var name = row[2] as String;
            var file = File('$cachePath/$dir/$name');
            if(await file.exists()){
              var size = await file.length();
              await file.delete();
              _db.execute('DELETE FROM cache WHERE key = ?', [key]);
              _currentSize = _currentSize! - size;
              anyDeleted = true;
              if(_currentSize! <= _limitSize && count - 1 <= 2000){
                break;
              }
            } else {
              _db.execute('DELETE FROM cache WHERE key = ?', [key]);
              anyDeleted = true;
            }
          } catch (_) { 
            //// 权限不足或文件操作异常时跳过当前条目，继续处理下一个
          }
          count--;
        }
        if (!anyDeleted) {
          break; // 防止死循环：数据库中还有记录但文件都已不存在
        }
      }
    } finally {
      _isChecking = false;
    }
  }

  /// 修改 1：在主 isolate 中分批计算目录大小，避免 listSync(recursive: true) OOM
  Future<int> _calcDirSize(String path) async {
    int total = 0;
    final dir = Directory(path);
    if (!dir.existsSync()) return 0;
    final List<FileSystemEntity> entries = dir.listSync(followLinks: false);//防止目录包含软链接 / 符号链接（指向自身 / 上级目录），递归无限执行
    for (final entity in entries) {
      try {
        if (entity is File) {
          total += await entity.length();
        } else if (entity is Directory) {
          total += await _calcDirSize(entity.path);
        }
      } catch (_) {
        // 权限不足或文件被删除时跳过
      }
    }
    return total;
  }

  /// 修改 5：使用 _sizeInitialized 替代 _currentSize != null
  Future<void> delete(String key) async{
    var res = _db.select('''
      SELECT * FROM cache
      WHERE key = ?
    ''', [key]);
    if(res.isEmpty){
      return;
    }
    var row = res.first;
    var dir = row[1] as String;
    var name = row[2] as String;
    var file = File('$cachePath/$dir/$name');
    var fileSize = 0;
    try {
      if(await file.exists()){
        fileSize = await file.length();
        await file.delete();
      }
    } catch (_) {
      // 权限不足或文件被外部删除时跳过
      fileSize = 0;
    }
    _db.execute('''
      DELETE FROM cache
      WHERE key = ?
    ''', [key]);
    if (_sizeInitialized) {
      _currentSize = _currentSize! - fileSize;
    }
  }

  Future<void> clear() async {
    try {
      await Directory(cachePath).delete(recursive: true);
    } catch (_) {
      // 权限不足时忽略
    }
    Directory(cachePath).createSync(recursive: true);
    _db.execute('''
      DELETE FROM cache
    ''');
    _currentSize = 0;
  }

  /// 修改 7：空 finally → deleteIgnoreError；修改 5：_currentSize != null → _sizeInitialized
  Future<void> deleteKeyword(String keyword) async{
    var res = _db.select('''
      SELECT * FROM cache
      WHERE key LIKE ?
    ''', ['%$keyword%']);
    for(var row in res){
      var key = row[0] as String;
      var dir = row[1] as String;
      var name = row[2] as String;
      var file = File('$cachePath/$dir/$name');
      var fileSize = 0;
      try {
        if(await file.exists()){
          fileSize = await file.length();
        }
      } catch (_) {
        // 权限不足或文件被外部删除时跳过
        fileSize = 0;
      }
      await file.deleteIgnoreError();
      _db.execute('''
        DELETE FROM cache
        WHERE key = ?
      ''', [key]);
      if (_sizeInitialized) {
        _currentSize = _currentSize! - fileSize;
      }
    }
  }
}

/// 修改 6：新增 _writtenBytes 追踪，修改 close()/cancel()/reset() 同步 _currentSize
class CachingFile{
  CachingFile._(this.key, this.dir, this.name, this.file);

  final String key;

  final String dir;

  final String name;

  final File file;

  final List<int> _buffer = [];

  int _writtenBytes = 0; // 跟踪已写入磁盘的字节数

  Future<void> writeBytes(List<int> data) async{
    _buffer.addAll(data);
    if(_buffer.length > 1024 * 1024){
      await file.writeAsBytes(_buffer, mode: FileMode.append);
      _writtenBytes += _buffer.length;
      _buffer.clear();
    }
  }

  Future<void> close() async{
    if(_buffer.isNotEmpty){
      await file.writeAsBytes(_buffer, mode: FileMode.append);
      _writtenBytes += _buffer.length;
      _buffer.clear();
    }
    CacheManager()._db.execute('''
      INSERT OR REPLACE INTO cache (key, dir, name, expires) VALUES (?, ?, ?, ?)
    ''', [key, dir, name, DateTime.now().millisecondsSinceEpoch + 7 * 24 * 60 * 60 * 1000]);

    // 追踪写入的缓存大小
    final cm = CacheManager();
    if (cm._sizeInitialized) {
      cm._currentSize = cm._currentSize! + _writtenBytes;
      if (cm._currentSize! > cm._limitSize) {
        await cm.checkCache();
        return;
      }
    } else {
      cm._needCheckAfterInit = true;
    }

    await cm.checkCache();
  }

  Future<void> cancel() async{
    // 如果已写入部分数据且 _currentSize 已追踪，需要扣减
    if (_writtenBytes > 0) {
      final cm = CacheManager();
      if (cm._sizeInitialized) {
        cm._currentSize = cm._currentSize! - _writtenBytes;
      }
    }
    await file.deleteIgnoreError();
  }

  void reset() {
    // 重置前扣减已追踪的大小
    if (_writtenBytes > 0) {
      final cm = CacheManager();
      if (cm._sizeInitialized) {
        cm._currentSize = cm._currentSize! - _writtenBytes;
      }
    }
    _writtenBytes = 0;
    _buffer.clear();
    if(file.existsSync()) {
      file.deleteSync();
    }
  }
}
